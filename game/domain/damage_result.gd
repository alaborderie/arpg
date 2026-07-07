class_name DamageResult
extends RefCounted
## Immutable outcome of a single [DamageCalculator] hit.

## Final damage dealt after all scaling and mitigation (always >= 1).
var amount: int
## Whether this hit rolled a critical strike.
var is_critical: bool
## Fraction of damage removed by armour/resistance, in [0.0, 1.0]. Useful for UI
## and tuning; e.g. 0.75 means three quarters of the post-crit damage was absorbed.
var mitigation_applied: float


func _init(p_amount: int, p_is_critical: bool, p_mitigation_applied: float) -> void:
	amount = p_amount
	is_critical = p_is_critical
	mitigation_applied = p_mitigation_applied
