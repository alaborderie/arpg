extends GdUnitTestSuite
## Scene-level integration tests for G9 (issue #16): reaching level 10 offers a
## skill bound to W (slot 1), W casts and kills independently of Q's own
## cooldown, and supports (G8, global) apply to slot 2 (E) exactly like slot 0.
##
## Style follows test_support_choice.gd/test_free_aim_cast.gd: a pre-configured
## scene instance, scene_runner driving the real engine loop, manual disposal,
## `skip_support_offers` left false only where the picker itself is exercised.

const SLOT_SEED: int = 61
const RANGED_SKILL_ID: String = "fireball"
const MELEE_SKILL_ID: String = "quick_strike"
const TIMEOUT_FRAMES: int = 2400
const STEP_FRAMES: int = 15


func before_test() -> void:
	SaveStore.delete()
	SyncConfig.enabled = false


func after_test() -> void:
	SaveStore.delete()
	SyncConfig.enabled = true
	# The picker test leaves the (process-wide) SceneTree paused on purpose;
	# unpause it so it never leaks into a later, unrelated test (same idiom
	# test_skill_choice.gd/test_support_choice.gd's after_test uses).
	get_tree().paused = false


## Instantiates main.tscn on a quiet map (no monsters needed for the tests
## that drive XP/slots directly), pinned to a starting skill and a fixed seed.
## [param skip_offers] mirrors every other G8/G9 suite's convention (docs/0021/
##0022): true (the default) bypasses BOTH reward pickers so a test driving W/E
## directly via [method Player.set_slot_skill] never gets stuck behind a
## screen it isn't testing; only the one suite exercising the real picker
## below passes false.
func _slots_main(skill_id: String = MELEE_SKILL_ID, skip_offers: bool = true) -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", SLOT_SEED)
	instance.set("starting_skill_id", skill_id)
	instance.set("skip_support_offers", skip_offers)
	instance.get_node("MonsterSpawner").set("target_population", 0)
	return instance


func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func _count_projectiles(main: Node3D) -> int:
	var count: int = 0
	for child: Node in main.get_children():
		if child is Projectile:
			count += 1
	return count


func _level_n_xp(level: int) -> int:
	var progression: ProgressionCurve = ProgressionCurve.new(
		BalanceData.load_progression().get("progression", {})
	)
	return progression.xp_required_for_level(level)


func test_reaching_level_10_offers_a_skill_bound_to_slot_w() -> void:
	# Start with offers skipped so climbing 1 -> 9 (gain_xp emits level_up for
	# EVERY level crossed, docs/0021) doesn't queue eight support pickers this
	# test doesn't care about; flip the knob back on right before the single
	# 9 -> 10 crossing so only that one reward — the skill-slot offer this test
	# actually exercises — ever gets queued or shown.
	var runner: GdUnitSceneRunner = scene_runner(_slots_main(MELEE_SKILL_ID, true))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	assert_bool(player.is_slot_unlocked(1)).is_false()
	assert_str(player.slot_skill_id(0)).is_equal(MELEE_SKILL_ID)

	player.gain_xp(_level_n_xp(9))
	await runner.simulate_frames(2)
	assert_int(player.level()).is_equal(9)
	assert_bool(main.get_tree().paused).is_false()

	main.set("skip_support_offers", false)
	player.gain_xp(_level_n_xp(10) - _level_n_xp(9))
	await runner.simulate_frames(2)

	assert_int(player.level()).is_equal(10)
	assert_bool(player.is_slot_unlocked(1)).is_true()
	assert_bool(main.get_tree().paused).is_true()

	var choice_ui: SkillChoiceUI = main.get_node("SkillChoiceUI")
	assert_bool(choice_ui.visible).is_true()
	var cards: HBoxContainer = choice_ui.get_node("Center/Layout/Cards")
	assert_int(cards.get_child_count()).is_equal(3)
	var ids: Array[String] = []
	for card: Node in cards.get_children():
		var id_value: String = String(card.get_meta("skill_id", ""))
		# The offer must never repeat slot 0's own skill (docs/0022's exclusion rule).
		assert_str(id_value).is_not_equal(MELEE_SKILL_ID)
		ids.append(id_value)

	var first_card: Node = cards.get_child(0)
	var picked_id: String = String(first_card.get_meta("skill_id", ""))
	var choose_button: Button = first_card.find_child("ChooseButton", true, false) as Button
	assert_object(choose_button).is_not_null()
	choose_button.pressed.emit()
	await runner.simulate_frames(2)

	assert_bool(main.get_tree().paused).is_false()
	assert_bool(choice_ui.visible).is_false()
	assert_str(player.slot_skill_id(1)).is_equal(picked_id)
	# Slot 0's own skill is untouched by picking a new slot 1 skill.
	assert_str(player.slot_skill_id(0)).is_equal(MELEE_SKILL_ID)

	await _free_main(runner, main)


## After a W pick, casting slot 1 (via [method Player.cast_at]'s slot
## parameter — the same seam main.gd's own cast_secondary handler calls) fires
## and kills a monster, proving the whole W cast path (unlock check, per-slot
## cooldown, cast core, damage resolution) end to end.
func test_w_cast_kills_a_monster_after_reaching_level_10() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_slots_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	var monsters: Node3D = main.get_node("Monsters")
	await runner.simulate_frames(2)

	player.gain_xp(_level_n_xp(10))
	await runner.simulate_frames(2)
	# Grant the ranged skill to slot 1 directly (bypassing the RNG offer/UI is
	# the documented seam for driving a slot deterministically, mirroring
	# [Player.add_support]'s test seam — docs/0022).
	var skill_catalog: SkillCatalog = SkillCatalog.new(BalanceData.load_skills())
	player.set_slot_skill(1, skill_catalog.skill(RANGED_SKILL_ID))
	assert_str(player.slot_skill_id(1)).is_equal(RANGED_SKILL_ID)

	var monster: Monster = (load("res://scenes/monster/monster.tscn") as PackedScene).instantiate() as Monster
	var calculator: DamageCalculator = DamageCalculator.new(RngService.new(SLOT_SEED))
	var combat_constants: Dictionary = BalanceData.load_combat().get("combat", {})
	monster.position = player.global_position + Vector3(0, 0, -5)
	monsters.add_child(monster)
	monster.setup(BalanceData.monster("fallen_imp"), combat_constants, calculator, player)
	await runner.simulate_frames(1)

	var frames: int = 0
	while frames < TIMEOUT_FRAMES and is_instance_valid(monster):
		player.cast_at(monster.global_position, 1)
		await runner.simulate_frames(STEP_FRAMES)
		frames += STEP_FRAMES

	assert_bool(is_instance_valid(monster)).is_false()
	await _free_main(runner, main)


## Cooldowns are independent per slot (the ticket's explicit requirement): W on
## cooldown must never block a Q cast, and vice versa.
func test_cooldowns_are_independent_between_slots() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_slots_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	player.gain_xp(_level_n_xp(10))
	await runner.simulate_frames(2)
	var skill_catalog: SkillCatalog = SkillCatalog.new(BalanceData.load_skills())
	player.set_slot_skill(1, skill_catalog.skill(RANGED_SKILL_ID))

	var aim: Vector3 = player.global_position + Vector3(0, 0, -5)
	# Cast Q, immediately putting slot 0 on cooldown.
	player.cast_at(aim, 0)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(1)

	# A second Q cast in the same frame is on cooldown and silently ignored.
	player.cast_at(aim, 0)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(1)

	# W (slot 1), never cast yet, is unaffected by Q's cooldown.
	player.cast_at(aim, 1)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(2)

	await _free_main(runner, main)


## G8's supports are global (docs/0021) — G9 must not regress that: a support
## granted while slot 0 is equipped still fans out extra projectiles when
## slot 2 (E) is the one casting, mirroring
## test_support_choice.gd's `added_projectiles` case but for a non-primary slot.
func test_a_support_applies_when_casting_from_slot_e() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_slots_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	player.gain_xp(_level_n_xp(20))
	await runner.simulate_frames(2)
	assert_int(player.level()).is_equal(20)
	assert_bool(player.is_slot_unlocked(2)).is_true()

	var skill_catalog: SkillCatalog = SkillCatalog.new(BalanceData.load_skills())
	player.set_slot_skill(2, skill_catalog.skill(RANGED_SKILL_ID))
	player.add_support("added_projectiles")

	var aim: Vector3 = player.global_position + Vector3(0, 0, -5)
	player.cast_at(aim, 2)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(2)

	await _free_main(runner, main)


## A locked slot behaves exactly like an on-cooldown one: casting it is a
## silent no-op, never an error, before its unlock level is reached.
func test_casting_a_locked_slot_is_a_silent_no_op() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_slots_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	assert_bool(player.is_slot_unlocked(1)).is_false()
	var aim: Vector3 = player.global_position + Vector3(0, 0, -5)
	player.cast_at(aim, 1)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(0)

	await _free_main(runner, main)
