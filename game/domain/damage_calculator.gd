class_name DamageCalculator
extends RefCounted
## Pure, deterministic damage calculation for the ARPG combat model.
##
## Pipeline (Path-of-Exile flavoured):
##   base roll -> + added flat -> x (1 + increased%) -> x more -> critical strike
##   -> defensive mitigation -> floor, minimum 1.
##
## Design rules enforced here:
##  * Purity: extends [RefCounted], not [Node]. No scene tree, input, or rendering.
##    This is what lets the whole combat model run under `godot --headless` in tests
##    and, later, inside a server-side simulation.
##  * Determinism: the only randomness comes from the injected [RngService]. There
##    are no `randi()`/`randf()` calls here. Same seed + same profiles => same result.
##  * Data-driven: no balance numbers are hard-coded; they all arrive on the
##    [AttackProfile]/[DefenseProfile], which are populated from `shared/*.json`.

var _rng: RngService


func _init(rng: RngService) -> void:
	_rng = rng


## Resolves one hit of [param attack] against [param defense].
func calculate_hit(attack: AttackProfile, defense: DefenseProfile) -> DamageResult:
	var base_roll: int = _rng.randi_range(attack.base_min, attack.base_max)

	var added: float = float(base_roll) + attack.added_flat
	var increased: float = added * (1.0 + attack.increased_pct / 100.0)
	var after_more: float = increased * attack.more_multiplier

	# Draw the crit roll unconditionally so the RNG stream advances the same way
	# regardless of crit_chance — this keeps sequences reproducible.
	var is_crit: bool = _rng.randf() < clampf(attack.crit_chance, 0.0, 1.0)
	var after_crit: float = after_more * (attack.crit_multiplier if is_crit else 1.0)

	var mitigation: float = _mitigation(attack.damage_type, after_crit, defense)
	var mitigated: float = after_crit * (1.0 - mitigation)

	# The epsilon guards against float noise: 100 * (1.0 - 0.90) is 9.999...98 in
	# IEEE754 and must floor to 10, not 9.
	var amount: int = maxi(1, int(floor(mitigated + 0.00001)))
	return DamageResult.new(amount, is_crit, mitigation)


## Returns the fraction of damage removed by the defender, in [0.0, 1.0].
## `damage_type` is an [enum AttackProfile.DamageType] value (annotated as int, since
## GDScript enums are ints, to keep this parseable independent of class load order).
func _mitigation(
	damage_type: int,
	incoming: float,
	defense: DefenseProfile
) -> float:
	if damage_type == AttackProfile.DamageType.PHYSICAL:
		var armor: float = float(defense.armor)
		if armor <= 0.0:
			return 0.0
		# Diminishing returns that scale with hit size: the same armour absorbs a
		# larger fraction of small hits than of big ones.
		var reduction: float = armor / (armor + defense.armor_constant * maxf(incoming, 1.0))
		return clampf(reduction, 0.0, defense.max_physical_reduction)

	# Elemental damage: flat resistance percentage with a hard cap.
	return clampf(defense.resistance_pct / 100.0, 0.0, defense.max_resistance)
