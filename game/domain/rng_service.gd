class_name RngService
extends RefCounted
## The single source of randomness for the domain layer.
##
## Determinism rule: domain code must never call the global `randi()`/`randf()`.
## It draws every random number from an injected [RngService] instead, so that
## `same seed + same inputs => same outcome`. That is what makes combat, loot and
## map generation reproducible, headlessly testable, and (later) verifiable on a
## server. See docs/0004-deterministic-injectable-rng.md.
##
## [member get_state]/[member set_state] let a run's RNG position be captured in a
## save file so a session resumes with an identical random stream.

var _rng: RandomNumberGenerator


func _init(seed_value: int = 0) -> void:
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed_value


## Inclusive integer in [from, to].
func randi_range(from: int, to: int) -> int:
	return _rng.randi_range(from, to)


## Float in [0.0, 1.0).
func randf() -> float:
	return _rng.randf()


## Float in [from, to].
func randf_range(from: float, to: float) -> float:
	return _rng.randf_range(from, to)


## Opaque position in the random stream, for persistence.
func get_state() -> int:
	return _rng.state


## Restores a position captured with [method get_state].
func set_state(state: int) -> void:
	_rng.state = state
