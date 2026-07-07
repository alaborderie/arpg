class_name ItemStats
extends RefCounted
## Computes what one rolled item contributes to its wearer.
##
## Domain class (ADR 0003): input is the rolled-item Dictionary (see [LootRoller])
## plus its `items.json` base entry; output is a plain "contribution" Dictionary
## [PlayerStats] folds into the wearer's stats:
##   { "damage": {type, base_min, base_max}?,   # weapons: implicit + damage affixes
##     "armor": int?,                           # implicit + added_armor affixes
##     "attack_speed_pct": float?,
##     "crit_chance_pct": float?,
##     "resistances": {fire?, cold?, lightning?}? }
## Keys are omitted when the item contributes nothing to them.
##
## Damage affix math, applied to the implicit damage range:
##   (implicit +- added_damage) * (1 + increased_damage_pct / 100), rounded.

const _RESISTANCE_KEY_BY_STAT: Dictionary = {
	"fire_resistance": "fire",
	"cold_resistance": "cold",
	"lightning_resistance": "lightning",
}


static func contribution(item: Dictionary, item_base: Dictionary) -> Dictionary:
	var implicit: Dictionary = item_base.get("implicit", {})
	var added_damage: int = 0
	var increased_damage_pct: float = 0.0
	var armor: int = int(implicit.get("armor", 0))
	var attack_speed_pct: float = 0.0
	var crit_chance_pct: float = 0.0
	var resistances: Dictionary = {}

	var affixes: Array = item.get("affixes", [])
	for entry: Variant in affixes:
		if entry is not Dictionary:
			continue
		var affix: Dictionary = entry as Dictionary
		var stat: String = String(affix.get("stat", ""))
		var value: int = int(affix.get("value", 0))
		match stat:
			"added_damage":
				added_damage += value
			"increased_damage_pct":
				increased_damage_pct += float(value)
			"added_armor":
				armor += value
			"attack_speed_pct":
				attack_speed_pct += float(value)
			"crit_chance_pct":
				crit_chance_pct += float(value)
			"fire_resistance", "cold_resistance", "lightning_resistance":
				var key: String = String(_RESISTANCE_KEY_BY_STAT[stat])
				resistances[key] = int(resistances.get(key, 0)) + value

	var out: Dictionary = {}
	if implicit.has("damage"):
		var implicit_damage: Dictionary = implicit.get("damage", {})
		var scale: float = 1.0 + increased_damage_pct / 100.0
		out["damage"] = {
			"type": String(implicit_damage.get("type", "physical")),
			"base_min": int(round((int(implicit_damage.get("base_min", 0)) + added_damage) * scale)),
			"base_max": int(round((int(implicit_damage.get("base_max", 0)) + added_damage) * scale)),
		}
	if armor != 0:
		out["armor"] = armor
	if attack_speed_pct != 0.0:
		out["attack_speed_pct"] = attack_speed_pct
	if crit_chance_pct != 0.0:
		out["crit_chance_pct"] = crit_chance_pct
	if not resistances.is_empty():
		out["resistances"] = resistances
	return out
