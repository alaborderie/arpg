class_name SkillCatalog
extends RefCounted
## Indexes `shared/skills.json` and deterministically offers a random choice of
## distinct skills (G2 — the player picks 1 of 3 at the start of a new game).
##
## Domain class (ADR 0003): built from the plain parsed `shared/skills.json`
## Dictionary an adapter (`main.gd`, via [BalanceData]) hands in; no file access,
## no Node. All randomness comes from the injected [RngService] (ADR 0004).
##
## [method offer] draws without replacement in a fixed order — pop a random
## index from the remaining pool, repeat — the same determinism contract
## [LootRoller]._roll_affixes documents: reordering the draw changes what a
## given RNG stream position produces next.

var _skills: Array[Dictionary] = []
var _skills_by_id: Dictionary = {}


## [param skills_data] is the parsed `shared/skills.json` document.
func _init(skills_data: Dictionary) -> void:
	var entries: Array = skills_data.get("skills", [])
	for entry: Variant in entries:
		if entry is Dictionary:
			var skill: Dictionary = entry as Dictionary
			_skills.append(skill)
			_skills_by_id[String(skill.get("id", ""))] = skill


## The `shared/skills.json` entry for [param skill_id], or an empty Dictionary
## if no such skill exists.
func skill(skill_id: String) -> Dictionary:
	return _skills_by_id.get(skill_id, {}) as Dictionary


## Every skill in file order. Exposed for tests/tools; gameplay only ever
## reaches for [method skill] or [method offer].
func all_skills() -> Array[Dictionary]:
	return _skills


## Draws [param count] distinct random skills from the full catalog via
## [param rng]. Returns fewer than [param count] only if the catalog itself has
## fewer skills than that (not expected in practice — see shared/skills.json).
func offer(rng: RngService, count: int = 3) -> Array[Dictionary]:
	var pool: Array[Dictionary] = _skills.duplicate()
	var picked: Array[Dictionary] = []
	var draws: int = mini(count, pool.size())
	for _i: int in draws:
		var index: int = rng.randi_range(0, pool.size() - 1)
		picked.append(pool.pop_at(index))
	return picked


## Builds the partial "player config" Dictionary [param skill] contributes:
## `damage` (type/base_min/base_max), `attack_range`, `crit_chance`,
## `crit_multiplier`, and whichever speed stat the skill's `kind` maps to —
## `attack_speed` for melee, `cast_speed` for ranged (docs/0016; G3 scales both
## per level through the same [PlayerStats.compose] contribution keys).
##
## Pure data shaping (ADR 0003): the caller ([Player._recompose_stats])
## `merge()`s this over the player's base config, *before* folding in equipment
## contributions, so `CombatProfiles.attack_from_data` sees the exact same
## Dictionary shape it always has — a skill just replaces the same fields a
## weapon already knew how to override.
static func attack_config(skill: Dictionary) -> Dictionary:
	var config: Dictionary = {
		"damage": {
			"type": String(skill.get("element", "physical")),
			"base_min": int(skill.get("base_min", 0)),
			"base_max": int(skill.get("base_max", 0)),
		},
		"attack_range": float(skill.get("range", 0.0)),
		"crit_chance": float(skill.get("crit_chance", 0.0)),
		"crit_multiplier": float(skill.get("crit_multiplier", 1.5)),
	}
	var rate: float = float(skill.get("actions_per_second", 1.0))
	if String(skill.get("kind", "melee")) == "ranged":
		config["cast_speed"] = rate
	else:
		config["attack_speed"] = rate
	return config
