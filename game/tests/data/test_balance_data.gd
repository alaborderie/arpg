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
