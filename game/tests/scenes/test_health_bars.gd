extends GdUnitTestSuite
## Scene-level integration tests for G4 (issue #11): a monster's floating
## health bar reflects damage after a real hit, and the player's bar reflects
## a level-up heal back to full. Style follows test_combat.gd/
## test_xp_progression.gd: one forced fallen_imp (spawner knobs pinned before
## the scene enters the tree), scene_runner driving the real engine loop,
## manual disposal to avoid orphans, generous polling timeouts.

const HEALTH_BAR_SEED: int = 17
## Upper bound of simulated frames a test lets a fight run for (60 Hz) — same
## budget as test_combat.gd/test_xp_progression.gd for the same reason (the
## spawner may place the imp up to 30 m out).
const TIMEOUT_FRAMES: int = 2400
const STEP_FRAMES: int = 10


func before_test() -> void:
	# Health bars have nothing to do with cloud sync; disabling it keeps this
	# suite hermetic and independent of network timing (same idiom as
	# test_combat.gd/test_xp_progression.gd, docs/0013).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true
	SaveStore.delete()


## Instantiates main.tscn pinned to one forced fallen_imp: seed and spawner
## knobs are set before the instance enters the tree so _ready picks them up
## (same idiom as test_combat.gd's/test_xp_progression.gd's helpers).
func _health_bar_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", HEALTH_BAR_SEED)
	instance.set("starting_skill_id", "quick_strike")
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


func test_monster_health_bar_reflects_damage_after_a_hit() -> void:
	SaveStore.delete()
	var runner: GdUnitSceneRunner = scene_runner(_health_bar_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	var imp: Monster = monsters.get_child(0) as Monster
	var bar: HealthBar3D = imp.get_node("HealthBar3D")
	assert_float(bar.current_fraction()).is_equal(1.0)

	# One order does it all: walk into range, then swing on cooldown (same
	# pattern as test_combat.gd's kill test) — poll until the first hit lands
	# rather than assuming a fixed frame count.
	player.order_attack(imp)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(imp) and bar.current_fraction() >= 1.0:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(imp)).is_true()
	assert_float(bar.current_fraction()).is_less(1.0)
	assert_float(bar.current_fraction()).is_greater(0.0)

	await _free_main(runner, main)


func test_player_health_bar_reflects_a_level_up_heal() -> void:
	SaveStore.delete()
	var runner: GdUnitSceneRunner = scene_runner(_health_bar_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var bar: HealthBar3D = player.get_node("HealthBar3D")
	assert_float(bar.current_fraction()).is_equal(1.0)

	# Take damage first so the level-up's heal is provably a heal, not a
	# no-op on a bar already reading full (same setup as
	# test_xp_progression.gd's level-up test).
	player.take_hit(DamageResult.new(15, false, 0.0))
	await runner.simulate_frames(1)
	assert_float(bar.current_fraction()).is_less(1.0)

	# The exact XP needed for level 2, read from the same curve the game
	# loaded (BalanceData) rather than a hand-copied magic number.
	var progression: ProgressionCurve = ProgressionCurve.new(
		BalanceData.load_progression().get("progression", {})
	)
	player.gain_xp(progression.xp_required_for_level(2))
	await runner.simulate_frames(2)

	assert_int(player.level()).is_equal(2)
	assert_float(bar.current_fraction()).is_equal(1.0)

	await _free_main(runner, main)
