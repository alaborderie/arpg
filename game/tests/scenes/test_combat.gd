extends GdUnitTestSuite
## Scene-level integration tests for M2 combat, in the style of
## test_player_movement.gd: drive the real engine loop with a scene runner and
## assert on observable outcomes (health, corpse freeing) — no mocks.
##
## Since G1 the roster comes from the infinite [MonsterSpawner]; this suite pins
## it to exactly one forced fallen_imp (knobs set before the scene enters the
## tree, the test_loot.gd idiom) so the fight is as deterministic as the old
## fixed spawns were. The spawner places it 14-30 m out on the navmesh ring;
## both sides' attack speeds are ~1/s, so the generous timeouts below hold.

## Seed for the scene's RNG streams; any fixed value works — combat rolls only
## need to be reproducible here, not specific.
const COMBAT_SEED: int = 5
## Upper bound of simulated frames a test lets the fight run for. Generous:
## the spawner may place the imp up to 30 m out, and in headless runs the
## engine simulates fewer physics ticks per scene-runner frame than 1:1 (the
## catch-up scheduler is wall-clock-driven), so distance costs frames.
const TIMEOUT_FRAMES: int = 2400
## Frames simulated per polling step while waiting for an outcome.
const STEP_FRAMES: int = 30
## An imp that reached the player must sit within its attack range (1.5) plus
## slack for body radii and pathing wobble.
const ENGAGED_DISTANCE: float = 3.0


func before_test() -> void:
	# Combat has nothing to do with cloud sync; disabling it keeps this suite
	# hermetic and independent of network timing (M5, see docs/0013 - the same
	# idiom test_save_load.gd uses for pinning rng_seed).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


## Instantiates main.tscn pinned to one forced fallen_imp: seed and spawner
## knobs are set before the instance enters the tree so _ready picks them up.
func _combat_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", COMBAT_SEED)
	# G2 (docs/0016): pin the skill so this fresh-game instance skips the
	# choice screen (which would otherwise pause the tree) — quick_strike
	# matches the pre-G2 basic attack exactly, so this suite's timings hold.
	instance.set("starting_skill_id", "quick_strike")
	var spawner: Node = instance.get_node("MonsterSpawner")
	spawner.set("target_population", 1)
	spawner.set("forced_monster_id", "fallen_imp")
	# G7 (docs/0020): pin off so this swept-seed suite never has its forced
	# fallen_imp randomly promoted to an elite (3x health, different loot bias).
	spawner.set("forced_elite", 0)
	return instance


## Pre-configured instances are owned by the test, not the runner; free manually
## so the scene's physics bodies/nav agents don't leak (see test_loot.gd).
func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


## Monsters in the container, counted by type: floating damage labels also live
## under it.
func _count_monsters(monsters: Node3D) -> int:
	var count: int = 0
	for child: Node in monsters.get_children():
		if child is Monster:
			count += 1
	return count


func test_monster_chases_and_damages_the_player() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_combat_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_int(_count_monsters(monsters)).is_greater_equal(1)
	var monster: Monster = monsters.get_child(0) as Monster
	var monster_start: Vector3 = monster.global_position
	var initial_health: int = player.current_health()
	assert_int(initial_health).is_greater(0)

	# Stand still and let the melee_chaser AI come to us.
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and player.current_health() == initial_health:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_int(player.current_health()).is_less(initial_health)
	assert_bool(player.is_dead()).is_false()
	# The damage came from an actual chase: the imp left its spawn and is now
	# standing on top of us swinging.
	assert_float(monster.global_position.distance_to(monster_start)).is_greater(1.0)
	var gap: Vector3 = monster.global_position - player.global_position
	gap.y = 0.0
	assert_float(gap.length()).is_less(ENGAGED_DISTANCE)
	await _free_main(runner, main)


func test_player_attack_order_kills_the_monster_and_frees_it() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_combat_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	var monster: Monster = monsters.get_child(0) as Monster
	var initial_monster_health: int = monster.current_health()
	assert_int(initial_monster_health).is_greater(0)

	# One order does it all: walk into range, then swing on cooldown until dead.
	player.order_attack(monster)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	# Death frees the corpse (queue_free), so the node is gone from the tree.
	assert_bool(is_instance_valid(monster)).is_false()
	# The spawner keeps the population at 1: a replacement shows up within one
	# spawner tick (0.5 s).
	frames = 0
	while frames < TIMEOUT_FRAMES and _count_monsters(monsters) < 1:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_int(_count_monsters(monsters)).is_equal(1)
	# A fallen imp cannot kill a healthy player in that time; we won the trade.
	assert_bool(player.is_dead()).is_false()
	assert_int(player.current_health()).is_greater(0)
	await _free_main(runner, main)
