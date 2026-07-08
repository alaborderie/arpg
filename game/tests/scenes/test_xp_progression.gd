extends GdUnitTestSuite
## Scene-level integration tests for G3: a real kill grants XP through
## Monster.died -> main._on_monster_died -> Player.gain_xp -> the XP bar UI,
## and crossing a level threshold changes an observable stat (max health,
## fully healed on the level-up) — not just a domain-level curve calculation.
## See docs/0017.
##
## Style follows test_combat.gd: one forced fallen_imp (spawner knobs pinned
## before the scene enters the tree), scene_runner driving the real engine
## loop, manual disposal to avoid orphans, generous polling timeouts.

const XP_SEED: int = 11
## Upper bound of simulated frames a test lets a fight run for (60 Hz) — same
## budget as test_combat.gd for the same reason (the spawner may place the
## imp up to 30 m out).
const TIMEOUT_FRAMES: int = 2400
const STEP_FRAMES: int = 30


func before_test() -> void:
	# XP/levels have nothing to do with cloud sync; disabling it keeps this
	# suite hermetic and independent of network timing (same idiom as
	# test_combat.gd/test_save_load.gd, docs/0013).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true
	SaveStore.delete()


## Instantiates main.tscn pinned to one forced fallen_imp: seed and spawner
## knobs are set before the instance enters the tree so _ready picks them up
## (same idiom as test_combat.gd's _combat_main).
func _xp_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", XP_SEED)
	instance.set("starting_skill_id", "quick_strike")
	# G8 (docs/0021): this suite's second test crosses level 2 directly via
	# gain_xp — without this knob that would now draw a support offer and
	# pause the tree, which isn't what this suite tests (see test_support_choice.gd).
	instance.set("skip_support_offers", true)
	var spawner: Node = instance.get_node("MonsterSpawner")
	spawner.set("target_population", 1)
	spawner.set("forced_monster_id", "fallen_imp")
	# G7 (docs/0020): pin off so this swept-seed suite never has its forced
	# fallen_imp randomly promoted to an elite (3x health, different loot bias).
	spawner.set("forced_elite", 0)
	return instance


## Pre-configured instances are owned by the test, not the runner; free
## manually so the scene's physics bodies/nav agents don't leak.
func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func test_killing_a_monster_grants_xp_and_updates_the_bar() -> void:
	SaveStore.delete()
	var runner: GdUnitSceneRunner = scene_runner(_xp_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	var xp_bar: XPBar = main.get_node("XPBar")
	await runner.simulate_frames(2)

	assert_int(player.total_xp()).is_equal(0)
	var imp: Monster = monsters.get_child(0) as Monster
	var expected_reward: int = imp.xp_reward()
	assert_int(expected_reward).is_greater(0)

	# One order does it all: walk into range, then swing on cooldown until dead
	# (same pattern as test_combat.gd's kill test).
	player.order_attack(imp)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(imp):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_bool(is_instance_valid(imp)).is_false()

	assert_int(player.total_xp()).is_equal(expected_reward)
	var progress: Dictionary = player.xp_progress()
	assert_int(int(progress.get("level", -1))).is_equal(player.level())

	# The bar is a dumb view refreshed on xp_changed (same idiom as
	# InventoryPanel/inventory_changed) — assert its own read of the player's
	# level agrees, not just that the player object changed underneath it.
	var bar_label: Label = xp_bar.get_node("Panel/Margin/Layout/LevelLabel")
	assert_str(bar_label.text).is_equal("Level %d" % player.level())

	await _free_main(runner, main)


## The ticket's "assert something observable" requirement: a level-up must
## change more than an internal counter. Uses Player.gain_xp directly (already
## proven to be exactly what a kill calls, above) to cross a level threshold
## without waiting through several real fights, then asserts the +10% max
## health bonus took effect and the level-up healed the player back to that
## new max — the one explicit heal docs/0017 documents.
func test_crossing_a_level_threshold_recomposes_stats_and_heals_to_the_new_max() -> void:
	SaveStore.delete()
	var runner: GdUnitSceneRunner = scene_runner(_xp_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	assert_int(player.level()).is_equal(1)
	var base_max_health: int = player.max_health()

	# Take damage first so the level-up's heal is provably a heal, not a
	# no-op on a body already sitting at full health.
	player.take_hit(DamageResult.new(15, false, 0.0))
	assert_int(player.current_health()).is_less(base_max_health)

	# The exact XP needed for level 2, read from the same curve the game
	# loaded (BalanceData) rather than a hand-copied magic number — immune to
	# shared/progression.json being retuned later.
	var progression: ProgressionCurve = ProgressionCurve.new(
		BalanceData.load_progression().get("progression", {})
	)
	player.gain_xp(progression.xp_required_for_level(2))
	await runner.simulate_frames(2)

	assert_int(player.level()).is_equal(2)
	# +10% max_health per level (docs/0017): a real, observable stat change.
	assert_int(player.max_health()).is_greater(base_max_health)
	# The one explicit level-up heal: current health snaps to the *new* max,
	# proving the heal ran (this player took damage above and would otherwise
	# still be sitting below max).
	assert_int(player.current_health()).is_equal(player.max_health())

	await _free_main(runner, main)
