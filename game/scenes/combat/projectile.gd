class_name Projectile
extends Node3D
## A ranged skill's traveling hit. Two modes, one scene (G6, docs/0019 —
## beats forking into two projectile scenes for a difference that's purely
## "how do I find what I hit"):
##
## - [constant Mode.HOMING] (G2, docs/0016): target-locked — every frame it
##   steps toward wherever [member _target] currently is (so it still connects
##   if the monster moves) and resolves on arrival. Used by the click-to-attack
##   order path ([method Player._fire_projectile]), which already has a locked
##   target.
## - [constant Mode.DIRECTIONAL] (G6): no target. Flies at a constant velocity
##   along a fixed direction, up to a maximum travel distance (the skill's
##   range), damaging the first live monster it passes within [constant
##   HIT_RADIUS] of — a per-physics-tick distance sweep over the "monsters"
##   group, cheap at the ~5-10 monsters this game keeps alive. Used by Q-cast
##   free aim ([method Player.cast_at]), which has an aim point but no target.
##
## Neither mode has a physics body or collision detection, and neither can
## miss its resolved victim — a "real" projectile that can whiff or be dodged
## is future work either way. Both share [method _resolve_hit_on]: the actual
## damage always comes from the injected [DamageCalculator]/[DefenseProfile]
## pipeline, never from movement code (ADR 0003 — movement here is plain
## per-frame Vector3 math, not a game rule).

enum Mode { HOMING, DIRECTIONAL }

## Metres per second the projectile travels, in either mode — the fallback
## when a caller doesn't pass its own `speed` (matches `shared/player.json`'s
## `projectile_speed` baseline). G8 (docs/0021): [Player] now passes its own
## composed `projectile_speed` (`faster_projectiles` support scales it via
## `PlayerStats.compose`'s `projectile_speed_pct`), so this constant is only
## ever the unmodified value in practice.
const SPEED: float = 18.0
## Distance at which the projectile is considered to have "arrived" (homing)
## or to have passed close enough to damage a monster (directional). Same
## constant, same meaning either way: "close enough to land the hit".
const HIT_RADIUS: float = 0.5
## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001

var _mode: Mode = Mode.HOMING
var _target: Monster
## Directional mode only: fixed unit direction and how far along it this
## projectile has traveled/may travel before despawning untouched.
var _direction: Vector3 = Vector3.ZERO
var _traveled: float = 0.0
var _max_distance: float = 0.0
var _attack: AttackProfile
var _calculator: DamageCalculator
## Metres per second this specific projectile travels — defaults to
## [constant SPEED], overridable per-cast (G8, docs/0021: [Player] passes its
## composed `projectile_speed`, which `faster_projectiles` scales).
var _speed: float = SPEED

@onready var _body: MeshInstance3D = $Body


## Target-locked homing setup (G2) — call after add_child, like
## [Monster.setup]/[GroundDrop.setup]. [param speed] is optional (G8) and
## defaults to [constant SPEED] so every pre-G8 call site keeps compiling
## unchanged.
func setup_homing(
	target: Monster, attack: AttackProfile, calculator: DamageCalculator, speed: float = SPEED
) -> void:
	_mode = Mode.HOMING
	_target = target
	_attack = attack
	_calculator = calculator
	_speed = speed
	_tint_for_element(attack.damage_type)


## Free-aim directional setup (G6, docs/0019): [param direction] must already
## be a unit vector (callers normalize their aim direction once); [param
## max_distance] is the casting skill's range. [param speed] is optional (G8),
## same default/rationale as [method setup_homing]. Call after add_child.
func setup_directional(
	direction: Vector3,
	max_distance: float,
	attack: AttackProfile,
	calculator: DamageCalculator,
	speed: float = SPEED
) -> void:
	_mode = Mode.DIRECTIONAL
	_direction = direction
	_max_distance = max_distance
	_attack = attack
	_calculator = calculator
	_speed = speed
	_tint_for_element(attack.damage_type)
	if _direction.length_squared() > FACING_EPSILON:
		look_at(global_position + _direction, Vector3.UP)


func _physics_process(delta: float) -> void:
	if _mode == Mode.DIRECTIONAL:
		_process_directional(delta)
	else:
		_process_homing(delta)


func _process_homing(delta: float) -> void:
	if _target == null or not is_instance_valid(_target) or _target.is_dead():
		queue_free()
		return
	var to_target: Vector3 = _target.global_position - global_position
	to_target.y = 0.0
	if to_target.length() <= HIT_RADIUS:
		_resolve_hit_on(_target)
		return
	var direction: Vector3 = to_target.normalized()
	global_position += direction * _speed * delta
	if direction.length_squared() > FACING_EPSILON:
		look_at(global_position + direction, Vector3.UP)


## Sweeps the "monsters" group for the nearest live one within [constant
## HIT_RADIUS] before advancing (so a monster standing right at the spawn
## point is caught on the very first tick), then steps [constant SPEED] *
## delta further along [member _direction] and despawns once [member
## _max_distance] is reached — free-fire at empty ground always ends this way.
func _process_directional(delta: float) -> void:
	var hit: Monster = _nearest_monster_in_hit_radius()
	if hit != null:
		_resolve_hit_on(hit)
		return
	var step: float = _speed * delta
	if _traveled + step >= _max_distance:
		queue_free()
		return
	global_position += _direction * step
	_traveled += step


## The closest live monster (in the "monsters" group) within [constant
## HIT_RADIUS] of the projectile's current position, or null. Deliberately a
## simple O(live monster count) sweep per tick — cheap at the ~5-10 monsters
## this game keeps alive (ADR 0015) — rather than a physics body/collision
## shape, matching this scene's existing "no physics body" simplicity.
func _nearest_monster_in_hit_radius() -> Monster:
	var nearest: Monster = null
	var nearest_distance: float = HIT_RADIUS
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		var monster: Monster = node as Monster
		if monster == null or monster.is_dead():
			continue
		var to_monster: Vector3 = monster.global_position - global_position
		to_monster.y = 0.0
		var distance: float = to_monster.length()
		if distance <= nearest_distance:
			nearest = monster
			nearest_distance = distance
	return nearest


func _resolve_hit_on(monster: Monster) -> void:
	var defense: DefenseProfile = monster.defense_profile(_attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(_attack, defense)
	monster.take_hit(result)
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
