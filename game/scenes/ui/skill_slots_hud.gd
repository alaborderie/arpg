class_name SkillSlotsHUD
extends CanvasLayer
## The G9 (issue #16, docs/0022) slot HUD: 3 small boxes near the XP bar — Q,
## W, E — each showing the bound skill's name/element, a dimmed look while
## that slot cools down, or (before it unlocks) the level it needs. Display
## only: no mouse/touch interaction, same as [XPBar].
##
## Adapter (ADR 0003): a dumb view over [Player]'s slot state — no game rules
## here, just formatting three Dictionaries/floats into labels and a tint.
##
## Unlike every other dumb view in this project ([InventoryPanel]/[XPBar]:
## redraw once, on a signal), this one polls every frame in [method _process].
## A cooldown is continuous state with no discrete "changed" event to hook —
## nothing fires "slot 1's cooldown ticked down a bit" — so three cheap
## label/modulate writes per frame is simpler and cheaper than inventing one.

## Dim level while a slot is on cooldown — subtle, still fully readable.
const COOLING_ALPHA: float = 0.55
## Dim level for a slot that hasn't unlocked yet — noticeably faded.
const LOCKED_ALPHA: float = 0.35

var _player: Player

@onready var _slot_panels: Array[PanelContainer] = [
	$Panel/Margin/Layout/SlotQ, $Panel/Margin/Layout/SlotW, $Panel/Margin/Layout/SlotE,
]


## Binds the HUD to [param player]. Called by main once the scene is composed.
func setup(player: Player) -> void:
	_player = player
	_refresh()


func _process(_delta: float) -> void:
	_refresh()


func _refresh() -> void:
	if _player == null:
		return
	for slot: int in _slot_panels.size():
		_refresh_slot(slot)


## Redraws one slot's panel: the locked label ("Lv N"), the unlocked-but-unpicked
## placeholder ("?" — reachable right after a level-10/20 crossing, before the
## reward queue's pick screen has actually been resolved), or the bound skill's
## name/element, dimmed while that slot's cooldown is still ticking down.
func _refresh_slot(slot: int) -> void:
	var panel: PanelContainer = _slot_panels[slot]
	var label: Label = panel.get_node("Label") as Label
	if not _player.is_slot_unlocked(slot):
		label.text = "Lv %d" % _player.slot_unlock_level(slot)
		panel.modulate = Color(1.0, 1.0, 1.0, LOCKED_ALPHA)
		return
	var skill: Dictionary = _player.slot_skill(slot)
	if skill.is_empty():
		label.text = "?"
		panel.modulate = Color(1.0, 1.0, 1.0, 1.0)
		return
	var name_text: String = String(skill.get("name", "?"))
	var element: String = String(skill.get("element", "physical")).capitalize()
	label.text = "%s\n%s" % [name_text, element]
	var cooling: bool = _player.slot_cooldown_fraction(slot) > 0.0
	panel.modulate = Color(1.0, 1.0, 1.0, COOLING_ALPHA if cooling else 1.0)
