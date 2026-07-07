class_name InventoryPanel
extends CanvasLayer
## The M3 inventory UI: a toggleable panel with two equipment slots and a bag grid.
##
## Adapter (ADR 0003): a dumb view over the player's [Inventory]. Every click maps
## 1:1 to a player call (`equip_bag_index`, `unequip_slot`) and the whole panel
## redraws on the player's `inventory_changed` signal — no inventory state lives
## here. Buttons consume their clicks before `_unhandled_input`, so interacting
## with the panel can never leak a move/attack order into the world (ADR 0010).
##
## Toggling: the `toggle_inventory` action (I key) for desktop, plus an always-
## visible Bag button for touch (taps ride the mouse-emulation path like all input).

## Bag cell size in pixels; sized for fat fingers on mobile.
const CELL_SIZE: Vector2 = Vector2(72.0, 72.0)

var _player: Player

@onready var _panel: PanelContainer = $Panel
@onready var _grid: GridContainer = $Panel/Margin/Layout/Grid
@onready var _weapon_slot: Button = $Panel/Margin/Layout/Slots/WeaponSlot
@onready var _armor_slot: Button = $Panel/Margin/Layout/Slots/ArmorSlot
@onready var _bag_button: Button = $BagButton


func _ready() -> void:
	_panel.visible = false
	_bag_button.pressed.connect(toggle)
	_weapon_slot.pressed.connect(_on_slot_pressed.bind("weapon"))
	_armor_slot.pressed.connect(_on_slot_pressed.bind("armor"))


## Binds the panel to [param player]. Called by main once the scene is composed.
func setup(player: Player) -> void:
	_player = player
	player.inventory_changed.connect(_refresh)
	_refresh()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_inventory"):
		toggle()


func is_open() -> bool:
	return _panel.visible


func toggle() -> void:
	_panel.visible = not _panel.visible
	if _panel.visible:
		_refresh()


## Redraws slots and bag from the player's inventory. Rebuild-from-scratch is
## plenty at 24 cells and keeps the view stateless.
func _refresh() -> void:
	if _player == null:
		return
	var inventory: Inventory = _player.inventory()
	_style_slot(_weapon_slot, "Weapon", inventory.equipped("weapon"))
	_style_slot(_armor_slot, "Armor", inventory.equipped("armor"))
	for child: Node in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var bag: Array[Dictionary] = inventory.bag()
	for index: int in inventory.capacity():
		_grid.add_child(_make_cell(bag, index))


func _make_cell(bag: Array[Dictionary], index: int) -> Button:
	var cell: Button = Button.new()
	cell.custom_minimum_size = CELL_SIZE
	cell.clip_text = true
	if index < bag.size():
		var item: Dictionary = bag[index]
		cell.text = String(item.get("name", "?"))
		cell.tooltip_text = _describe(item)
		cell.add_theme_color_override(
			"font_color", RarityColors.color_of(String(item.get("rarity", "normal")))
		)
		cell.pressed.connect(_on_bag_cell_pressed.bind(index))
	else:
		cell.disabled = true
	return cell


func _style_slot(slot_button: Button, label: String, item: Dictionary) -> void:
	if item.is_empty():
		slot_button.text = "%s: —" % label
		slot_button.tooltip_text = ""
		slot_button.remove_theme_color_override("font_color")
		return
	slot_button.text = "%s: %s" % [label, String(item.get("name", "?"))]
	slot_button.tooltip_text = _describe(item)
	slot_button.add_theme_color_override(
		"font_color", RarityColors.color_of(String(item.get("rarity", "normal")))
	)


## Multi-line tooltip: name, rarity, then one "stat +value" line per affix.
func _describe(item: Dictionary) -> String:
	var lines: Array[String] = [
		String(item.get("name", "?")),
		"%s %s" % [String(item.get("rarity", "normal")).capitalize(), String(item.get("slot", ""))],
	]
	var affixes: Array = item.get("affixes", [])
	for entry: Variant in affixes:
		var affix: Dictionary = entry as Dictionary
		lines.append("%s +%d" % [
			String(affix.get("stat", "")).capitalize(), int(affix.get("value", 0))
		])
	return "\n".join(lines)


func _on_bag_cell_pressed(index: int) -> void:
	_player.equip_bag_index(index)


func _on_slot_pressed(slot: String) -> void:
	_player.unequip_slot(slot)
