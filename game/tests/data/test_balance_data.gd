extends GdUnitTestSuite
## Tests for [BalanceData] — the adapter that reads `res://shared/*.json`.
##
## These double as a canary for the `game/shared -> ../shared` symlink (ADR 0008):
## if a checkout loses the link, every case here fails with an open error.


func test_player_config_loads() -> void:
	var doc: Dictionary = BalanceData.load_player()
	assert_bool(doc.is_empty()).is_false()
	assert_int(int(doc.get("schema_version", 0))).is_greater_equal(1)


func test_player_move_speed_is_positive() -> void:
	var player: Dictionary = BalanceData.load_player().get("player", {})
	assert_float(float(player.get("move_speed", 0.0))).is_greater(0.0)


func test_monsters_config_loads() -> void:
	var doc: Dictionary = BalanceData.load_monsters()
	assert_bool(doc.is_empty()).is_false()
	var monsters: Array = doc.get("monsters", [])
	assert_int(monsters.size()).is_greater_equal(1)


func test_player_has_combat_stats() -> void:
	var player: Dictionary = BalanceData.load_player().get("player", {})
	assert_int(int(player.get("max_health", 0))).is_greater(0)
	var damage: Dictionary = player.get("damage", {})
	assert_int(int(damage.get("base_max", 0))).is_greater(0)
	assert_float(float(player.get("attack_speed", 0.0))).is_greater(0.0)
	assert_float(float(player.get("attack_range", 0.0))).is_greater(0.0)


func test_combat_constants_load() -> void:
	var combat: Dictionary = BalanceData.load_combat().get("combat", {})
	assert_bool(combat.is_empty()).is_false()
	assert_float(float(combat.get("armor_constant", 0.0))).is_greater(0.0)


func test_monster_lookup_by_id_finds_the_m2_monster() -> void:
	var imp: Dictionary = BalanceData.monster("fallen_imp")
	assert_bool(imp.is_empty()).is_false()
	assert_str(String(imp.get("ai", ""))).is_equal("melee_chaser")
	assert_int(int(imp.get("max_health", 0))).is_greater(0)


func test_items_config_loads() -> void:
	var doc: Dictionary = BalanceData.load_items()
	assert_bool(doc.is_empty()).is_false()
	var bases: Array = doc.get("bases", [])
	var affixes: Array = doc.get("affixes", [])
	assert_int(bases.size()).is_greater_equal(1)
	assert_int(affixes.size()).is_greater_equal(1)


func test_loot_tables_config_loads() -> void:
	var doc: Dictionary = BalanceData.load_loot_tables()
	assert_bool(doc.is_empty()).is_false()
	var rarities: Array = doc.get("rarities", [])
	var tables: Array = doc.get("tables", [])
	assert_int(rarities.size()).is_greater_equal(1)
	assert_int(tables.size()).is_greater_equal(1)


func test_loot_tables_reference_only_known_monsters_and_bases() -> void:
	# Cross-file referential integrity the JSON Schemas cannot express: every
	# `monster_id` must exist in monsters.json, every `base_pool` id in items.json.
	var monster_ids: Array[String] = []
	var monsters: Array = BalanceData.load_monsters().get("monsters", [])
	for entry: Variant in monsters:
		monster_ids.append(String((entry as Dictionary).get("id", "")))
	var base_ids: Array[String] = []
	var bases: Array = BalanceData.load_items().get("bases", [])
	for entry: Variant in bases:
		base_ids.append(String((entry as Dictionary).get("id", "")))

	var tables: Array = BalanceData.load_loot_tables().get("tables", [])
	for entry: Variant in tables:
		var table: Dictionary = entry as Dictionary
		assert_array(monster_ids).contains([String(table.get("monster_id", ""))])
		var pool: Array = table.get("base_pool", [])
		for pooled: Variant in pool:
			assert_array(base_ids).contains([String(pooled)])


func test_every_monster_has_a_loot_table() -> void:
	# Not a hard rule forever, but with two monsters both should drop; a missing
	# table is far more likely a typo than a design choice today.
	var table_ids: Array[String] = []
	var tables: Array = BalanceData.load_loot_tables().get("tables", [])
	for entry: Variant in tables:
		table_ids.append(String((entry as Dictionary).get("monster_id", "")))
	var monsters: Array = BalanceData.load_monsters().get("monsters", [])
	for entry: Variant in monsters:
		assert_array(table_ids).contains([String((entry as Dictionary).get("id", ""))])


func test_affix_ranges_are_ordered() -> void:
	var affixes: Array = BalanceData.load_items().get("affixes", [])
	for entry: Variant in affixes:
		var affix: Dictionary = entry as Dictionary
		assert_int(int(affix.get("max", -1))).is_greater_equal(int(affix.get("min", 0)))


## G3 (docs/0017): the XP/level curve data.
func test_progression_config_loads() -> void:
	var doc: Dictionary = BalanceData.load_progression()
	assert_bool(doc.is_empty()).is_false()
	var progression: Dictionary = doc.get("progression", {})
	assert_int(int(progression.get("max_level", 0))).is_greater(1)
	assert_float(float(progression.get("xp_base", 0.0))).is_greater(0.0)
	assert_float(float(progression.get("xp_growth", 0.0))).is_greater(1.0)
	assert_float(float(progression.get("level_bonus_pct", 0.0))).is_greater(0.0)
