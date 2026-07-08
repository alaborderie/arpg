class_name SupportChoiceUI
extends CanvasLayer
## The G8 level-up support-choice screen: shown after most level-ups, offering
## three (possibly repeated — see docs/0021) support cards (name, description,
## value). Mirrors [SkillChoiceUI] almost exactly (docs/0016) — same Button/
## emulate-mouse-from-touch input path, same pause idiom.
##
## Adapter (ADR 0003): a dumb view over whatever offer [SupportCatalog.offer]
## produced — no randomness, no game rules here, just rendering three
## Dictionaries and reporting which one got clicked.
##
## Pause idiom (docs/0021, following docs/0016): `process_mode` is ALWAYS (set
## on this CanvasLayer in support_choice_ui.tscn; children inherit it), so this
## panel keeps responding to input while main.gd sets `get_tree().paused = true`
## for everything else. Unlike the one-shot skill choice screen, this one can
## show again immediately after a pick (main.gd's queued-offers idiom, docs/0021)
## if a big XP grant crossed several eligible levels at once — [method setup]
## is safe to call again while already visible.

## Card size; same footprint as SkillChoiceUI.CARD_SIZE.
const CARD_SIZE: Vector2 = Vector2(220.0, 260.0)

## Emitted once, when a card is chosen. [param support_id] is the picked
## support's `shared/supports.json` id; main.gd applies it via
## [method Player.add_support] and either shows the next queued offer or
## unpauses the tree.
signal support_chosen(support_id: String)

@onready var _cards: HBoxContainer = $Center/Layout/Cards


func _ready() -> void:
	visible = false


## Populates the three cards from [param offer] (see [SupportCatalog.offer])
## and shows the panel. Called by main.gd right before it pauses the tree (or
## right after a previous pick, if another offer is already queued).
func setup(offer: Array[Dictionary]) -> void:
	for child: Node in _cards.get_children():
		_cards.remove_child(child)
		child.queue_free()
	for support: Dictionary in offer:
		_cards.add_child(_make_card(support))
	visible = true


func _make_card(support: Dictionary) -> PanelContainer:
	var support_id: String = String(support.get("id", ""))
	var card: PanelContainer = PanelContainer.new()
	card.custom_minimum_size = CARD_SIZE
	# Exposed for tests (see test_support_choice.gd): which support this card
	# offers, without reaching into the button hierarchy to infer it.
	card.set_meta("support_id", support_id)

	var margin: MarginContainer = MarginContainer.new()
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_%s" % side, 12)
	card.add_child(margin)

	var layout: VBoxContainer = VBoxContainer.new()
	layout.add_theme_constant_override("separation", 6)
	margin.add_child(layout)

	var name_label: Label = Label.new()
	name_label.text = String(support.get("name", "?"))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	layout.add_child(name_label)

	var description_label: Label = Label.new()
	description_label.text = String(support.get("description", ""))
	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	layout.add_child(description_label)

	layout.add_child(_info_label(_value_text(support)))

	var spacer: Control = Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(spacer)

	var choose: Button = Button.new()
	choose.name = "ChooseButton"
	choose.text = "Choose"
	choose.pressed.connect(_on_choose_pressed.bind(support_id))
	layout.add_child(choose)

	return card


## Formats [param support]'s `value` as a percentage when its `stat` key ends
## in `_pct` (every `PlayerStats.compose` percentage rule, docs/0021), or as a
## flat "+N" otherwise (`added_flat_damage`, `life_on_kill`, `added_projectiles`).
func _value_text(support: Dictionary) -> String:
	var stat: String = String(support.get("stat", ""))
	var value: float = float(support.get("value", 0))
	if stat.ends_with("_pct"):
		return "+%.0f%%" % value
	return "+%d" % int(value)


func _info_label(text: String) -> Label:
	var label: Label = Label.new()
	label.text = text
	return label


func _on_choose_pressed(support_id: String) -> void:
	visible = false
	support_chosen.emit(support_id)
