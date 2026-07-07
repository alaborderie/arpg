class_name Health
extends RefCounted
## Pure hit-point state for a single combatant.
##
## Domain class (ADR 0003): no Node, no scene tree, no signals wired to rendering —
## adapters apply damage through [method take_damage] and read the outcome. The
## maximum comes from data (`shared/player.json`, `shared/monsters.json`), never
## from a constant in a scene.

var max_health: int
var current: int


func _init(p_max_health: int) -> void:
	max_health = maxi(1, p_max_health)
	current = max_health


## Removes up to [param amount] hit points (never below zero) and returns the
## damage actually applied. Negative amounts are ignored and return 0.
func take_damage(amount: int) -> int:
	var applied: int = clampi(amount, 0, current)
	current -= applied
	return applied


func is_dead() -> bool:
	return current <= 0


func is_alive() -> bool:
	return current > 0
