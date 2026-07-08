class_name Projectile
extends Node3D
## A ranged skill's traveling hit (G2, docs/0016).
##
## Deliberately the simplest thing that reads as "a projectile": target-locked
## homing, no physics body, no collision detection, no ability to miss. Every
## frame it steps toward whatever position [member _target] currently occupies
## (so it still connects if the monster moves) and, once close enough, resolves
## the hit through the same [DamageCalculator]/[DefenseProfile] pipeline melee
## skills use and frees itself. A "real" projectile that can miss, be dodged, or
## travel in a straight line past its original target is future work — this is
## the boring version that proves the ranged-skill flow end to end.
##
## Adapter (ADR 0003): movement here is plain per-frame Vector3 math, not a game
## rule; the rule (how much damage lands) still only ever comes from the
## injected [DamageCalculator].

## Metres per second the projectile closes on its target.
const SPEED: float = 18.0
## Distance at which the projectile is considered to have "arrived" and
## resolves its hit.
const HIT_RADIUS: float = 0.5
## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001

var _target: Monster
var _attack: AttackProfile
var _calculator: DamageCalculator

@onready var _body: MeshInstance3D = $Body


## Hands over what to chase and how to resolve the hit on arrival. Call after
## add_child, like [Monster.setup]/[GroundDrop.setup].
func setup(target: Monster, attack: AttackProfile, calculator: DamageCalculator) -> void:
	_target = target
	_attack = attack
	_calculator = calculator
	_tint_for_element(attack.damage_type)


func _physics_process(delta: float) -> void:
	if _target == null or not is_instance_valid(_target) or _target.is_dead():
		queue_free()
		return
	var to_target: Vector3 = _target.global_position - global_position
	to_target.y = 0.0
	if to_target.length() <= HIT_RADIUS:
		_resolve_hit()
		return
	var direction: Vector3 = to_target.normalized()
	global_position += direction * SPEED * delta
	if direction.length_squared() > FACING_EPSILON:
		look_at(global_position + direction, Vector3.UP)


func _resolve_hit() -> void:
	var defense: DefenseProfile = _target.defense_profile(_attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(_attack, defense)
	_target.take_hit(result)
	queue_free()


## Cosmetic only: tints the bolt by damage element so a fireball doesn't look
## like an icebolt. Falls back to a neutral grey for physical/unknown types.
func _tint_for_element(damage_type: AttackProfile.DamageType) -> void:
	var colors: Dictionary = {
		AttackProfile.DamageType.FIRE: Color(0.95, 0.35, 0.15),
		AttackProfile.DamageType.COLD: Color(0.55, 0.85, 0.95),
		AttackProfile.DamageType.LIGHTNING: Color(0.95, 0.9, 0.3),
		AttackProfile.DamageType.POISON: Color(0.45, 0.85, 0.3),
	}
	var color: Color = colors.get(damage_type, Color(0.8, 0.8, 0.8))
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_body.material_override = material
