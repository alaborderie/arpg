extends GdUnitTestSuite
## Scene-level integration tests for M1 movement: bake -> move order -> arrival.
##
## gdUnit note: `scene_runner()` instantiates a scene and lets the test drive the real
## engine loop (`simulate_frames`), so this exercises the actual NavigationServer path
## the game uses — not a mock. Runs headless; navigation and physics don't need a
## display.
##
## The test map bakes synchronously and force-updates the navigation map in `_ready`
## (ADR 0009), so paths are queryable one frame after the scene loads — no signal to
## wait for.

const ARRIVAL_TOLERANCE: float = 1.5
## Open ground on the test map, away from every obstacle.
const DESTINATION: Vector3 = Vector3(5.0, 0.0, -5.0)
## Centre of the BlockSquat obstacle (3x3 footprint at (-9, 9), see test_map.tscn).
const OBSTACLE_CENTRE: Vector3 = Vector3(-9.0, 0.0, 9.0)
## Frames to simulate: generous for the distances involved at move_speed 6, 60 Hz.
const MAX_FRAMES: int = 400
## Frames simulated per polling step while waiting for the player to settle.
const STEP_FRAMES: int = 20
## Position change per step under which the player counts as settled (arrived).
const SETTLE_EPSILON: float = 0.05


func before_test() -> void:
	# Movement has nothing to do with cloud sync; disabling it keeps this suite
	# hermetic and independent of network timing (M5, see docs/0013 - the same
	# idiom test_save_load.gd uses for pinning rng_seed).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


func test_player_walks_to_ordered_destination() -> void:
	var runner: GdUnitSceneRunner = scene_runner("res://scenes/main/main.tscn")
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var start: Vector3 = player.global_position
	player.move_to(DESTINATION)
	await _simulate_until_settled(runner, player, start)

	var travelled: float = player.global_position.distance_to(start)
	var remaining: Vector3 = player.global_position - DESTINATION
	remaining.y = 0.0
	assert_float(travelled).is_greater(1.0)
	assert_float(remaining.length()).is_less(ARRIVAL_TOLERANCE)


func test_order_into_obstacle_resolves_to_nearby_reachable_point() -> void:
	var runner: GdUnitSceneRunner = scene_runner("res://scenes/main/main.tscn")
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	# The agent clamps the unreachable target to the closest point on the navmesh,
	# so the player should end up next to the block — never inside it, no crash.
	var start: Vector3 = player.global_position
	player.move_to(OBSTACLE_CENTRE)
	await _simulate_until_settled(runner, player, start)

	var offset: Vector3 = player.global_position - OBSTACLE_CENTRE
	offset.y = 0.0
	# Block half-extent is 1.5; anything below that would be inside the box.
	assert_float(offset.length()).is_greater(1.2)
	assert_float(offset.length()).is_less(5.0)


## Simulates frames until the player stops moving (arrived), or MAX_FRAMES pass.
## Asserting right at arrival keeps this suite about *movement*: since M2 the map
## also holds chasing monsters, and given enough frames they reach the player and
## jostle it around — that interference is the combat suite's business, not ours.
func _simulate_until_settled(
	runner: GdUnitSceneRunner, player: Player, start: Vector3
) -> void:
	var frames: int = 0
	var previous: Vector3 = player.global_position
	while frames < MAX_FRAMES:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
		var now: Vector3 = player.global_position
		if now.distance_to(previous) < SETTLE_EPSILON and now.distance_to(start) > 0.5:
			return
		previous = now
