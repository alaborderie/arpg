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
