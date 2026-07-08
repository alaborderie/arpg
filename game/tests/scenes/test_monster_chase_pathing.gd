extends GdUnitTestSuite
## G10 (issue #17, docs/0023): a regression guard for the "sideways chase"
## pathing complaint in the playtest report — a chasing monster was observed
## drifting mostly laterally (+X at constant Z) toward a stationary target
## instead of closing the distance directly, taking far longer than its own
## `move_speed` implies.
##
## The investigation (docs/0023) reproduced the report's exact setup — one
## `fallen_imp` placed 5 m from a stationary [Player] standing at the scene
## origin, open ground, no obstacles (inside G5's 12 m prop-free safe zone,
## docs/0018) — with a scene-runner probe logging the monster's position
## every physics tick. It closed in a dead-straight line (zero lateral
## deviation) at its full `move_speed`, with [NavigationAgent3D] reporting a
## valid path from the very first tick. No defect was found in
## [Monster]'s chase code (`game/scenes/monster/monster.gd`), which already
## mirrors [Player]'s own known-good movement pattern (identical
## `path_desired_distance`/`target_desired_distance`, the same per-tick
## `target_position` reassignment). This suite exists to lock that verified
## behavior in against a future regression, since the ticket calls for a
## test either way.
##
## Style follows test_free_aim_cast.gd's off-aim-line case: a quiet map
## (population 0) with one [Monster] instanced and positioned by hand, since
## the spawner's ring placement can't guarantee an exact, obstacle-free
## starting offset.

const CHASE_SEED: int = 41
## Generous margin over the straight-line time (open ground, fallen_imp's own
## `move_speed`) — headless scene-runner frames don't map 1:1 onto physics
## ticks at this project's timescale (see test_combat.gd), so this is a loose
## upper bound, not a tight performance assertion.
const TIMEOUT_FRAMES: int = 1200
const STEP_FRAMES: int = 15
## Perpendicular drift off the straight approach line tolerated before
## calling it "not a straight chase" — comfortably above float/step noise,
## comfortably below "wandered sideways instead of closing".
const LATERAL_TOLERANCE: float = 0.75


func before_test() -> void:
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


func _quiet_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", CHASE_SEED)
	instance.set("starting_skill_id", "quick_strike")
	instance.get_node("MonsterSpawner").set("target_population", 0)
	return instance


func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func test_monster_closes_open_ground_directly_at_its_own_move_speed() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_quiet_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	var calculator: DamageCalculator = DamageCalculator.new(RngService.new(CHASE_SEED))
	var combat_constants: Dictionary = BalanceData.load_combat().get("combat", {})
	var monster_data: Dictionary = BalanceData.monster("fallen_imp")
	var monster: Monster = (load("res://scenes/monster/monster.tscn") as PackedScene).instantiate() as Monster
	# 5 m out along -Z, matching the playtest report's exact reproduction —
	# well inside test_map.gd's 12 m safe zone, so no prop ever sits between
	# the two.
	var start_offset: Vector3 = Vector3(0, 0, -5)
	monster.position = player.global_position + start_offset
	monsters.add_child(monster)
	monster.setup(monster_data, combat_constants, calculator, player)
	await runner.simulate_frames(1)

	var attack_range: float = float(monster_data.get("attack_range", 1.5))
	var move_speed: float = monster.move_speed()
	assert_float(move_speed).is_greater(0.0)

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		var gap: Vector3 = monster.global_position - player.global_position
		gap.y = 0.0
		if gap.length() <= attack_range:
			break
		# Straight-line approach: lateral (X) drift off the aim line (-Z from
		# the player) must stay well under the starting gap, never grow into
		# a "moving sideways instead of closing" pattern.
		assert_float(absf(monster.global_position.x - player.global_position.x)).is_less(
			LATERAL_TOLERANCE
		)
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(monster)).is_true()
	var final_gap: Vector3 = monster.global_position - player.global_position
	final_gap.y = 0.0
	assert_float(final_gap.length()).is_less_equal(attack_range)
	assert_int(frames).is_less(TIMEOUT_FRAMES)
	await _free_main(runner, main)
