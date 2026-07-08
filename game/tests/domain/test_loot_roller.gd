extends GdUnitTestSuite
## Unit tests for [LootRoller] — deterministic loot rolls from plain Dictionaries
## shaped like `shared/loot_tables.json` / `shared/items.json`.
##
## The fixtures mirror those file shapes on purpose: adapters hand the parsed JSON
## straight in, so the shapes agreeing is the contract under test.

const ITEMS: Dictionary = {
	"bases": [
		{
			"id": "sword",
			"name": "Sword",
			"slot": "weapon",
			"implicit": {"damage": {"type": "physical", "base_min": 3, "base_max": 6}},
		},
		{"id": "vest", "name": "Vest", "slot": "armor", "implicit": {"armor": 4}},
	],
	"affixes": [
		{
			"id": "jagged", "name": "Jagged", "kind": "prefix",
			"stat": "added_damage", "min": 1, "max": 3, "slots": ["weapon"],
		},
		{
			"id": "of_alacrity", "name": "of Alacrity", "kind": "suffix",
			"stat": "attack_speed_pct", "min": 5, "max": 15, "slots": ["weapon"],
		},
		{
			"id": "stony", "name": "Stony", "kind": "prefix",
			"stat": "added_armor", "min": 3, "max": 8, "slots": ["armor"],
		},
	],
}

const TABLES: Dictionary = {
	"rarities": [
		{"id": "normal", "weight": 60, "affix_count_min": 0, "affix_count_max": 0},
		{"id": "magic", "weight": 30, "affix_count_min": 1, "affix_count_max": 2},
		{"id": "rare", "weight": 10, "affix_count_min": 3, "affix_count_max": 4},
	],
	"tables": [
		{"monster_id": "imp", "drop_chance": 0.5, "base_pool": ["sword", "vest"]},
		{"monster_id": "generous", "drop_chance": 1.0, "base_pool": ["sword", "vest"]},
		{"monster_id": "stingy", "drop_chance": 0.0, "base_pool": ["sword"]},
	],
}

## Affix id -> [min, max] from the fixture, for range assertions.
const AFFIX_RANGES: Dictionary = {
	"jagged": [1, 3],
	"of_alacrity": [5, 15],
	"stony": [3, 8],
}


func _roller(seed_value: int, tables: Dictionary = TABLES, items: Dictionary = ITEMS) -> LootRoller:
	return LootRoller.new(tables, items, RngService.new(seed_value))


func test_same_seed_and_kill_order_produces_identical_items() -> void:
	# The must-test of ADR 0004: two rollers, same seed, same kill sequence.
	var kills: Array[String] = ["imp", "generous", "imp", "generous", "imp"]
	var first: Array[Dictionary] = []
	var second: Array[Dictionary] = []
	var roller_a: LootRoller = _roller(1234)
	var roller_b: LootRoller = _roller(1234)
	for monster_id: String in kills:
		first.append(roller_a.roll_drop(monster_id))
		second.append(roller_b.roll_drop(monster_id))
	# Dictionary == compares by value recursively, so this checks every field of
	# every rolled item (base, rarity, affix ids and rolled values).
	assert_bool(first == second).is_true()


func test_drop_chance_one_always_drops() -> void:
	for seed_value: int in range(20):
		var item: Dictionary = _roller(seed_value).roll_drop("generous")
		assert_bool(item.is_empty()).is_false()


func test_drop_chance_zero_never_drops() -> void:
	for seed_value: int in range(20):
		assert_bool(_roller(seed_value).roll_drop("stingy").is_empty()).is_true()


func test_unknown_monster_drops_nothing() -> void:
	assert_bool(_roller(1).roll_drop("nonexistent").is_empty()).is_true()


func test_rolled_item_has_the_persistable_shape() -> void:
	var item: Dictionary = _roller(7).roll_drop("generous")
	assert_bool(item.has("base_id")).is_true()
	assert_bool(item.has("name")).is_true()
	assert_bool(item.has("slot")).is_true()
	assert_bool(item.has("rarity")).is_true()
	assert_bool(item.has("affixes")).is_true()
	assert_bool(String(item.get("slot", "")) == "weapon" or String(item.get("slot", "")) == "armor") \
		.is_true()


func test_affix_values_and_counts_stay_within_data_ranges() -> void:
	# Statistical sweep: every rolled affix value must sit inside its data range,
	# affix ids must be unique per item (no replacement), and the count must fit
	# the item's rarity (clamped to the slot's eligible pool).
	var roller: LootRoller = _roller(99)
	var seen_magic_or_rare: bool = false
	for _kill: int in range(200):
		var item: Dictionary = roller.roll_drop("generous")
		var rarity: String = String(item.get("rarity", ""))
		var affixes: Array = item.get("affixes", [])
		var eligible: int = 2 if String(item.get("slot", "")) == "weapon" else 1
		match rarity:
			"normal":
				assert_int(affixes.size()).is_equal(0)
			"magic":
				seen_magic_or_rare = true
				assert_int(affixes.size()).is_between(1, mini(2, eligible))
			"rare":
				seen_magic_or_rare = true
				assert_int(affixes.size()).is_equal(eligible)
		var seen_ids: Array[String] = []
		for entry: Variant in affixes:
			var affix: Dictionary = entry as Dictionary
			var affix_id: String = String(affix.get("id", ""))
			assert_bool(seen_ids.has(affix_id)).is_false()
			seen_ids.append(affix_id)
			var value_range: Array = AFFIX_RANGES.get(affix_id, [])
			assert_int(int(affix.get("value", -1))) \
				.is_between(int(value_range[0]), int(value_range[1]))
	assert_bool(seen_magic_or_rare).is_true()


func test_display_name_uses_first_prefix_and_suffix() -> void:
	# Single always-magic rarity with exactly 2 affixes on a weapon-only pool:
	# both weapon affixes (one prefix, one suffix) must appear around the base name.
	var tables: Dictionary = {
		"rarities": [{"id": "magic", "weight": 1, "affix_count_min": 2, "affix_count_max": 2}],
		"tables": [{"monster_id": "imp", "drop_chance": 1.0, "base_pool": ["sword"]}],
	}
	var item: Dictionary = _roller(5, tables).roll_drop("imp")
	assert_str(String(item.get("name", ""))).is_equal("Jagged Sword of Alacrity")


func test_base_lookup_resolves_rolled_items() -> void:
	var roller: LootRoller = _roller(3)
	var item: Dictionary = roller.roll_drop("generous")
	var base: Dictionary = roller.base(String(item.get("base_id", "")))
	assert_bool(base.is_empty()).is_false()
	assert_str(String(base.get("slot", ""))).is_equal(String(item.get("slot", "")))


## G7 (issue #14, docs/0020): rarities carrying an `elite_weight` column bias an
## elite kill's rarity pick without spending any extra RNG draws — same seed,
## same number of draws, just a different weight table feeding the one
## randi_range the normal roll already made.
const ELITE_TABLES: Dictionary = {
	"rarities": [
		{"id": "normal", "weight": 60, "elite_weight": 15, "affix_count_min": 0, "affix_count_max": 0},
		{"id": "magic", "weight": 30, "elite_weight": 45, "affix_count_min": 1, "affix_count_max": 2},
		{"id": "rare", "weight": 10, "elite_weight": 40, "affix_count_min": 3, "affix_count_max": 4},
	],
	"tables": [
		{"monster_id": "generous", "drop_chance": 1.0, "base_pool": ["sword", "vest"]},
	],
}


func test_elite_rolls_shift_the_rarity_distribution_toward_higher_tiers() -> void:
	# Two independent rollers, same seed, same kill count — one always rolling
	# normal kills, the other always elite — so any difference in the resulting
	# rarity distribution is attributable purely to the is_elite bias, not to
	# the RNG stream position (both rollers draw exactly the same shape of
	# sequence per kill: the bias only changes which weight column feeds the
	# rarity draw, per the class doc).
	const SAMPLES: int = 500
	var normal_roller: LootRoller = _roller(55, ELITE_TABLES)
	var elite_roller: LootRoller = _roller(55, ELITE_TABLES)
	var normal_counts: Dictionary = {"normal": 0, "magic": 0, "rare": 0}
	var elite_counts: Dictionary = {"normal": 0, "magic": 0, "rare": 0}
	for _i: int in SAMPLES:
		var normal_item: Dictionary = normal_roller.roll_drop("generous", false)
		var elite_item: Dictionary = elite_roller.roll_drop("generous", true)
		var normal_rarity: String = String(normal_item.get("rarity", ""))
		var elite_rarity: String = String(elite_item.get("rarity", ""))
		normal_counts[normal_rarity] = int(normal_counts.get(normal_rarity, 0)) + 1
		elite_counts[elite_rarity] = int(elite_counts.get(elite_rarity, 0)) + 1

	# The bias must measurably shift mass off "normal" and onto "magic"/"rare".
	assert_int(int(elite_counts["normal"])).is_less(int(normal_counts["normal"]))
	var normal_high_tier: int = int(normal_counts["magic"]) + int(normal_counts["rare"])
	var elite_high_tier: int = int(elite_counts["magic"]) + int(elite_counts["rare"])
	assert_int(elite_high_tier).is_greater(normal_high_tier)
	# Sanity bound against the fixture's exact weights: normal kills should land
	# close to the 60% normal / 40% magic+rare split, elite kills close to the
	# 15% normal / 85% magic+rare split (elite_weight column) — generous bands
	# so this isn't flaky, just confirms the shift is in the right ballpark.
	assert_float(float(normal_counts["normal"]) / SAMPLES).is_between(0.45, 0.75)
	assert_float(float(elite_counts["normal"]) / SAMPLES).is_between(0.05, 0.3)


func test_elite_flag_defaults_to_false_and_does_not_change_existing_seeds() -> void:
	# Backward compatibility: a caller that never passes is_elite (every call
	# site before G7) must roll byte-for-byte what it always rolled.
	var with_default: LootRoller = _roller(1234)
	var explicit_false: LootRoller = _roller(1234)
	var kills: Array[String] = ["imp", "generous", "imp", "generous", "imp"]
	for monster_id: String in kills:
		var a: Dictionary = with_default.roll_drop(monster_id)
		var b: Dictionary = explicit_false.roll_drop(monster_id, false)
		assert_bool(a == b).is_true()
