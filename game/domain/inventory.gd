class_name Inventory
extends RefCounted
## The player's bag and equipment slots.
##
## Domain class (ADR 0003): pure state + rules, no Nodes. Items are the plain
## rolled-item Dictionaries [LootRoller] produces; the whole state is
## Dictionaries/Arrays end to end, so M4 can persist it as-is.
##
## One item per slot (`weapon`, `armor` — whatever `slot` values the data ships).
## Equipping from the bag swaps with whatever occupied the slot.

## Bag capacity; the grid UI shows exactly this many cells.
const DEFAULT_CAPACITY: int = 24

var _capacity: int
## Bag contents, in pickup order.
var _bag: Array[Dictionary] = []
## slot name -> equipped item.
var _equipped: Dictionary = {}


func _init(capacity: int = DEFAULT_CAPACITY) -> void:
	_capacity = maxi(1, capacity)


func capacity() -> int:
	return _capacity


func is_full() -> bool:
	return _bag.size() >= _capacity


func bag() -> Array[Dictionary]:
	return _bag


## Adds [param item] to the bag. Returns false (and drops nothing in) when the
## bag is full or the item has no slot to ever equip into.
func add(item: Dictionary) -> bool:
	if is_full() or String(item.get("slot", "")).is_empty():
		return false
	_bag.append(item)
	return true


## Equips the bag item at [param index] into its slot, swapping any previous
## occupant back into the same bag position. Returns false on a bad index.
func equip_bag_index(index: int) -> bool:
	if index < 0 or index >= _bag.size():
		return false
	var item: Dictionary = _bag[index]
	var slot: String = String(item.get("slot", ""))
	if slot.is_empty():
		return false
	var previous: Dictionary = _equipped.get(slot, {}) as Dictionary
	_equipped[slot] = item
	if previous.is_empty():
		_bag.remove_at(index)
	else:
		_bag[index] = previous
	return true


## Moves the item equipped in [param slot] back to the bag. Returns false when
## the slot is empty or the bag has no room.
func unequip(slot: String) -> bool:
	var item: Dictionary = _equipped.get(slot, {}) as Dictionary
	if item.is_empty() or is_full():
		return false
	_equipped.erase(slot)
	_bag.append(item)
	return true


## The item equipped in [param slot], or an empty Dictionary.
func equipped(slot: String) -> Dictionary:
	return _equipped.get(slot, {}) as Dictionary


## Every equipped item, in deterministic slot-name order.
func equipped_items() -> Array[Dictionary]:
	var items: Array[Dictionary] = []
	var slots: Array = _equipped.keys()
	slots.sort()
	for slot: Variant in slots:
		items.append(_equipped.get(slot, {}) as Dictionary)
	return items
