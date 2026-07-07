extends GdUnitTestSuite
## Scene-level integration tests for M3 loot: a kill drops an item on the ground,
## the player picks it up into the bag, and equipping it changes combat output —
## in the style of test_combat.gd, driving the real engine loop with a scene
## runner and asserting on observable outcomes (no mocks).
##
## Determinism (ADR 0004) makes this practical: `main.gd` derives its loot RNG
## stream from `rng_seed` (see `_ready`), so a fixed seed plus "kill the first
## spawned fallen_imp" always rolls the same item. DROP_SEED was found offline by
## sweeping seeds through LootRoller against the real shared data until one
## produced a drop on the first kill; it currently rolls a plain "Rusty Sword"
## (weapon, normal rarity, no affixes) — if `shared/loot_tables.json` or
## `shared/items.json` change enough to roll something else, re-sweep and update
## the expectations below together.

## A master seed (see main.gd `_ready`) whose derived loot stream (`seed + 1`)
## rolls a "Rusty Sword" off the first fallen_imp kill.
const DROP_SEED: int = 37
const EXPECTED_ITEM_NAME: String = "Rusty Sword"
const EXPECTED_ITEM_SLOT: String = "weapon"

## Upper bound of simulated frames a test lets the fight/walk run for (60 Hz).
const TIMEOUT_FRAMES: int = 900
## Frames simulated per polling step while waiting for an outcome.
const STEP_FRAMES: int = 30


## Instantiates main.tscn with a fixed rng_seed, set *before* the scene enters
## the tree so `_ready` picks it up. `set()` (not `.rng_seed =`) sidesteps a
## static "unsafe property access" warning: main.gd has no class_name, so the
## exported var isn't visible on the `Node3D` type this returns.
func _seeded_main(seed_value: int) -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", seed_value)
	return instance


## `scene_runner()` only auto-frees scenes *it* instantiated from a path; handing
## it a pre-seeded instance (the only way to set `rng_seed` before `_ready`)
## means we own its lifetime. Free it ourselves, or the node (and its physics
## bodies/nav agents) leaks past the test and gdUnit flags an orphan.
func _free_seeded_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


## Kills [param monster] and waits until its drop lands under [param drops].
## Returns the spawned [GroundDrop], or null if it never showed up.
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


func test_kill_drops_item_that_can_be_picked_up_into_the_bag() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_seeded_main(DROP_SEED))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	var drops: Node3D = main.get_node("Drops")
	await runner.simulate_frames(2)

	var monster: Monster = monsters.get_child(0) as Monster
	var drop: GroundDrop = await _kill_and_wait_for_drop(runner, player, monster, drops)
	assert_object(drop).is_not_null()
	assert_str(String(drop.item().get("name", ""))).is_equal(EXPECTED_ITEM_NAME)
	assert_bool(player.inventory().bag().is_empty()).is_true()

	# Walk over and grab it; PICKUP_RANGE is generous, so ordering the pickup from
	# the drop's own spot (where the corpse fell) settles in one step.
	player.order_pickup(drop)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(drop):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(drop)).is_false()
	assert_int(drops.get_child_count()).is_equal(0)
	var bag: Array[Dictionary] = player.inventory().bag()
	assert_int(bag.size()).is_equal(1)
	assert_str(String(bag[0].get("name", ""))).is_equal(EXPECTED_ITEM_NAME)
	assert_str(String(bag[0].get("slot", ""))).is_equal(EXPECTED_ITEM_SLOT)
	await _free_seeded_main(runner, main)


func test_equipping_a_looted_weapon_changes_the_players_attack_output() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_seeded_main(DROP_SEED))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	var drops: Node3D = main.get_node("Drops")
	await runner.simulate_frames(2)

	# Baseline: the unarmed attack profile from shared/player.json (4-7 physical
	# as of schema v2 — see shared/player.json — distinct from the rolled sword).
	var before: AttackProfile = player.attack_profile()
	var before_min: int = before.base_min
	var before_max: int = before.base_max

	var monster: Monster = monsters.get_child(0) as Monster
	var drop: GroundDrop = await _kill_and_wait_for_drop(runner, player, monster, drops)
	assert_object(drop).is_not_null()
	player.order_pickup(drop)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(drop):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_int(player.inventory().bag().size()).is_equal(1)

	player.equip_bag_index(0)

	assert_str(String(player.inventory().equipped(EXPECTED_ITEM_SLOT).get("name", ""))) \
		.is_equal(EXPECTED_ITEM_NAME)
	assert_bool(player.inventory().bag().is_empty()).is_true()
	var after: AttackProfile = player.attack_profile()
	# The rolled Rusty Sword is a plain (no-affix) base: its implicit damage
	# (shared/items.json) replaces the unarmed profile wholesale.
	assert_bool(after.base_min != before_min or after.base_max != before_max).is_true()
	assert_int(after.base_min).is_equal(3)
	assert_int(after.base_max).is_equal(6)
	assert_int(after.damage_type).is_equal(AttackProfile.DamageType.PHYSICAL)

	# Unequipping puts the sword back in the bag and reverts to the unarmed profile.
	player.unequip_slot(EXPECTED_ITEM_SLOT)
	assert_int(player.inventory().bag().size()).is_equal(1)
	var reverted: AttackProfile = player.attack_profile()
	assert_int(reverted.base_min).is_equal(before_min)
	assert_int(reverted.base_max).is_equal(before_max)
	await _free_seeded_main(runner, main)
