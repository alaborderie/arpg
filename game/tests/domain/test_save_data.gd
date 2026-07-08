extends GdUnitTestSuite
## Unit tests for [SaveData] — envelope shape, migration and version rejection.


func _sample_bag() -> Array[Dictionary]:
	var bag: Array[Dictionary] = []
	bag.append({"base_id": "sword", "name": "Sword", "slot": "weapon", "rarity": "normal", "affixes": []})
	return bag


func _sample_equipped() -> Dictionary:
	return {
		"armor": {"base_id": "vest", "name": "Vest", "slot": "armor", "rarity": "normal", "affixes": []},
	}


func _sample_envelope() -> Dictionary:
	return SaveData.build(
		42, 7, 9, 55, Vector3(1.0, 0.0, -2.5), _sample_bag(), _sample_equipped(),
		"heavy_slash", 4, 57, 3, 1700000000
	)


func test_build_shapes_the_current_schema_version_envelope() -> void:
	var envelope: Dictionary = _sample_envelope()
	assert_int(int(envelope.get("schema_version", 0))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	assert_int(int(envelope.get("master_seed", 0))).is_equal(42)
	assert_int(int(envelope.get("combat_rng_state", 0))).is_equal(7)
	assert_int(int(envelope.get("loot_rng_state", 0))).is_equal(9)
	assert_int(int(envelope.get("saved_at_unix", 0))).is_equal(1700000000)
	var player: Dictionary = envelope.get("player", {})
	assert_int(int(player.get("health", 0))).is_equal(55)
	assert_int(int(player.get("level", 0))).is_equal(4)
	assert_int(int(player.get("xp", -1))).is_equal(57)
	assert_int(int(envelope.get("progress", {}).get("monsters_killed", -1))).is_equal(3)


func test_round_trip_through_migrate_preserves_every_field() -> void:
	var envelope: Dictionary = _sample_envelope()
	var migrated: Dictionary = SaveData.migrate(envelope)
	assert_bool(migrated.is_empty()).is_false()
	assert_int(int(migrated.get("schema_version", 0))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	assert_int(int(migrated.get("master_seed", 0))).is_equal(42)
	assert_int(int(migrated.get("combat_rng_state", 0))).is_equal(7)
	assert_int(int(migrated.get("loot_rng_state", 0))).is_equal(9)

	var position: Vector3 = SaveData.position_from_player(migrated)
	assert_bool(position.is_equal_approx(Vector3(1.0, 0.0, -2.5))).is_true()

	var bag: Array[Dictionary] = SaveData.bag_from_player(migrated)
	assert_int(bag.size()).is_equal(1)
	assert_str(String(bag[0].get("name", ""))).is_equal("Sword")

	var equipped: Dictionary = SaveData.equipped_from_player(migrated)
	assert_str(String((equipped.get("armor", {}) as Dictionary).get("name", ""))).is_equal("Vest")

	assert_str(SaveData.skill_id_from_player(migrated)).is_equal("heavy_slash")
	assert_int(SaveData.level_from_player(migrated)).is_equal(4)
	assert_int(SaveData.xp_from_player(migrated)).is_equal(57)

	var progress: Dictionary = migrated.get("progress", {})
	assert_int(int(progress.get("monsters_killed", -1))).is_equal(3)


func test_migrate_v0_fills_in_defaults_for_fields_it_lacked() -> void:
	# A scaffolded v0 save: only what predates the loot RNG split and progress
	# tracking (ADR 0011) existed — no loot_rng_state, no progress, no bag/equipped.
	var legacy: Dictionary = {
		"schema_version": 0,
		"saved_at_unix": 1600000000,
		"master_seed": 5,
		"combat_rng_state": 11,
		"player": {"health": 80, "position": {"x": 0.0, "y": 0.0, "z": 0.0}},
	}
	var migrated: Dictionary = SaveData.migrate(legacy)
	assert_bool(migrated.is_empty()).is_false()
	assert_int(int(migrated.get("schema_version", -1))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	# Defaulted from the old combat stream so the loot stream at least starts
	# somewhere sane rather than crashing the loader.
	assert_int(int(migrated.get("loot_rng_state", -1))).is_equal(11)
	assert_int(int(migrated.get("progress", {}).get("monsters_killed", -1))).is_equal(0)
	assert_bool(SaveData.bag_from_player(migrated).is_empty()).is_true()
	assert_bool(SaveData.equipped_from_player(migrated).is_empty()).is_true()
	# G2's step (v1 -> v2) runs right after v0 -> v1 in the same migrate() call:
	# a save this old predates skills entirely, so it lands on the documented
	# default (docs/0016).
	assert_str(SaveData.skill_id_from_player(migrated)).is_equal(SaveData.DEFAULT_SKILL_ID)
	# G3's step (v2 -> v3) runs right after: this save predates levels entirely
	# too, so it lands on level 1 / 0 XP (docs/0017) but keeps its kill count.
	assert_int(SaveData.level_from_player(migrated)).is_equal(SaveData.DEFAULT_LEVEL)
	assert_int(SaveData.xp_from_player(migrated)).is_equal(SaveData.DEFAULT_XP)
	# Fields the legacy save did have survive untouched.
	assert_int(int(migrated.get("master_seed", 0))).is_equal(5)
	assert_int(int(migrated.get("player", {}).get("health", 0))).is_equal(80)


## G2's own migration step: a v1 save (skills didn't exist) has no
## `player.skill_id` at all, unlike the v0 scaffold above which is missing
## everything. Exercised separately so this step is tested in isolation, the
## way a real "one version behind" save will actually show up in the wild.
func test_migrate_v1_defaults_missing_skill_id() -> void:
	var v1_save: Dictionary = {
		"schema_version": 1,
		"saved_at_unix": 1650000000,
		"master_seed": 9,
		"combat_rng_state": "3",
		"loot_rng_state": "4",
		"player": {"health": 100, "position": {"x": 0.0, "y": 0.0, "z": 0.0}, "bag": [], "equipped": {}},
		"progress": {"monsters_killed": 2},
	}
	var migrated: Dictionary = SaveData.migrate(v1_save)
	assert_bool(migrated.is_empty()).is_false()
	assert_int(int(migrated.get("schema_version", -1))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	assert_str(SaveData.skill_id_from_player(migrated)).is_equal(SaveData.DEFAULT_SKILL_ID)
	assert_int(SaveData.level_from_player(migrated)).is_equal(SaveData.DEFAULT_LEVEL)
	assert_int(SaveData.xp_from_player(migrated)).is_equal(SaveData.DEFAULT_XP)


## G3's own migration step: a v2 save (levels didn't exist) has no
## `player.level`/`player.xp` at all — exercised in isolation the same way the
## v1 case above tests G2's step, since this is how a real "one version
## behind" save will actually show up once G3 ships.
func test_migrate_v2_defaults_missing_level_and_xp() -> void:
	var v2_save: Dictionary = {
		"schema_version": 2,
		"saved_at_unix": 1690000000,
		"master_seed": 11,
		"combat_rng_state": "5",
		"loot_rng_state": "6",
		"player": {
			"health": 100, "position": {"x": 0.0, "y": 0.0, "z": 0.0},
			"bag": [], "equipped": {}, "skill_id": "fireball",
		},
		"progress": {"monsters_killed": 7},
	}
	var migrated: Dictionary = SaveData.migrate(v2_save)
	assert_bool(migrated.is_empty()).is_false()
	assert_int(int(migrated.get("schema_version", -1))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	assert_int(SaveData.level_from_player(migrated)).is_equal(SaveData.DEFAULT_LEVEL)
	assert_int(SaveData.xp_from_player(migrated)).is_equal(SaveData.DEFAULT_XP)
	# Fields the v2 save did have survive untouched.
	assert_str(SaveData.skill_id_from_player(migrated)).is_equal("fireball")
	assert_int(int(migrated.get("progress", {}).get("monsters_killed", -1))).is_equal(7)


func test_migrate_rejects_a_newer_schema_version() -> void:
	var from_the_future: Dictionary = {
		"schema_version": SaveData.CURRENT_SCHEMA_VERSION + 1,
		"master_seed": 1,
	}
	assert_bool(SaveData.migrate(from_the_future).is_empty()).is_true()


func test_migrate_rejects_missing_or_malformed_schema_version() -> void:
	assert_bool(SaveData.migrate({}).is_empty()).is_true()
	assert_bool(SaveData.migrate({"master_seed": 1}).is_empty()).is_true()
	assert_bool(SaveData.migrate({"schema_version": "not-a-number"}).is_empty()).is_true()


func test_migrate_rejects_a_version_with_no_known_migration_path() -> void:
	# schema_version -1 has no migration step defined; the chain must fail closed
	# rather than loop or crash.
	assert_bool(SaveData.migrate({"schema_version": -1}).is_empty()).is_true()


## Regression test: [RandomNumberGenerator.state] is a full 64-bit value, well
## past the 53 bits of exact integer precision a JSON double can hold. If the
## envelope ever stored it as a bare JSON number, `JSON.stringify` /
## `JSON.parse_string` (what SaveStore does on disk) would silently truncate it —
## the save would "work" but resume the RNG stream from the wrong position.
## This drives the same JSON encode/decode round trip in-memory (no FileAccess,
## so still a pure domain test) to prove SaveData's String-encoded state
## survives it exactly.
func test_large_rng_state_survives_a_json_round_trip() -> void:
	var huge_combat_state: int = 7952383842509584290
	var huge_loot_state: int = -6871234509876543210
	var envelope: Dictionary = SaveData.build(
		1, huge_combat_state, huge_loot_state, 100, Vector3.ZERO, [], {}, "quick_strike", 1, 0, 0, 0
	)
	var through_json: Variant = JSON.parse_string(JSON.stringify(envelope))
	assert_bool(through_json is Dictionary).is_true()
	var migrated: Dictionary = SaveData.migrate(through_json as Dictionary)
	assert_bool(migrated.is_empty()).is_false()
	assert_int(int(migrated.get("combat_rng_state", 0))).is_equal(huge_combat_state)
	assert_int(int(migrated.get("loot_rng_state", 0))).is_equal(huge_loot_state)
