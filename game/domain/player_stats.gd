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
##  * `attack_range` — G8 (docs/0021) adds `range_pct`, the same "sum then
##                    scale once" rule, so a support can extend melee reach
##                    and ranged skill range through one shared knob (both
##                    already read the same `attack_range` field).
##  * `projectile_speed` — G8 adds this stat (mirrors `attack_speed`/
##                    `cast_speed`'s rule exactly) so `faster_projectiles`
##                    can scale [Projectile]'s travel speed without a
##                    GDScript constant edit.
##  * `crit_multiplier` — G8 adds `crit_multiplier_pct`, the same "sum then
##                    scale once" rule, applied to whatever `crit_multiplier`
##                    the skill/base already carries.
##  * `damage`      — G8 adds `damage_pct`: after the implicit-damage-replace
##                    rule above runs, `base_min`/`base_max` are scaled by
##                    `(1 + damage_pct / 100)` and, if any contribution's
##                    `added_flat_damage` Dictionary has an entry matching the
##                    composed damage's own `type`, that flat amount is added
##                    first (matching [ItemStats]'s "(implicit + added) *
##                    scale" order). A support's `added_flat_damage` for an
##                    element other than the equipped skill's own is inert —
##                    the pipeline only ever tracks one damage type per hit
##                    (docs/0021).
##  * `life_on_kill`/`added_projectiles` — new, flat (not percentage) fields:
##                    every contribution's value simply sums. Not consumed by
##                    [CombatProfiles] at all — [Player] reads them directly
##                    off the composed Dictionary (a kill-triggered heal, and
##                    how many projectiles a ranged cast fans out).
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
	var range_pct: float = 0.0
	var projectile_speed_pct: float = 0.0
	var crit_multiplier_pct: float = 0.0
	var damage_pct: float = 0.0
	var life_on_kill: int = 0
	var added_projectiles: int = 0
	var added_flat_damage: Dictionary = {}
	for contribution: Dictionary in contributions:
		if contribution.has("damage"):
			composed["damage"] = (contribution.get("damage", {}) as Dictionary).duplicate()
		composed["armor"] = int(composed.get("armor", 0)) + int(contribution.get("armor", 0))
		attack_speed_pct += float(contribution.get("attack_speed_pct", 0.0))
		cast_speed_pct += float(contribution.get("cast_speed_pct", 0.0))
		max_health_pct += float(contribution.get("max_health_pct", 0.0))
		range_pct += float(contribution.get("range_pct", 0.0))
		projectile_speed_pct += float(contribution.get("projectile_speed_pct", 0.0))
		crit_multiplier_pct += float(contribution.get("crit_multiplier_pct", 0.0))
		damage_pct += float(contribution.get("damage_pct", 0.0))
		life_on_kill += int(contribution.get("life_on_kill", 0))
		added_projectiles += int(contribution.get("added_projectiles", 0))
		composed["crit_chance"] = float(composed.get("crit_chance", 0.0)) \
			+ float(contribution.get("crit_chance_pct", 0.0)) / 100.0
		if contribution.has("resistances"):
			var merged: Dictionary = (composed.get("resistances", {}) as Dictionary).duplicate()
			var incoming: Dictionary = contribution.get("resistances", {})
			for element: Variant in incoming:
				var key: String = String(element)
				merged[key] = int(merged.get(key, 0)) + int(incoming.get(key, 0))
			composed["resistances"] = merged
		if contribution.has("added_flat_damage"):
			var incoming_flat: Dictionary = contribution.get("added_flat_damage", {})
			for element: Variant in incoming_flat:
				var key: String = String(element)
				added_flat_damage[key] = int(added_flat_damage.get(key, 0)) + int(incoming_flat[key])
	composed["attack_speed"] = float(composed.get("attack_speed", 1.0)) \
		* (1.0 + attack_speed_pct / 100.0)
	composed["cast_speed"] = float(composed.get("cast_speed", 1.0)) \
		* (1.0 + cast_speed_pct / 100.0)
	composed["crit_chance"] = clampf(float(composed.get("crit_chance", 0.0)), 0.0, 1.0)
	composed["max_health"] = roundi(
		float(composed.get("max_health", 0)) * (1.0 + max_health_pct / 100.0)
	)
	composed["attack_range"] = float(composed.get("attack_range", 0.0)) * (1.0 + range_pct / 100.0)
	composed["projectile_speed"] = float(composed.get("projectile_speed", 0.0)) \
		* (1.0 + projectile_speed_pct / 100.0)
	composed["crit_multiplier"] = float(composed.get("crit_multiplier", 1.0)) \
		* (1.0 + crit_multiplier_pct / 100.0)
	composed["life_on_kill"] = life_on_kill
	composed["added_projectiles"] = added_projectiles
	if composed.has("damage"):
		var damage: Dictionary = (composed["damage"] as Dictionary).duplicate()
		var element_key: String = String(damage.get("type", "physical"))
		var flat_add: int = int(added_flat_damage.get(element_key, 0))
		var scale: float = 1.0 + damage_pct / 100.0
		damage["base_min"] = roundi((float(damage.get("base_min", 0)) + flat_add) * scale)
		damage["base_max"] = roundi((float(damage.get("base_max", 0)) + flat_add) * scale)
		composed["damage"] = damage
	return composed
