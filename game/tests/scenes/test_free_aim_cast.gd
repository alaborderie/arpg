extends GdUnitTestSuite
## Scene-level integration tests for G6 (issue #13): Q-cast free-aim casting.
##
## Style follows test_ranged_skill.gd/test_combat.gd: drive the real engine
## loop with a scene runner, call [method Player.cast_at] directly rather than
## injecting input events — gdUnit warns InputEvents don't transport reliably
## in headless mode, and `cast_at` is exactly the seam main.gd's `cast_primary`
## handler calls, so exercising it directly proves the same code path.

const CAST_SEED: int = 33
## Generous: the spawner may place a forced imp up to 30 m out and it has to
## chase all the way into the (much shorter) skill range before a cast can
## land at all — see test_combat.gd for why headless scene-runner frames
## don't map 1:1 onto physics ticks.
const TIMEOUT_FRAMES: int = 2400
const STEP_FRAMES: int = 15
const RANGED_SKILL_ID: String = "fireball"
const MELEE_SKILL_ID: String = "quick_strike"


func before_test() -> void:
	# Casting has nothing to do with cloud sync; disabling it keeps this suite
	# hermetic and independent of network timing (same idiom as
	# test_combat.gd/test_ranged_skill.gd, docs/0013).
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


## Instantiates main.tscn pinned to one forced fallen_imp and a chosen starting
## skill: seed and spawner knobs are set before the instance enters the tree so
## _ready picks them up (test_combat.gd's idiom).
func _cast_main(skill_id: String, population: int = 1) -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", CAST_SEED)
	instance.set("starting_skill_id", skill_id)
	var spawner: Node = instance.get_node("MonsterSpawner")
	spawner.set("target_population", population)
	spawner.set("forced_monster_id", "fallen_imp")
	# G7 (docs/0020): pin off so this swept-seed suite never has its forced
	# fallen_imp randomly promoted to an elite (3x health, different loot bias).
	spawner.set("forced_elite", 0)
	return instance


## Pre-configured instances are owned by the test, not the runner; free
## manually so the scene's physics bodies/nav agents don't leak (test_loot.gd
## idiom).
func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func _count_monsters(monsters: Node3D) -> int:
	var count: int = 0
	for child: Node in monsters.get_children():
		if child is Monster:
			count += 1
	return count


func _count_projectiles(main: Node3D) -> int:
	var count: int = 0
	for child: Node in main.get_children():
		if child is Projectile:
			count += 1
	return count


## Q-cast never walks into range; the tests let the (aggro-less-radius,
## always-hunting) melee_chaser AI close the distance itself, the same way
## test_combat.gd's "stand still and let it come to us" case does — once it's
## within the skill's range, the cast can actually land.
func _wait_until_within_range(
	runner: GdUnitSceneRunner, player: Player, monster: Monster, range: float
) -> void:
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		var gap: Vector3 = monster.global_position - player.global_position
		gap.y = 0.0
		if gap.length() <= range:
			return
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES


func test_ranged_q_cast_kills_a_monster_along_the_aim_line() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_str(player.skill_id()).is_equal(RANGED_SKILL_ID)
	var monster: Monster = monsters.get_child(0) as Monster
	assert_int(monster.current_health()).is_greater(0)

	# fireball's range is 9 m; let the chaser close in first (no auto-walk on
	# Q), then keep casting at its current position — an aim line straight at
	# a stationary-relative-to-the-cast target — until it dies. A cast is a
	# no-op while on cooldown, so repeatedly calling it just fires as soon as
	# it's ready again.
	await _wait_until_within_range(runner, player, monster, 9.0)
	assert_bool(is_instance_valid(monster)).is_true()

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		player.cast_at(monster.global_position)
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(monster)).is_false()
	assert_bool(player.is_dead()).is_false()
	await _free_main(runner, main)


func test_melee_q_cast_kills_an_adjacent_monster_in_the_aim_arc() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(MELEE_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_str(player.skill_id()).is_equal(MELEE_SKILL_ID)
	var monster: Monster = monsters.get_child(0) as Monster
	assert_int(monster.current_health()).is_greater(0)

	# quick_strike's range is 1.8 m; the melee_chaser AI walks all the way up
	# to its own attack range (1.5 m) to swing at the player, which already
	# puts it inside quick_strike's range and squarely in front of the player
	# (facing whatever it's attacking) — a real "adjacent monster" case.
	await _wait_until_within_range(runner, player, monster, 1.8)
	assert_bool(is_instance_valid(monster)).is_true()

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		player.cast_at(monster.global_position)
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(monster)).is_false()
	assert_bool(player.is_dead()).is_false()
	await _free_main(runner, main)


func test_free_fire_at_empty_ground_does_not_error_and_starts_cooldown() -> void:
	# Quiet map (population 0, per G1's test-knob idiom): free-fire must work
	# with zero monsters around at all.
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(RANGED_SKILL_ID, 0))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var aim: Vector3 = player.global_position + Vector3(0, 0, -5)
	player.cast_at(aim)
	# A second cast in the same frame must be silently ignored (no queueing) —
	# only one projectile should ever have spawned.
	player.cast_at(aim)
	await runner.simulate_frames(1)

	assert_int(_count_projectiles(main)).is_equal(1)
	assert_bool(player.is_dead()).is_false()

	# Let the lone projectile fly its full course and despawn untouched —
	# proving free-fire at empty ground never errors, all the way through.
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and _count_projectiles(main) > 0:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_int(_count_projectiles(main)).is_equal(0)
	await _free_main(runner, main)


func test_a_monster_off_the_aim_line_is_not_hit_by_free_fire() -> void:
	# Quiet map: the only monster present is the one this test places by hand,
	# well off to the side of the aim line (the spawner's own ring placement
	# can't be pinned to "off-line", so this test controls the position
	# directly the way test_health_bars.gd/test_monster_spawner.gd instance
	# scenes manually when the spawner's ring can't guarantee a layout).
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(RANGED_SKILL_ID, 0))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	var calculator: DamageCalculator = DamageCalculator.new(RngService.new(CAST_SEED))
	var combat_constants: Dictionary = BalanceData.load_combat().get("combat", {})
	var monster: Monster = (load("res://scenes/monster/monster.tscn") as PackedScene).instantiate() as Monster
	# Perpendicular to the aim direction below (+X), and far enough away (the
	# closest point on the whole flight path is still 6 m off) that no
	# HIT_RADIUS (0.5 m) sweep could ever catch it.
	monster.position = player.global_position + Vector3(0, 0, 6)
	monsters.add_child(monster)
	monster.setup(BalanceData.monster("fallen_imp"), combat_constants, calculator, player)
	await runner.simulate_frames(1)
	assert_int(_count_monsters(monsters)).is_equal(1)
	var initial_health: int = monster.current_health()

	var aim: Vector3 = player.global_position + Vector3(9, 0, 0)
	player.cast_at(aim)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(1)

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and _count_projectiles(main) > 0:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_int(_count_projectiles(main)).is_equal(0)
	assert_bool(is_instance_valid(monster)).is_true()
	assert_int(monster.current_health()).is_equal(initial_health)
	await _free_main(runner, main)


## G10 (issue #17, docs/0023): the primary playtest bug — a directional shot
## aimed dead-on at a chasing monster would still whiff because the monster
## drifted out of the (old, narrow) hit corridor during the projectile's
## flight. Aim assist looks up a snap target at cast time and fires it as
## [constant Projectile.Mode.HOMING] instead, which re-tracks the monster
## every tick and therefore cannot be outrun by its own continued chase
## movement. This lets the chaser close to somewhere in the 5-8 m band the
## ticket calls out — still clearly still approaching, nowhere near its own
## 1.5 m attack range — then fires exactly once at wherever it stands *right
## now* and proves the hit lands despite the monster moving throughout the
## flight.
func test_ranged_q_cast_hits_a_moving_monster_via_aim_assist() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	var monster: Monster = monsters.get_child(0) as Monster
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		var gap: Vector3 = monster.global_position - player.global_position
		gap.y = 0.0
		if gap.length() <= 8.0:
			break
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES
	assert_bool(is_instance_valid(monster)).is_true()

	var pre_gap: Vector3 = monster.global_position - player.global_position
	pre_gap.y = 0.0
	# Comfortably not adjacent (nowhere near quick_strike/melee range) and
	# still within fireball's 9 m range — the "5-8 m, still closing" case.
	assert_float(pre_gap.length()).is_greater(2.5)
	assert_float(pre_gap.length()).is_less_equal(9.0)

	var initial_health: int = monster.current_health()
	player.cast_at(monster.global_position)
	assert_int(_count_projectiles(main)).is_equal(1)

	# Let the shot's whole flight play out (comfortably longer than any
	# in-range travel time at Projectile.SPEED) while the monster keeps
	# closing in — the exact window the old directional-only miss bug lived in.
	var flight_frames: int = 0
	while flight_frames < 180 and _count_projectiles(main) > 0:
		await runner.simulate_frames(5)
		flight_frames += 5

	assert_int(_count_projectiles(main)).is_equal(0)
	assert_bool(is_instance_valid(monster)).is_true()
	assert_int(monster.current_health()).is_less(initial_health)
	await _free_main(runner, main)


## G10 (issue #17, docs/0023): G8's `added_projectiles` fan (docs/0021) and
## the new aim assist must coexist — a fanned cast's center projectile still
## snaps to homing on a monster near the aim line, while the rest of the fan
## keeps flying directional, with neither mechanism erroring or swallowing
## the hit.
func test_fan_and_aim_assist_coexist() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_cast_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	# Player.add_support is the documented seam (docs/0021) for granting a
	# support deterministically, bypassing the level-up RNG offer/UI.
	player.add_support("added_projectiles")

	var monster: Monster = monsters.get_child(0) as Monster
	await _wait_until_within_range(runner, player, monster, 9.0)
	assert_bool(is_instance_valid(monster)).is_true()
	var initial_health: int = monster.current_health()

	player.cast_at(monster.global_position)
	# 1 (base) + 1 (added_projectiles) — the fan the ticket asks to keep working.
	assert_int(_count_projectiles(main)).is_equal(2)

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and _count_projectiles(main) > 0:
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_int(_count_projectiles(main)).is_equal(0)
	assert_bool(player.is_dead()).is_false()
	# At least the homed shot must have connected — the fan + aim-assist
	# combination must not silently swallow the hit.
	if is_instance_valid(monster):
		assert_int(monster.current_health()).is_less(initial_health)
	await _free_main(runner, main)
