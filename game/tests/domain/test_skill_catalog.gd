extends GdUnitTestSuite
## Unit tests for [SkillCatalog] — indexing `shared/skills.json`-shaped data,
## the deterministic 3-skill offer, and the skill -> attack-config translation
## that feeds [PlayerStats]/[CombatProfiles] (docs/0016).

const SKILLS_DATA: Dictionary = {
	"schema_version": 1,
	"skills": [
		{
			"id": "quick_strike", "name": "Quick Strike", "element": "physical", "kind": "melee",
			"range": 1.8, "base_min": 4, "base_max": 7, "actions_per_second": 1.5,
			"crit_chance": 0.05, "crit_multiplier": 1.5,
		},
		{
			"id": "fireball", "name": "Fireball", "element": "fire", "kind": "ranged",
			"range": 9.0, "base_min": 10, "base_max": 16, "actions_per_second": 0.6,
			"crit_chance": 0.05, "crit_multiplier": 1.6,
		},
		{
			"id": "venom_slash", "name": "Venom Slash", "element": "poison", "kind": "melee",
			"range": 1.6, "base_min": 4, "base_max": 6, "actions_per_second": 1.4,
			"crit_chance": 0.05, "crit_multiplier": 1.5,
		},
		{
			"id": "icebolt", "name": "Icebolt", "element": "cold", "kind": "ranged",
			"range": 8.0, "base_min": 4, "base_max": 6, "actions_per_second": 1.2,
			"crit_chance": 0.05, "crit_multiplier": 1.5,
		},
	],
}


func test_skill_looks_up_by_id() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var skill: Dictionary = catalog.skill("fireball")
	assert_str(String(skill.get("name", ""))).is_equal("Fireball")


func test_skill_with_unknown_id_returns_empty() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	assert_bool(catalog.skill("does_not_exist").is_empty()).is_true()


func test_all_skills_returns_every_entry_in_file_order() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var all: Array[Dictionary] = catalog.all_skills()
	assert_int(all.size()).is_equal(4)
	assert_str(String(all[0].get("id", ""))).is_equal("quick_strike")
	assert_str(String(all[3].get("id", ""))).is_equal("icebolt")


func test_offer_returns_the_requested_count_of_distinct_skills() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var offer: Array[Dictionary] = catalog.offer(RngService.new(1), 3)
	assert_int(offer.size()).is_equal(3)
	var ids: Array[String] = []
	for skill: Dictionary in offer:
		ids.append(String(skill.get("id", "")))
	# No duplicates: every id shows up exactly once.
	for id_value: String in ids:
		assert_int(ids.count(id_value)).is_equal(1)


func test_offer_is_deterministic_for_the_same_seed() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var first: Array[Dictionary] = catalog.offer(RngService.new(99), 3)
	var second: Array[Dictionary] = catalog.offer(RngService.new(99), 3)
	assert_int(first.size()).is_equal(second.size())
	for i: int in first.size():
		assert_str(String(first[i].get("id", ""))).is_equal(String(second[i].get("id", "")))


func test_offer_differs_for_a_different_seed() -> void:
	# Not a strict guarantee for every possible seed pair, but true for this
	# small fixed pool with these two seeds — pins the "seed actually matters"
	# behaviour without being a flaky statistical test.
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var a: Array[Dictionary] = catalog.offer(RngService.new(1), 3)
	var b: Array[Dictionary] = catalog.offer(RngService.new(2), 3)
	var a_ids: Array[String] = []
	var b_ids: Array[String] = []
	for skill: Dictionary in a:
		a_ids.append(String(skill.get("id", "")))
	for skill: Dictionary in b:
		b_ids.append(String(skill.get("id", "")))
	assert_bool(a_ids == b_ids).is_false()


func test_offer_never_exceeds_the_catalog_size() -> void:
	var catalog: SkillCatalog = SkillCatalog.new(SKILLS_DATA)
	var offer: Array[Dictionary] = catalog.offer(RngService.new(1), 10)
	assert_int(offer.size()).is_equal(4)


func test_attack_config_maps_melee_skill_to_attack_speed() -> void:
	var config: Dictionary = SkillCatalog.attack_config(SKILLS_DATA.get("skills")[0])
	var damage: Dictionary = config.get("damage", {})
	assert_str(String(damage.get("type", ""))).is_equal("physical")
	assert_int(int(damage.get("base_min", 0))).is_equal(4)
	assert_int(int(damage.get("base_max", 0))).is_equal(7)
	assert_float(float(config.get("attack_range", 0.0))).is_equal_approx(1.8, 0.0001)
	assert_float(float(config.get("attack_speed", 0.0))).is_equal_approx(1.5, 0.0001)
	assert_bool(config.has("cast_speed")).is_false()


func test_attack_config_maps_ranged_skill_to_cast_speed() -> void:
	var config: Dictionary = SkillCatalog.attack_config(SKILLS_DATA.get("skills")[1])
	var damage: Dictionary = config.get("damage", {})
	assert_str(String(damage.get("type", ""))).is_equal("fire")
	assert_int(int(damage.get("base_min", 0))).is_equal(10)
	assert_float(float(config.get("cast_speed", 0.0))).is_equal_approx(0.6, 0.0001)
	assert_bool(config.has("attack_speed")).is_false()


## Domain-only integration (mirrors test_combat_profiles.gd's end-to-end test):
## a poison skill's attack_config feeds CombatProfiles.attack_from_data and
## resolves against a defender's poison resistance, exactly like any other
## element — proving poison is routed through the same mitigation model rather
## than a bolted-on special case.
func test_poison_skill_feeds_combat_profiles_and_respects_poison_resistance() -> void:
	var config: Dictionary = SkillCatalog.attack_config(SKILLS_DATA.get("skills")[2])
	var attack: AttackProfile = CombatProfiles.attack_from_data(config)
	assert_int(attack.damage_type).is_equal(AttackProfile.DamageType.POISON)

	var combat_constants: Dictionary = {
		"armor_constant": 10.0, "max_physical_reduction": 0.9, "max_resistance": 0.75,
	}
	var immune_defender: Dictionary = {"armor": 0, "resistances": {"poison": 50}}
	var defense: DefenseProfile = CombatProfiles.defense_from_data(
		immune_defender, AttackProfile.DamageType.POISON, combat_constants
	)
	assert_float(defense.resistance_pct).is_equal_approx(50.0, 0.0001)

	var result: DamageResult = DamageCalculator.new(RngService.new(3)).calculate_hit(attack, defense)
	# Base 4-6 poison at 50% resistance: at most 3, never below the floor of 1.
	assert_int(result.amount).is_between(1, 3)
