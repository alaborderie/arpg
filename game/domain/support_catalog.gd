class_name SupportCatalog
extends RefCounted
## Indexes `shared/supports.json` and deterministically offers a pick-1-of-3 on
## most level-ups (G8 — supports are PoE-support-gem-lite passive modifiers
## that apply globally, to whichever skill is equipped).
##
## Domain class (ADR 0003): built from the plain parsed `shared/supports.json`
## Dictionary an adapter (`main.gd`, via [BalanceData]) hands in; no file access,
## no Node. All randomness comes from the injected [RngService] (ADR 0004).
##
## [method offer] draws without replacement in a fixed order — pop a random
## index from the remaining pool, repeat — the same determinism contract
## [SkillCatalog.offer]/[LootRoller]._roll_affixes document: reordering the
## draw changes what a given RNG stream position produces next. Unlike
## [SkillCatalog.offer] (drawn once, ever), this stream is drawn from on every
## eligible level-up, and — the "your call, document it" decision docs/0021
## makes — the draw is over the FULL support pool every time, never excluding
## supports the player already owns: duplicates stack additively
## ([method contribution_for_owned] sums per-owned-entry, so owning the same
## support twice is simply "counted twice"), so re-offering one is a
## legitimate, mechanically meaningful pick rather than a wasted card.

var _supports: Array[Dictionary] = []
var _supports_by_id: Dictionary = {}


## [param supports_data] is the parsed `shared/supports.json` document.
func _init(supports_data: Dictionary) -> void:
	var entries: Array = supports_data.get("supports", [])
	for entry: Variant in entries:
		if entry is Dictionary:
			var support: Dictionary = entry as Dictionary
			_supports.append(support)
			_supports_by_id[String(support.get("id", ""))] = support


## The `shared/supports.json` entry for [param support_id], or an empty
## Dictionary if no such support exists.
func support(support_id: String) -> Dictionary:
	return _supports_by_id.get(support_id, {}) as Dictionary


## Every support in file order. Exposed for tests/tools; gameplay only ever
## reaches for [method support] or [method offer].
func all_supports() -> Array[Dictionary]:
	return _supports


## Draws [param count] distinct random supports from the full catalog via
## [param rng] — see the class doc for why owned supports are never excluded.
## Returns fewer than [param count] only if the catalog itself has fewer
## supports than that (not expected in practice — see shared/supports.json).
func offer(rng: RngService, count: int = 3) -> Array[Dictionary]:
	var pool: Array[Dictionary] = _supports.duplicate()
	var picked: Array[Dictionary] = []
	var draws: int = mini(count, pool.size())
	for _i: int in draws:
		var index: int = rng.randi_range(0, pool.size() - 1)
		picked.append(pool.pop_at(index))
	return picked


## Builds the one contribution Dictionary [method Player._recompose_stats]
## appends to the same `contributions` array equipment/level bonuses already
## feed into [PlayerStats.compose] (docs/0021) — every owned support id (in
## [param owned_ids], duplicates included) is looked up and summed by its
## `stat` key. Always returns every key (zeroed/empty when nothing is owned),
## so callers can append it unconditionally, the same idiom
## [ProgressionCurve.bonus_contribution] already established.
func contribution_for_owned(owned_ids: Array[String]) -> Dictionary:
	var damage_pct: float = 0.0
	var attack_cast_speed_pct: float = 0.0
	var crit_chance_pct: float = 0.0
	var crit_multiplier_pct: float = 0.0
	var range_pct: float = 0.0
	var projectile_speed_pct: float = 0.0
	var life_on_kill: int = 0
	var added_projectiles: int = 0
	var added_flat_damage: Dictionary = {}

	for owned_id: String in owned_ids:
		var entry: Dictionary = _supports_by_id.get(owned_id, {})
		if entry.is_empty():
			continue
		var stat: String = String(entry.get("stat", ""))
		var value: float = float(entry.get("value", 0))
		match stat:
			"damage_pct":
				damage_pct += value
			"attack_cast_speed_pct":
				attack_cast_speed_pct += value
			"crit_chance_pct":
				crit_chance_pct += value
			"crit_multiplier_pct":
				crit_multiplier_pct += value
			"range_pct":
				range_pct += value
			"projectile_speed_pct":
				projectile_speed_pct += value
			"life_on_kill":
				life_on_kill += int(value)
			"added_projectiles":
				added_projectiles += int(value)
			"added_flat_damage":
				var element: String = String(entry.get("element", "physical"))
				added_flat_damage[element] = int(added_flat_damage.get(element, 0)) + int(value)

	return {
		"damage_pct": damage_pct,
		"attack_speed_pct": attack_cast_speed_pct,
		"cast_speed_pct": attack_cast_speed_pct,
		"crit_chance_pct": crit_chance_pct,
		"crit_multiplier_pct": crit_multiplier_pct,
		"range_pct": range_pct,
		"projectile_speed_pct": projectile_speed_pct,
		"life_on_kill": life_on_kill,
		"added_projectiles": added_projectiles,
		"added_flat_damage": added_flat_damage,
	}
