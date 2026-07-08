class_name SkillChoiceUI
extends CanvasLayer
## The G2 skill-choice screen: shown once, at the start of a new game, offering
## three distinct random skills as cards (name, element, kind, damage, range).
## Mouse and touch both work through the existing Button/emulate-mouse-from-touch
## path every other UI panel in this project already rides.
##
## Adapter (ADR 0003): a dumb view over whatever offer [SkillCatalog.offer]
## produced — no randomness, no game rules here, just rendering three
## Dictionaries and reporting which one got clicked.
##
## Pause idiom (docs/0016): `process_mode` is ALWAYS (set on this CanvasLayer in
## skill_choice_ui.tscn; children inherit it), so this panel keeps responding to
## input while main.gd sets `get_tree().paused = true` for everything else —
## the world (player, monsters, spawner) is frozen until a card is picked.

## Card size; touch-friendly, in the same spirit as InventoryPanel.CELL_SIZE.
const CARD_SIZE: Vector2 = Vector2(220.0, 260.0)

## Emitted once, when a card is chosen. [param skill_id] is the picked skill's
## `shared/skills.json` id; main.gd applies it and unpauses the tree.
signal skill_chosen(skill_id: String)

@onready var _cards: HBoxContainer = $Center/Layout/Cards


func _ready() -> void:
	visible = false


## Populates the three cards from [param offer] (see [SkillCatalog.offer]) and
## shows the panel. Called by main.gd right before it pauses the tree.
func setup(offer: Array[Dictionary]) -> void:
	for child: Node in _cards.get_children():
		_cards.remove_child(child)
		child.queue_free()
	for skill: Dictionary in offer:
		_cards.add_child(_make_card(skill))
	visible = true


func _make_card(skill: Dictionary) -> PanelContainer:
	var skill_id: String = String(skill.get("id", ""))
	var card: PanelContainer = PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	# Exposed for tests (see test_skill_choice.gd): which skill this card offers,
	# without reaching into the button hierarchy to infer it.
	card.set_meta("skill_id", skill_id)

	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 12)
	card.add_child(margin)

	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 6)
	margin.add_child(layout)

	var name_label: Label = Label.new()
	name_label.text = String(skill.get("name", "?"))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	layout.add_child(name_label)

	var element: String = String(skill.get("element", "physical")).capitalize()
	var kind: String = String(skill.get("kind", "melee")).capitalize()
	layout.add_child(_info_label("%s %s" % [element, kind]))
	layout.add_child(_info_label(
		"Damage: %d-%d" % [int(skill.get("base_min", 0)), int(skill.get("base_max", 0))]
	))
	layout.add_child(_info_label("Range: %.1fm" % float(skill.get("range", 0.0))))

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(spacer)

	var choose: Button = Button.new()
	choose.name = "ChooseButton"
	choose.text = "Choose"
	choose.pressed.connect(_on_choose_pressed.bind(skill_id))
	layout.add_child(choose)

	return card


func _info_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	return label


func _on_choose_pressed(skill_id: String) -> void:
	visible = false
	skill_chosen.emit(skill_id)
