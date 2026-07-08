extends GdUnitTestSuite
## Scene-level integration test for G2's skill-choice screen: a fresh game (no
## save, no `starting_skill_id` pin) must show three distinct skill cards and
## pause the whole tree, and picking one must apply that skill and resume play.
##
## Style follows test_loot.gd/test_combat.gd: a pre-configured scene instance,
## scene_runner driving the real engine loop, manual disposal. Unlike those
## suites this one deliberately does NOT pin `starting_skill_id` — the choice
## screen is exactly what it exercises — but it does pin the spawner to a quiet
## map (population 0), since nothing here needs monsters and G1's guidance is
## to pin them in every new scene test.

## Frames simulated per polling step while waiting for an outcome.
const STEP_FRAMES: int = 10


func before_test() -> void:
	# A fresh game is only "fresh" with no save on disk (see main.gd's _ready:
	# rng_seed == 0 and SaveStore.has_save() decides whether the choice screen
	# even has a chance to show). Also keeps this suite hermetic and
	# independent of network timing, same idiom every other scene suite uses.
	SaveStore.delete()
	SyncConfig.enabled = false


func after_test() -> void:
	SaveStore.delete()
	SyncConfig.enabled = true
	# test_fresh_game_offers_three_distinct_skills_and_pauses_the_tree leaves
	# the (process-wide) SceneTree paused on purpose; unpause it so a paused
	# tree never leaks into a later, unrelated test.
	get_tree().paused = false


## A genuinely fresh boot: rng_seed stays 0 (the "randomize, or load a save"
## default) and starting_skill_id stays "" (the default), so main.gd's _ready
## has no way to skip the choice screen — this is deliberately the one suite
## that does NOT pin either.
func _fresh_main() -> Node3D:
	var packed: PackedScene = load("res://scenes/main/main.tscn")
	var instance: Node3D = packed.instantiate() as Node3D
	instance.get_node("MonsterSpawner").set("target_population", 0)
	return instance


func _free_main(runner: GdUnitSceneRunner, main: Node3D) -> void:
	main.queue_free()
	await runner.simulate_frames(1)


func test_fresh_game_offers_three_distinct_skills_and_pauses_the_tree() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_fresh_main())
	var main: Node3D = runner.scene()
	await runner.simulate_frames(2)

	assert_bool(main.get_tree().paused).is_true()
	var choice_ui: SkillChoiceUI = main.get_node("SkillChoiceUI")
	assert_bool(choice_ui.visible).is_true()

	var cards: HBoxContainer = choice_ui.get_node("Center/Layout/Cards")
	assert_int(cards.get_child_count()).is_equal(3)
	var ids: Array[String] = []
	for card: Node in cards.get_children():
		ids.append(String(card.get_meta("skill_id", "")))
	assert_int(ids.size()).is_equal(3)
	for id_value: String in ids:
		assert_bool(id_value.is_empty()).is_false()
		assert_int(ids.count(id_value)).is_equal(1)

	await _free_main(runner, main)


func test_picking_a_card_applies_the_skill_and_resumes_play() -> void:
	var runner: GdUnitSceneRunner = scene_runner(_fresh_main())
	var main: Node3D = runner.scene()
	var player: Player = main.get_node("Player")
	await runner.simulate_frames(2)

	var choice_ui: SkillChoiceUI = main.get_node("SkillChoiceUI")
	var cards: HBoxContainer = choice_ui.get_node("Center/Layout/Cards")
	var first_card: Node = cards.get_child(0)
	var picked_id: String = String(first_card.get_meta("skill_id", ""))
	var choose_button: Button = first_card.find_child("ChooseButton", true, false) as Button
	assert_object(choose_button).is_not_null()

	choose_button.pressed.emit()
	await runner.simulate_frames(STEP_FRAMES)

	assert_bool(main.get_tree().paused).is_false()
	assert_bool(choice_ui.visible).is_false()
	assert_str(player.skill_id()).is_equal(picked_id)

	await _free_main(runner, main)
