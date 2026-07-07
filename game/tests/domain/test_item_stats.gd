extends GdUnitTestSuite
## Unit tests for [ItemStats] — turning one rolled item + its base into the
## contribution Dictionary [PlayerStats] consumes.

const SWORD_BASE: Dictionary = {
	"id": "sword",
	"name": "Sword",
	"slot": "weapon",
	"implicit": {"damage": {"type": "physical", "base_min": 3, "base_max": 6}},
}

const VEST_BASE: Dictionary = {
	"id": "vest",
	"name": "Vest",
	"slot": "armor",
	"implicit": {"armor": 4},
}


func test_plain_weapon_contributes_its_implicit_damage() -> void:
	var item: Dictionary = {"base_id": "sword", "slot": "weapon", "affixes": []}
	var contribution: Dictionary = ItemStats.contribution(item, SWORD_BASE)
	var damage: Dictionary = contribution.get("damage", {})
	assert_str(String(damage.get("type", ""))).is_equal("physical")
	assert_int(int(damage.get("base_min", 0))).is_equal(3)
	assert_int(int(damage.get("base_max", 0))).is_equal(6)
	# No armor/speed/crit/resist keys for a bare weapon.
	assert_bool(contribution.has("armor")).is_false()
	assert_bool(contribution.has("attack_speed_pct")).is_false()
	assert_bool(contribution.has("resistances")).is_false()


func test_damage_affixes_apply_flat_then_percent() -> void:
	var item: Dictionary = {
		"base_id": "sword",
		"slot": "weapon",
		"affixes": [
			{"id": "jagged", "stat": "added_damage", "value": 2},
			{"id": "gleaming", "stat": "increased_damage_pct", "value": 20},
		],
	}
	var damage: Dictionary = ItemStats.contribution(item, SWORD_BASE).get("damage", {})
	# (3 + 2) * 1.2 = 6, (6 + 2) * 1.2 = 9.6 -> 10 (rounded).
	assert_int(int(damage.get("base_min", 0))).is_equal(6)
	assert_int(int(damage.get("base_max", 0))).is_equal(10)


func test_armor_piece_sums_implicit_and_affix_armor_and_resistances() -> void:
	var item: Dictionary = {
		"base_id": "vest",
		"slot": "armor",
		"affixes": [
			{"id": "stony", "stat": "added_armor", "value": 5},
			{"id": "of_the_salamander", "stat": "fire_resistance", "value": 25},
		],
	}
	var contribution: Dictionary = ItemStats.contribution(item, VEST_BASE)
	assert_int(int(contribution.get("armor", 0))).is_equal(9)
	var resistances: Dictionary = contribution.get("resistances", {})
	assert_int(int(resistances.get("fire", 0))).is_equal(25)
	assert_bool(contribution.has("damage")).is_false()


func test_speed_and_crit_affixes_pass_through_as_percentages() -> void:
	var item: Dictionary = {
		"base_id": "sword",
		"slot": "weapon",
		"affixes": [
			{"id": "of_alacrity", "stat": "attack_speed_pct", "value": 10},
			{"id": "of_precision", "stat": "crit_chance_pct", "value": 2},
		],
	}
	var contribution: Dictionary = ItemStats.contribution(item, SWORD_BASE)
	assert_float(float(contribution.get("attack_speed_pct", 0.0))).is_equal_approx(10.0, 0.0001)
	assert_float(float(contribution.get("crit_chance_pct", 0.0))).is_equal_approx(2.0, 0.0001)


func test_unknown_stat_is_ignored() -> void:
	var item: Dictionary = {
		"base_id": "vest",
		"slot": "armor",
		"affixes": [{"id": "weird", "stat": "not_a_stat", "value": 999}],
	}
	var contribution: Dictionary = ItemStats.contribution(item, VEST_BASE)
	assert_int(int(contribution.get("armor", 0))).is_equal(4)
	assert_int(contribution.size()).is_equal(1)
