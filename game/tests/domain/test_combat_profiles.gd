extends GdUnitTestSuite
## Unit tests for [CombatProfiles] — building profiles from plain Dictionaries with
## the shapes of `shared/player.json` / `shared/monsters.json` / `shared/combat.json`.
##
## The fixtures below mirror those file shapes on purpose: adapters hand the parsed
## JSON straight in, so the shapes agreeing is the contract under test.

const FALLEN_IMP: Dictionary = {
	"id": "fallen_imp",
	"max_health": 24,
	"armor": 4,
	"resistances": {"fire": 40, "cold": -20, "lightning": 0},
	"damage": {"type": "physical", "base_min": 2, "base_max": 4},
	"crit_chance": 0.05,
	"crit_multiplier": 1.5,
}

const COMBAT_CONSTANTS: Dictionary = {
	"armor_constant": 12.0,
	"max_physical_reduction": 0.85,
	"max_resistance": 0.7,
}


func test_attack_from_data_maps_all_fields() -> void:
	var attack: AttackProfile = CombatProfiles.attack_from_data(FALLEN_IMP)
	assert_int(attack.base_min).is_equal(2)
	assert_int(attack.base_max).is_equal(4)
	assert_int(attack.damage_type).is_equal(AttackProfile.DamageType.PHYSICAL)
	assert_float(attack.crit_chance).is_equal_approx(0.05, 0.0001)
	assert_float(attack.crit_multiplier).is_equal_approx(1.5, 0.0001)


func test_attack_from_empty_data_keeps_profile_defaults() -> void:
	var attack: AttackProfile = CombatProfiles.attack_from_data({})
	var defaults: AttackProfile = AttackProfile.new()
	assert_int(attack.base_min).is_equal(defaults.base_min)
	assert_int(attack.base_max).is_equal(defaults.base_max)
	assert_int(attack.damage_type).is_equal(AttackProfile.DamageType.PHYSICAL)


func test_damage_type_from_name_maps_every_type() -> void:
	assert_int(CombatProfiles.damage_type_from_name("physical")) \
		.is_equal(AttackProfile.DamageType.PHYSICAL)
	assert_int(CombatProfiles.damage_type_from_name("fire")) \
		.is_equal(AttackProfile.DamageType.FIRE)
	assert_int(CombatProfiles.damage_type_from_name("cold")) \
		.is_equal(AttackProfile.DamageType.COLD)
	assert_int(CombatProfiles.damage_type_from_name("lightning")) \
		.is_equal(AttackProfile.DamageType.LIGHTNING)
	# G2 (docs/0016): poison feeds monsters.json's new `poison` resistance key,
	# the same way fire/cold/lightning each feed their own.
	assert_int(CombatProfiles.damage_type_from_name("poison")) \
		.is_equal(AttackProfile.DamageType.POISON)


func test_damage_type_from_unknown_name_falls_back_to_physical() -> void:
	assert_int(CombatProfiles.damage_type_from_name("chaos")) \
		.is_equal(AttackProfile.DamageType.PHYSICAL)


func test_defense_reads_armor_and_combat_constants() -> void:
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		FALLEN_IMP, AttackProfile.DamageType.PHYSICAL, COMBAT_CONSTANTS
	)
	assert_int(defense.armor).is_equal(4)
	assert_float(defense.armor_constant).is_equal_approx(12.0, 0.0001)
	assert_float(defense.max_physical_reduction).is_equal_approx(0.85, 0.0001)
	assert_float(defense.max_resistance).is_equal_approx(0.7, 0.0001)


func test_defense_picks_resistance_matching_incoming_type() -> void:
	var fire: DefenseProfile = CombatProfiles.defense_from_data(
		FALLEN_IMP, AttackProfile.DamageType.FIRE, COMBAT_CONSTANTS
	)
	assert_float(fire.resistance_pct).is_equal_approx(40.0, 0.0001)
	var cold: DefenseProfile = CombatProfiles.defense_from_data(
		FALLEN_IMP, AttackProfile.DamageType.COLD, COMBAT_CONSTANTS
	)
	assert_float(cold.resistance_pct).is_equal_approx(-20.0, 0.0001)


func test_defense_against_physical_ignores_resistances() -> void:
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		FALLEN_IMP, AttackProfile.DamageType.PHYSICAL, COMBAT_CONSTANTS
	)
	assert_float(defense.resistance_pct).is_equal_approx(0.0, 0.0001)


func test_defense_picks_poison_resistance_when_present() -> void:
	var poison_resistant: Dictionary = {"armor": 0, "resistances": {"poison": 50}}
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		poison_resistant, AttackProfile.DamageType.POISON, COMBAT_CONSTANTS
	)
	assert_float(defense.resistance_pct).is_equal_approx(50.0, 0.0001)


func test_defense_without_resistances_defaults_to_zero() -> void:
	# The player entry has armor but no resistances block (see player.schema.json).
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		{"armor": 10}, AttackProfile.DamageType.FIRE, COMBAT_CONSTANTS
	)
	assert_float(defense.resistance_pct).is_equal_approx(0.0, 0.0001)


func test_profiles_feed_the_damage_calculator_end_to_end() -> void:
	# Domain-only integration: data dictionaries -> profiles -> deterministic hit.
	var attack: AttackProfile = CombatProfiles.attack_from_data(FALLEN_IMP)
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		{"armor": 0}, attack.damage_type, COMBAT_CONSTANTS
	)
	var result: DamageResult = DamageCalculator.new(RngService.new(1)) \
		.calculate_hit(attack, defense)
	assert_int(result.amount).is_between(2, 6)
