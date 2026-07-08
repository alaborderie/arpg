extends GdUnitTestSuite
## Scene-level integration tests for the G1 infinite [MonsterSpawner]: the
## population is maintained after kills, spawn positions land on the navmesh
## outside the minimum radius, and far-away ground drops get cleaned up.
##
## Style follows test_loot.gd: pre-configured scene instances (knobs set before
## _ready), scene_runner driving the real engine loop, manual disposal.

const SPAWNER_SEED: int = 11
## Upper bound of simulated frames a test waits for an outcome (60 Hz physics).
const TIMEOUT_FRAMES: int = 900
## Frames simulated per polling step while waiting for an outcome.
const STEP_FRAMES: int = 30
## Two frames of a chasing monster's movement (~0.1 m) plus pathing slack: how
## far inside MIN_SPAWN_RADIUS a monster may legitimately sit by the time the
## test measures it.
const CHASE_SLACK: float = 1.0

const GROUND_DROP_SCENE: PackedScene = preload("res://scenes/loot/ground_drop.tscn")


func before_test() -> void:
	# Spawning has nothing to do with cloud sync; disabling it keeps this suite
	# hermetic and independent of network timing (M5, see docs/0013).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


## Instantiates main.tscn with a fixed rng_seed and the spawner knobs set before
## the scene enters the tree, so _ready picks everything up (test_loot.gd idiom).
func _spawner_main(population: int, forced_id: String = "") -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", SPAWNER_SEED)
	var spawner: Node = instance.get_node("MonsterSpawner")
	spawner.set("target_population", population)
	if forced_id != "":
		spawner.set("forced_monster_id", forced_id)
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


func test_initial_spawns_fill_the_population_on_the_navmesh_ring() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_spawner_main(5))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_int(_count_monsters(monsters)).is_equal(5)
	var map: RID = player.get_world_3d().navigation_map
	for child: Node in monsters.get_children():
		var monster: Monster = child as Monster
		if monster == null:
			continue
		# Ring geometry: outside the minimum radius (minus the little they may
		# already have chased), inside the maximum.
		var gap: Vector3 = monster.global_position - player.global_position
		gap.y = 0.0
		assert_float(gap.length()) \
			.is_greater_equal(MonsterSpawner.MIN_SPAWN_RADIUS - CHASE_SLACK)
		assert_float(gap.length()).is_less_equal(MonsterSpawner.MAX_SPAWN_RADIUS + CHASE_SLACK)
		# On the navmesh: the closest navmesh point sits at the monster's own
		# horizontal position (only the bake's vertical offset differs).
		var snapped: Vector3 = NavigationServer3D.map_get_closest_point(
			map, monster.global_position
		)
		var off_mesh: Vector3 = snapped - monster.global_position
		off_mesh.y = 0.0
		assert_float(off_mesh.length()).is_less(0.5)
	await _free_main(runner, main)


func test_population_recovers_after_a_kill() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_spawner_main(1, "fallen_imp"))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_int(_count_monsters(monsters)).is_equal(1)
	var first: Monster = monsters.get_child(0) as Monster
	var first_id: int = first.get_instance_id()

	player.order_attack(first)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(first):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_bool(is_instance_valid(first)).is_false()

	# The spawner tops the population back up within one tick.
	frames = 0
	while frames < TIMEOUT_FRAMES and _count_monsters(monsters) < 1:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_int(_count_monsters(monsters)).is_equal(1)
	var replacement: Monster = null
	for child: Node in monsters.get_children():
		if child is Monster:
			replacement = child as Monster
	assert_object(replacement).is_not_null()
	assert_bool(replacement.get_instance_id() == first_id).is_false()
	await _free_main(runner, main)


func test_far_drops_are_despawned_and_near_drops_kept() -> void:
	# Population 0: no monsters to interfere; the cleanup pass still ticks.
	var runner: GdUnitSceneRunner = scene_runner(_spawner_main(0))
	var main: Node3D = runner.scene()
	var drops: Node3D = main.get_node("Drops")
	await runner.simulate_frames(2)

	var far_drop: GroundDrop = GROUND_DROP_SCENE.instantiate() as GroundDrop
	far_drop.position = Vector3(60.0, 0.0, 0.0)
	drops.add_child(far_drop)
	far_drop.setup({"name": "Far Corpse Loot", "rarity": "normal"})
	var near_drop: GroundDrop = GROUND_DROP_SCENE.instantiate() as GroundDrop
	near_drop.position = Vector3(5.0, 0.0, 0.0)
	drops.add_child(near_drop)
	near_drop.setup({"name": "Near Corpse Loot", "rarity": "normal"})

	# Poll: the cleanup pass runs once per spawner tick (0.5 s), and headless
	# scene-runner frames don't map 1:1 onto physics ticks.
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(far_drop):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(far_drop)).is_false()
	assert_bool(is_instance_valid(near_drop)).is_true()
	assert_int(drops.get_child_count()).is_equal(1)
	await _free_main(runner, main)
