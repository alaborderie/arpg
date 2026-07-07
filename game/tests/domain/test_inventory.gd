extends GdUnitTestSuite
## Unit tests for [Inventory] — bag capacity, equip swapping, unequip.


func _weapon(item_name: String = "Sword") -> Dictionary:
	return {"base_id": "sword", "name": item_name, "slot": "weapon", "rarity": "normal", "affixes": []}


func _armor(item_name: String = "Vest") -> Dictionary:
	return {"base_id": "vest", "name": item_name, "slot": "armor", "rarity": "normal", "affixes": []}


func test_add_appends_until_capacity() -> void:
	var inventory: Inventory = Inventory.new(2)
	assert_bool(inventory.add(_weapon())).is_true()
	assert_bool(inventory.is_full()).is_false()
	assert_bool(inventory.add(_armor())).is_true()
	assert_bool(inventory.is_full()).is_true()
	assert_bool(inventory.add(_weapon("Overflow"))).is_false()
	assert_int(inventory.bag().size()).is_equal(2)


func test_add_rejects_items_without_a_slot() -> void:
	var inventory: Inventory = Inventory.new()
	assert_bool(inventory.add({"name": "Mystery"})).is_false()
	assert_int(inventory.bag().size()).is_equal(0)


func test_equip_moves_item_from_bag_to_its_slot() -> void:
	var inventory: Inventory = Inventory.new()
	inventory.add(_weapon())
	assert_bool(inventory.equip_bag_index(0)).is_true()
	assert_int(inventory.bag().size()).is_equal(0)
	assert_str(String(inventory.equipped("weapon").get("name", ""))).is_equal("Sword")
	assert_bool(inventory.equipped("armor").is_empty()).is_true()


func test_equip_swaps_with_the_previous_occupant_in_place() -> void:
	var inventory: Inventory = Inventory.new()
	inventory.add(_weapon("Old Sword"))
	inventory.add(_armor())
	inventory.add(_weapon("New Sword"))
	inventory.equip_bag_index(0)
	assert_bool(inventory.equip_bag_index(1)).is_true()
	# "New Sword" (bag index 1) went on; "Old Sword" landed in its bag position.
	assert_str(String(inventory.equipped("weapon").get("name", ""))).is_equal("New Sword")
	assert_str(String(inventory.bag()[1].get("name", ""))).is_equal("Old Sword")
	assert_int(inventory.bag().size()).is_equal(2)


func test_equip_rejects_bad_indices() -> void:
	var inventory: Inventory = Inventory.new()
	assert_bool(inventory.equip_bag_index(0)).is_false()
	assert_bool(inventory.equip_bag_index(-1)).is_false()


func test_unequip_returns_the_item_to_the_bag() -> void:
	var inventory: Inventory = Inventory.new()
	inventory.add(_armor())
	inventory.equip_bag_index(0)
	assert_bool(inventory.unequip("armor")).is_true()
	assert_bool(inventory.equipped("armor").is_empty()).is_true()
	assert_str(String(inventory.bag()[0].get("name", ""))).is_equal("Vest")


func test_unequip_fails_on_empty_slot_or_full_bag() -> void:
	var inventory: Inventory = Inventory.new(1)
	assert_bool(inventory.unequip("weapon")).is_false()
	inventory.add(_weapon())
	inventory.equip_bag_index(0)
	inventory.add(_armor())
	# Bag is full (capacity 1), so the weapon has nowhere to go.
	assert_bool(inventory.unequip("weapon")).is_false()
	assert_str(String(inventory.equipped("weapon").get("name", ""))).is_equal("Sword")


func test_equipped_items_lists_slots_in_stable_order() -> void:
	var inventory: Inventory = Inventory.new()
	inventory.add(_weapon())
	inventory.add(_armor())
	inventory.equip_bag_index(0)
	inventory.equip_bag_index(0)
	var equipped: Array[Dictionary] = inventory.equipped_items()
	assert_int(equipped.size()).is_equal(2)
	# Sorted by slot name: armor before weapon.
	assert_str(String(equipped[0].get("slot", ""))).is_equal("armor")
	assert_str(String(equipped[1].get("slot", ""))).is_equal("weapon")
