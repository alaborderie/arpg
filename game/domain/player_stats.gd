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
##  * `armor`       — additive.
##  * `attack_speed`— percentage increases sum, then scale the base once.
##  * `crit_chance` — percentage-point increases add, clamped to [0, 1].
##  * `resistances` — additive per element (the mitigation cap in
##                    `shared/combat.json` bounds the effect, ADR 0005).


static func compose(base_player: Dictionary, contributions: Array[Dictionary]) -> Dictionary:
	var composed: Dictionary = base_player.duplicate(true)
	var attack_speed_pct: float = 0.0
	for contribution: Dictionary in contributions:
		if contribution.has("damage"):
			composed["damage"] = (contribution.get("damage", {}) as Dictionary).duplicate()
		composed["armor"] = int(composed.get("armor", 0)) + int(contribution.get("armor", 0))
		attack_speed_pct += float(contribution.get("attack_speed_pct", 0.0))
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
	composed["crit_chance"] = clampf(float(composed.get("crit_chance", 0.0)), 0.0, 1.0)
	return composed
