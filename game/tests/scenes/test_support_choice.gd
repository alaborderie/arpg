extends GdUnitTestSuite
## Scene-level integration tests for G8 (issue #15): the level-up support-pick
## screen, a pipeline support changing projectile count, a stat support
## changing an observable number, and owned supports surviving a save/reload.
##
## Style follows test_skill_choice.gd/test_xp_progression.gd: a pre-configured
## scene instance, scene_runner driving the real engine loop, manual disposal.
## Unlike every other scene suite in this project, the first test here
## deliberately does NOT pin `skip_support_offers` — the picker/pause flow is
## exactly what it exercises (the same "don't pin the new knob in the one
## suite that tests it" precedent test_skill_choice.gd set for
## `starting_skill_id`).

const SUPPORT_SEED: int = 41
const RANGED_SKILL_ID: String = "fireball"


func before_test() -> void:
	SaveStore.delete()
	SyncConfig.enabled = false


func after_test() -> void:
	SaveStore.delete()
	SyncConfig.enabled = true
	# The picker test leaves the (process-wide) SceneTree paused on purpose;
	# unpause it so it never leaks into a later, unrelated test (same idiom
	# test_skill_choice.gd's after_test uses).
	get_tree().paused = false


## Instantiates main.tscn on a quiet map (no monsters needed — these tests
## drive XP/support grants directly), pinned to skip the one-shot skill-choice
## screen so only the support picker's pause is ever in play.
func _support_main(skill_id: String = "quick_strike") -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.set("rng_seed", SUPPORT_SEED)
	instance.set("starting_skill_id", skill_id)
	instance.get_node("MonsterSpawner").set("target_population", 0)
	return instance


## A fresh, unseeded instance: rng_seed stays 0, the same as a real boot, so
## _ready's "load the save if one exists" path is exercised for real (same
## idiom as test_save_load.gd's `_fresh_main`) — an explicit non-zero
## `rng_seed` (as `_support_main` above pins) always wins over a save on disk,
## so testing the reload path needs a genuinely unpinned instance.
func _reload_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
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


func _level_2_xp() -> int:
	var progression: ProgressionCurve = ProgressionCurve.new(
		BalanceData.load_progression().get("progression", {})
	)
	return progression.xp_required_for_level(2)


func test_level_up_shows_the_support_picker_and_pauses_the_tree() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_support_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	assert_bool(main.get_tree().paused).is_false()
	player.gain_xp(_level_2_xp())
	await runner.simulate_frames(2)

	assert_int(player.level()).is_equal(2)
	assert_bool(main.get_tree().paused).is_true()
	var choice_ui: SupportChoiceUI = main.get_node("SupportChoiceUI")
	assert_bool(choice_ui.visible).is_true()

	var cards: HBoxContainer = choice_ui.get_node("Center/Layout/Cards")
	assert_int(cards.get_child_count()).is_equal(3)
	var first_card: Node = cards.get_child(0)
	var picked_id: String = String(first_card.get_meta("support_id", ""))
	assert_bool(picked_id.is_empty()).is_false()

	var choose_button: Button = first_card.find_child("ChooseButton", true, false) as Button
	assert_object(choose_button).is_not_null()
	choose_button.pressed.emit()
	await runner.simulate_frames(2)

	assert_bool(main.get_tree().paused).is_false()
	assert_bool(choice_ui.visible).is_false()
	var owned: Array[String] = player.owned_supports()
	assert_int(owned.size()).is_equal(1)
	assert_str(owned[0]).is_equal(picked_id)

	await _free_main(runner, main)


## The ticket's headline pipeline case: picking `added_projectiles` (granted
## directly via [method Player.add_support], the same seam
## `_on_support_chosen` calls — bypassing the RNG offer/UI is the correct way
## to drive this deterministically, not a shortcut around it) then casting a
## ranged skill spawns 2 projectiles instead of 1.
func test_picking_added_projectiles_then_casting_spawns_two_projectiles() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_support_main(RANGED_SKILL_ID))
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var aim: Vector3 = player.global_position + Vector3(0, 0, -5)
	player.cast_at(aim)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(1)
	# Let the baseline cast's projectile finish its flight (well under a
	# second at fireball's 18 m/s over its 9 m range) AND its cooldown fully
	# expire (fireball's actions_per_second 0.6 -> ~1.667 s, ~100 physics
	# frames) before casting again — otherwise the second cast_at below would
	# be silently ignored (on cooldown) rather than proving anything about
	# added_projectiles.
	await runner.simulate_frames(400)
	assert_int(_count_projectiles(main)).is_equal(0)

	player.add_support("added_projectiles")
	player.cast_at(aim)
	await runner.simulate_frames(1)
	assert_int(_count_projectiles(main)).is_equal(2)

	await _free_main(runner, main)


## A stat support changes an observable number: `increased_damage` raises the
## composed attack profile's base_min/base_max (read straight off
## [method Player.attack_profile], the same public getter combat already
## exposes) rather than anything internal-only.
func test_a_stat_support_changes_an_observable_number() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_support_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var base_min_before: int = player.attack_profile().base_min
	var base_max_before: int = player.attack_profile().base_max
	assert_int(base_min_before).is_greater(0)

	player.add_support("increased_damage")
	await runner.simulate_frames(1)

	assert_int(player.attack_profile().base_min).is_greater(base_min_before)
	assert_int(player.attack_profile().base_max).is_greater(base_max_before)

	await _free_main(runner, main)


## Save round trip (docs/0021, mirroring test_save_load.gd's real
## save-then-reload idiom): owned supports (duplicates included) survive
## through a genuine `_save_game`/`SaveStore.load()` cycle into a second,
## independent main instance.
func test_owned_supports_persist_through_save_and_reload() -> void:
	var runner1: GdUnitSceneRunner = scene_runner(_support_main())
	var main1: Node3D = runner1.scene()
	var player1: Player = main1.get_node("Player")
	await runner1.simulate_frames(2)

	player1.add_support("increased_damage")
	player1.add_support("increased_damage")
	player1.add_support("life_on_kill")
	main1.call("_save_game")
	await runner1.simulate_frames(1)
	main1.queue_free()
	await runner1.simulate_frames(1)

	var runner2: GdUnitSceneRunner = scene_runner(_reload_main())
	var main2: Node3D = runner2.scene()
	var player2: Player = main2.get_node("Player")
	await runner2.simulate_frames(2)

	var owned: Array[String] = player2.owned_supports()
	assert_int(owned.size()).is_equal(3)
	assert_int(owned.count("increased_damage")).is_equal(2)
	assert_int(owned.count("life_on_kill")).is_equal(1)

	await _free_main(runner2, main2)
