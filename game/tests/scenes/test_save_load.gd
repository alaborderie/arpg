extends GdUnitTestSuite
## Scene-level integration test for M4 persistence: kill, loot and equip in one
## seeded session, save, then boot a second, independent scene instance that
## loads the same save — and assert health, inventory/equipment and the loot RNG
## stream all resumed exactly where the first session left off.
##
## Style follows test_loot.gd: a pre-seeded scene instance (rng_seed set before
## _ready, so main.gd picks it up), scene_runner driving the real engine loop,
## manual disposal to avoid orphans, and `.call()`/`.set()` to reach main.gd's
## script members without a class_name (see test_loot.gd's own comment on why).
##
## SAVE_SEED was found the same way DROP_SEED was in test_loot.gd: swept offline
## against the real shared data until the loot stream it derives (SAVE_SEED + 1)
## rolled two different, nonempty, easy-to-tell-apart drops back to back — a
## plain "Rusty Sword" (weapon) for the kill this test
## loots and equips, then a "Leather Vest" (armor) for the kill the *second*,
## reloaded session performs. That second drop only comes out right if the loot
## RNG stream truly resumed after one prior roll_drop call instead of restarting
## from the derived seed — the crux of what this test proves.

const SAVE_SEED: int = 43
const FIRST_DROP_NAME: String = "Rusty Sword"
const FIRST_DROP_SLOT: String = "weapon"
const SECOND_DROP_NAME: String = "Leather Vest"
const SECOND_DROP_SLOT: String = "armor"

## Upper bound of simulated frames a test lets a fight/walk run for (60 Hz).
const TIMEOUT_FRAMES: int = 900
## Frames simulated per polling step while waiting for an outcome.
const STEP_FRAMES: int = 30


func before_test() -> void:
	# Save/load has nothing to do with cloud sync; disabling it keeps this
	# suite hermetic and independent of network timing (M5, see docs/0013).
	# _fresh_main() below boots with rng_seed == 0, the same "real boot" path
	# SyncService normally runs on, so it would otherwise try to reach the
	# server during this test.
	SyncConfig.enabled = false


func after_test() -> void:
	# Guarantee cleanup even if an assertion fails mid-test (CLAUDE.md: keep
	# headless runs hermetic, never leave a save behind for the next test).
	SaveStore.delete()
	SyncStore.delete()
	SyncConfig.enabled = true


## Instantiates main.tscn with a fixed rng_seed, set *before* the scene enters the
## tree so `_ready` picks it up — mirrors test_loot.gd's `_seeded_main`.
func _seeded_main(seed_value: int) -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", seed_value)
	return instance


## A fresh, unseeded instance: rng_seed stays 0, the same as a real boot, so
## _ready's "load the save if one exists" path is exercised for real.
func _fresh_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	return packed.instantiate() as Node3D


func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


## Kills [param monster] and waits until its drop lands under [param drops].
func _kill_and_wait_for_drop(
	runner: GdUnitSceneRunner, player: Player, monster: Monster, drops: Node3D
) -> GroundDrop:
	player.order_attack(monster)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and drops.get_child_count() == 0:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	if drops.get_child_count() == 0:
		return null
	return drops.get_child(0) as GroundDrop


## Walks the player onto [param drop] and waits until it disappears into the bag.
func _pick_up_and_wait(runner: GdUnitSceneRunner, player: Player, drop: GroundDrop) -> void:
	player.order_pickup(drop)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(drop):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES


func test_save_then_reload_restores_health_inventory_equipment_and_progress() -> void:
	SaveStore.delete()

	# --- Session 1: kill, loot, equip, take a hit, then save. ---
	var runner1: GdUnitSceneRunner = scene_runner(_seeded_main(SAVE_SEED))
	var main1: Node3D = runner1.scene()
	var player1: Player = main1.get_node("Player")
	var monsters1: Node3D = main1.get_node("Monsters")
	var drops1: Node3D = main1.get_node("Drops")
	await runner1.simulate_frames(2)

	var initial_health: int = player1.current_health()
	var killed_monster: Monster = monsters1.get_child(0) as Monster
	var drop: GroundDrop = await _kill_and_wait_for_drop(runner1, player1, killed_monster, drops1)
	assert_object(drop).is_not_null()
	assert_str(String(drop.item().get("name", ""))).is_equal(FIRST_DROP_NAME)
	await _pick_up_and_wait(runner1, player1, drop)
	assert_int(player1.inventory().bag().size()).is_equal(1)
	player1.equip_bag_index(0)
	assert_str(String(player1.inventory().equipped(FIRST_DROP_SLOT).get("name", ""))) \
		.is_equal(FIRST_DROP_NAME)
	assert_bool(player1.inventory().bag().is_empty()).is_true()

	# A direct, fixed hit (rather than waiting on the surviving imp's chase AI —
	# already proven in test_combat.gd) so the saved health is provably not just
	# "still at the default max", without coupling this test's timing to combat.
	player1.take_hit(DamageResult.new(15, false, 0.0))
	var health_after_hit: int = player1.current_health()
	assert_int(health_after_hit).is_less(initial_health)

	main1.call("_save_game")

	# The adapter round-trip: what actually landed on disk.
	var saved: Dictionary = SaveStore.load()
	assert_bool(saved.is_empty()).is_false()
	assert_int(int(saved.get("master_seed", 0))).is_equal(SAVE_SEED)
	assert_int(int(saved.get("progress", {}).get("monsters_killed", -1))).is_equal(1)
	assert_int(int(saved.get("player", {}).get("health", -1))).is_equal(health_after_hit)

	await _free_main(runner1, main1)

	# --- Session 2: a brand-new scene instance boots and loads the same save. ---
	var runner2: GdUnitSceneRunner = scene_runner(_fresh_main())
	var main2: Node3D = runner2.scene()
	var player2: Player = main2.get_node("Player")
	var monsters2: Node3D = main2.get_node("Monsters")
	var drops2: Node3D = main2.get_node("Drops")
	await runner2.simulate_frames(2)

	assert_int(player2.current_health()).is_equal(health_after_hit)
	assert_str(String(player2.inventory().equipped(FIRST_DROP_SLOT).get("name", ""))) \
		.is_equal(FIRST_DROP_NAME)
	assert_bool(player2.inventory().bag().is_empty()).is_true()

	# Prove the loot RNG stream resumed rather than restarted: killing a monster
	# now must roll the *second* drop of the SAVE_SEED sequence, not the first
	# again (the fresh-restart failure mode this test is designed to catch).
	var second_kill: Monster = monsters2.get_child(0) as Monster
	var second_drop: GroundDrop = await _kill_and_wait_for_drop(runner2, player2, second_kill, drops2)
	assert_object(second_drop).is_not_null()
	assert_str(String(second_drop.item().get("name", ""))).is_equal(SECOND_DROP_NAME)
	assert_str(String(second_drop.item().get("slot", ""))).is_equal(SECOND_DROP_SLOT)

	await _free_main(runner2, main2)
	SaveStore.delete()
