extends GdUnitTestSuite
## G10 (issue #17, docs/0023): a data-side regression guard for the ranged
## balance pass. Every skill in `shared/skills.json` can be offered as a
## player's very first (and only, until level 10) skill — [SkillCatalog.offer]
## draws from the whole list, there is no separate "starter tier" — so every
## `kind == "ranged"` entry's un-mitigated average dps (`(base_min + base_max)
## / 2 * actions_per_second`) must clear [constant DPS_FLOOR]. This is
## deliberately the same simple metric the balance pass was tuned against
## (docs/0023): it ignores crit and target mitigation on purpose, so it is a
## floor on the skill's own numbers, not a simulation of a specific monster
## matchup.

## Matches docs/0023's stated target (dps ~7-10 for a starter skill against a
## 24 HP fallen_imp, killing it in ~2.5-3.5 s of sustained, connecting fire).
const DPS_FLOOR: float = 7.0


func _ranged_skills() -> Array:
	var skills: Array = BalanceData.load_skills().get("skills", [])
	var ranged: Array = []
	for skill: Dictionary in skills:
		if String(skill.get("kind", "")) == "ranged":
			ranged.append(skill)
	return ranged


func test_every_ranged_skill_clears_the_dps_floor() -> void:
	var ranged: Array = _ranged_skills()
	assert_int(ranged.size()).is_greater_equal(1)
	for skill: Dictionary in ranged:
		var base_min: float = float(skill.get("base_min", 0))
		var base_max: float = float(skill.get("base_max", 0))
		var actions_per_second: float = float(skill.get("actions_per_second", 0.0))
		var base_avg: float = (base_min + base_max) / 2.0
		var dps: float = base_avg * actions_per_second
		assert_float(dps).is_greater_equal(DPS_FLOOR)


## Sanity check on the balance pass's own stated goal (docs/0023): melee's
## average dps across the roster should keep a premium over ranged's, since
## melee takes on-hit risk (see docs/0023's "Ranged balance pass" section)
## that a free-aim ranged cast doesn't. Deliberately an average-over-average
## comparison, not a per-pair one — individual skills can and do overlap.
func test_melee_average_dps_keeps_a_premium_over_ranged() -> void:
	var skills: Array = BalanceData.load_skills().get("skills", [])
	var melee_total: float = 0.0
	var melee_count: int = 0
	var ranged_total: float = 0.0
	var ranged_count: int = 0
	for skill: Dictionary in skills:
		var base_min: float = float(skill.get("base_min", 0))
		var base_max: float = float(skill.get("base_max", 0))
		var actions_per_second: float = float(skill.get("actions_per_second", 0.0))
		var dps: float = (base_min + base_max) / 2.0 * actions_per_second
		if String(skill.get("kind", "")) == "melee":
			melee_total += dps
			melee_count += 1
		else:
			ranged_total += dps
			ranged_count += 1
	assert_int(melee_count).is_greater_equal(1)
	assert_int(ranged_count).is_greater_equal(1)
	var melee_avg: float = melee_total / float(melee_count)
	var ranged_avg: float = ranged_total / float(ranged_count)
	assert_float(melee_avg).is_greater(ranged_avg)
