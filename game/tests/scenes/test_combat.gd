extends GdUnitTestSuite
## Scene-level integration tests for M2 combat, in the style of
## test_player_movement.gd: drive the real engine loop with a scene runner and
## assert on observable outcomes (health, corpse freeing) — no mocks.
##
## Main spawns the fallen imps and wires the shared DamageCalculator in `_ready`,
## and the test map's navmesh is queryable one frame after load (ADR 0009), so the
## fight starts immediately. Timings below are generous: the imps spawn in the far
## corners (~21 m out at move_speed 3.2, so the movement suite gets an uncontested
## window), and both sides' attack speeds are ~1/s.

## Upper bound of simulated frames a test lets the fight run for (60 Hz physics).
const TIMEOUT_FRAMES: int = 900
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


func test_monster_chases_and_damages_the_player() -> void:
	var runner: GdUnitSceneRunner = scene_runner("res://scenes/main/main.tscn")
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_int(monsters.get_child_count()).is_greater_equal(1)
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


func test_player_attack_order_kills_the_monster_and_frees_it() -> void:
	var runner: GdUnitSceneRunner = scene_runner("res://scenes/main/main.tscn")
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

	# Death frees the corpse (queue_free), so the node is gone from the tree. The
	# container is counted by type: floating damage labels also live under it.
	assert_bool(is_instance_valid(monster)).is_false()
	var remaining: int = 0
	for child: Node in monsters.get_children():
		if child is Monster:
			remaining += 1
	assert_int(remaining).is_equal(1)
	# A fallen imp cannot kill a healthy player in that time; we won the trade.
	assert_bool(player.is_dead()).is_false()
	assert_int(player.current_health()).is_greater(0)
