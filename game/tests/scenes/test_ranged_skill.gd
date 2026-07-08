extends GdUnitTestSuite
## Scene-level integration test for G2's ranged skills: a target-locked
## [Projectile] must travel from the player to a monster and kill it, proving
## the whole ranged path end to end (skill selection -> composed AttackProfile
## -> fired projectile -> DamageCalculator resolution on impact -> Monster.take_hit
## -> death/loot chain) rather than just unit-testing the pieces.
##
## Style follows test_combat.gd: the spawner is pinned to one forced fallen_imp
## (G1 guidance — pin target_population/forced_monster_id in every scene test),
## and this suite additionally pins `starting_skill_id` to a ranged skill so it
## skips the choice screen the way every other fresh-game scene test now does
## (docs/0016).

const RANGED_SEED: int = 21
const RANGED_SKILL_ID: String = "fireball"
## Generous: the spawner may place the imp up to 30 m out, well past
## fireball's 9 m range, so the player has to walk in first (see test_combat.gd
## for why headless scene-runner frames don't map 1:1 onto physics ticks).
const TIMEOUT_FRAMES: int = 2400
const STEP_FRAMES: int = 30


func before_test() -> void:
	SyncConfig.enabled = false


func after_test() -> void:
	SyncConfig.enabled = true


func _ranged_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", RANGED_SEED)
	instance.set("starting_skill_id", RANGED_SKILL_ID)
	var spawner: Node = instance.get_node("MonsterSpawner")
	spawner.set("target_population", 1)
	spawner.set("forced_monster_id", "fallen_imp")
	# G7 (docs/0020): pin off so this swept-seed suite never has its forced
	# fallen_imp randomly promoted to an elite (3x health, different loot bias).
	spawner.set("forced_elite", 0)
	return instance


func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func test_ranged_skill_fires_a_projectile_that_kills_the_monster() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_ranged_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	assert_str(player.skill_id()).is_equal(RANGED_SKILL_ID)
	var monster: Monster = monsters.get_child(0) as Monster
	assert_int(monster.current_health()).is_greater(0)

	player.order_attack(monster)
	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(monster)).is_false()
	assert_bool(player.is_dead()).is_false()
	await _free_main(runner, main)
