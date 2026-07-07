class_name CombatProfiles
extends RefCounted
## Assembles [AttackProfile]/[DefenseProfile] from plain Dictionaries shaped like
## the entries in `shared/player.json`, `shared/monsters.json` and
## `shared/combat.json`.
##
## Domain class (ADR 0003): it never touches the filesystem — adapters load the
## JSON (via `BalanceData`) and hand the parsed Dictionaries in. Missing keys fall
## back to the profile defaults so a malformed file degrades instead of crashing.

const _DAMAGE_TYPE_BY_NAME: Dictionary = {
	"physical": AttackProfile.DamageType.PHYSICAL,
	"fire": AttackProfile.DamageType.FIRE,
	"cold": AttackProfile.DamageType.COLD,
	"lightning": AttackProfile.DamageType.LIGHTNING,
}

const _RESISTANCE_KEY_BY_TYPE: Dictionary = {
	AttackProfile.DamageType.FIRE: "fire",
	AttackProfile.DamageType.COLD: "cold",
	AttackProfile.DamageType.LIGHTNING: "lightning",
}


## Maps a data-file damage-type name ("physical", "fire", ...) to the enum.
## Unknown names fall back to PHYSICAL.
static func damage_type_from_name(type_name: String) -> AttackProfile.DamageType:
	var value: int = int(_DAMAGE_TYPE_BY_NAME.get(type_name, AttackProfile.DamageType.PHYSICAL))
	return value as AttackProfile.DamageType


## Builds the outgoing-hit profile of [param entity] — a Dictionary with the
## combat-stat shape shared by the `player` object and each `monsters[]` entry:
## `damage: {type, base_min, base_max}`, `crit_chance`, `crit_multiplier`.
static func attack_from_data(entity: Dictionary) -> AttackProfile:
	var damage: Dictionary = entity.get("damage", {})
	var attack: AttackProfile = AttackProfile.new()
	attack.base_min = int(damage.get("base_min", attack.base_min))
	attack.base_max = int(damage.get("base_max", attack.base_max))
	attack.damage_type = damage_type_from_name(String(damage.get("type", "physical")))
	attack.crit_chance = float(entity.get("crit_chance", attack.crit_chance))
	attack.crit_multiplier = float(entity.get("crit_multiplier", attack.crit_multiplier))
	return attack


## Builds [param entity]'s defence against one hit of [param incoming_type].
## Reads `armor` and (for elemental hits) the matching `resistances` entry from the
## entity, and the formula constants from [param combat_constants] — the `combat`
## object of `shared/combat.json`.
static func defense_from_data(
	entity: Dictionary,
	incoming_type: AttackProfile.DamageType,
	combat_constants: Dictionary
) -> DefenseProfile:
	var defense: DefenseProfile = DefenseProfile.new()
	defense.armor = int(entity.get("armor", defense.armor))
	if _RESISTANCE_KEY_BY_TYPE.has(incoming_type):
		var resistances: Dictionary = entity.get("resistances", {})
		var key: String = String(_RESISTANCE_KEY_BY_TYPE[incoming_type])
		defense.resistance_pct = float(resistances.get(key, 0.0))
	defense.armor_constant = float(combat_constants.get("armor_constant", defense.armor_constant))
	defense.max_physical_reduction = float(
		combat_constants.get("max_physical_reduction", defense.max_physical_reduction)
	)
	defense.max_resistance = float(combat_constants.get("max_resistance", defense.max_resistance))
	return defense
