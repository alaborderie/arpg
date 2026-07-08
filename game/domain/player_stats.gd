class_name PlayerStats
extends RefCounted
## Composes the player's effective stats from base data plus equipped items.
##
## Domain class (ADR 0003): input is the `player` object of `shared/player.json`
## and the [ItemStats] contribution of each equipped item; output is a Dictionary
## of the exact same shape (plus an optional `resistances` block), so it feeds
## [CombatProfiles] unchanged — equipment changes the numbers, never the pipeline.
##
## Composition rules:
##  * `damage`      — an equipped weapon *replaces* the unarmed base damage
##                    (slots are unique, so at most one contribution carries damage).
##                    Since G2 (docs/0016), "unarmed base damage" is whichever
##                    skill the player has active — a weapon's implicit damage
##                    still wins over it, exactly as it won over the player.json
##                    baseline before skills existed.
##  * `armor`       — additive.
##  * `attack_speed`— percentage increases sum, then scale the base once. Read
##                    by melee skills (docs/0016).
##  * `cast_speed`  — the same rule as `attack_speed`, kept as an independent
##                    stat read by ranged skills. No item affix populates
##                    `cast_speed_pct` yet; it exists so G3's per-level bonus
##                    has one obvious contribution key to add alongside
##                    `attack_speed_pct` (both fold through this same function).
##  * `crit_chance` — percentage-point increases add, clamped to [0, 1].
##  * `resistances` — additive per element (the mitigation cap in
##                    `shared/combat.json` bounds the effect, ADR 0005).
##  * `max_health`  — the same "percentages sum, then scale once" rule as
##                    `attack_speed`/`cast_speed`. G3 (docs/0017) is the first
##                    contributor, via `max_health_pct` in
##                    [ProgressionCurve.bonus_contribution]; no item affix
##                    populates it yet. Rounds to the nearest integer HP.
##
## G3 note on compounding (docs/0017): [ProgressionCurve.bonus_contribution]
## bakes `(1 + level_bonus_pct/100)^(level-1) - 1` into the `_pct` value it
## contributes, so this function's single "sum then scale once" pass reproduces
## exact multiplicative per-level compounding *as long as the level bonus is
## the only contribution touching that stat*. If an item affix ever also
## contributes `attack_speed_pct`/`cast_speed_pct`/`max_health_pct`, the two
## sum before the single scale-once multiply (same as two item affixes always
## have) rather than compounding with each other — a deliberate, documented
## deviation from "pure" multiplicative stacking, not a bug.


static func compose(base_player: Dictionary, contributions: Array[Dictionary]) -> Dictionary:
	var composed: Dictionary = base_player.duplicate(true)
	var attack_speed_pct: float = 0.0
	var cast_speed_pct: float = 0.0
	var max_health_pct: float = 0.0
	for contribution: Dictionary in contributions:
		if contribution.has("damage"):
			composed["damage"] = (contribution.get("damage", {}) as Dictionary).duplicate()
		composed["armor"] = int(composed.get("armor", 0)) + int(contribution.get("armor", 0))
		attack_speed_pct += float(contribution.get("attack_speed_pct", 0.0))
		cast_speed_pct += float(contribution.get("cast_speed_pct", 0.0))
		max_health_pct += float(contribution.get("max_health_pct", 0.0))
		composed["crit_chance"] = float(composed.get("crit_chance", 0.0)) \
			+ float(contribution.get("crit_chance_pct", 0.0)) / 100.0
		if contribution.has("resistances"):
			var merged: Dictionary = (composed.get("resistances", {}) as Dictionary).duplicate()
			var incoming: Dictionary = contribution.get("resistances", {})
			for element: Variant in incoming:
				var key: String = String(element)
				merged[key] = int(merged.get(key, 0)) + int(incoming.get(key, 0))
			composed["resistances"] = merged
	composed["attack_speed"] = float(composed.get("attack_speed", 1.0)) \
		* (1.0 + attack_speed_pct / 100.0)
	composed["cast_speed"] = float(composed.get("cast_speed", 1.0)) \
		* (1.0 + cast_speed_pct / 100.0)
	composed["crit_chance"] = clampf(float(composed.get("crit_chance", 0.0)), 0.0, 1.0)
	composed["max_health"] = roundi(
		float(composed.get("max_health", 0)) * (1.0 + max_health_pct / 100.0)
	)
	return composed
