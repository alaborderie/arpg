class_name Player
extends CharacterBody3D
## The player character: navigation-driven movement, plus M2 combat — an ordered
## melee attack against one [Monster], own health, and death.
##
## Godot notes: [CharacterBody3D] is the engine's kinematic body — it moves by
## `move_and_slide()` from a `velocity` we set each physics tick, rather than by
## forces. The child [NavigationAgent3D] asks the NavigationServer for a path across
## the baked navigation mesh and hands us one waypoint at a time via
## `get_next_path_position()`.
##
## This scene is an adapter (ADR 0003): it turns "go there" / "kill that" commands
## into engine movement and swing timing. It holds no game rules; every balance
## number (move speed, health, damage, range) comes from `shared/player.json` and
## `shared/combat.json` via [BalanceData], resolved by the domain classes.
##
## Tuning constraint: the agent's `path_desired_distance`/`target_desired_distance`
## (set in player.tscn) must stay comfortably ABOVE the vertical gap between the
## baked navmesh surface (~0.5 above the ground plane) and this body's origin (on
## the ground plane) — the agent's waypoint-advance check is a 3D distance, and at
## exactly the gap it oscillates in place forever.

## Fallbacks if `shared/player.json` cannot be read; they keep the scene playable
## and are NOT the balance source (that is the JSON, see ADR 0005).
const DEFAULT_MOVE_SPEED: float = 5.0
const DEFAULT_MAX_HEALTH: int = 100
const DEFAULT_ATTACK_RANGE: float = 1.5
const DEFAULT_ATTACK_SPEED: float = 1.0
## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001

var _config: Dictionary = {}
var _combat_constants: Dictionary = {}
var _move_speed: float = DEFAULT_MOVE_SPEED
var _attack_range: float = DEFAULT_ATTACK_RANGE
var _seconds_between_attacks: float = 1.0 / DEFAULT_ATTACK_SPEED
## Seconds until the next swing is allowed; 0 means ready.
var _attack_cooldown: float = 0.0
var _health: Health
var _attack: AttackProfile
## Shared per-scene calculator, injected by main (one RNG stream, ADR 0004).
var _calculator: DamageCalculator
## Monster this player is ordered to kill; null while just moving.
var _attack_target: Monster
var _dead: bool = false

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _body: MeshInstance3D = $Body


func _ready() -> void:
	_config = BalanceData.load_player().get("player", {})
	_combat_constants = BalanceData.load_combat().get("combat", {})
	_move_speed = float(_config.get("move_speed", DEFAULT_MOVE_SPEED))
	_attack_range = float(_config.get("attack_range", DEFAULT_ATTACK_RANGE))
	_seconds_between_attacks = 1.0 / maxf(
		float(_config.get("attack_speed", DEFAULT_ATTACK_SPEED)), 0.01
	)
	_health = Health.new(int(_config.get("max_health", DEFAULT_MAX_HEALTH)))
	_attack = CombatProfiles.attack_from_data(_config)


## Injects the scene-shared [DamageCalculator]. Called by main before any combat;
## without it the player can move but not attack.
func setup_combat(calculator: DamageCalculator) -> void:
	_calculator = calculator


## Orders the player to walk to [param world_point], cancelling any attack order.
## The agent clamps the target to the closest reachable point on the navigation
## mesh, so clicks on obstacles or outside the map resolve to the nearest sensible
## destination.
func move_to(world_point: Vector3) -> void:
	if _dead:
		return
	_attack_target = null
	_agent.target_position = world_point


## Orders the player to attack [param target]: walk into range first if needed,
## then swing on cooldown until it (or this player) dies.
func order_attack(target: Monster) -> void:
	if _dead:
		return
	_attack_target = target


func is_dead() -> bool:
	return _dead


func current_health() -> int:
	return _health.current if _health != null else 0


## This player's defence against one incoming hit, built fresh from data so M3
## equipment only has to change the underlying Dictionaries.
func defense_profile(incoming: AttackProfile.DamageType) -> DefenseProfile:
	return CombatProfiles.defense_from_data(_config, incoming, _combat_constants)


## Applies an already-resolved hit. Feedback here, rules in the domain.
func take_hit(result: DamageResult) -> void:
	if _dead:
		return
	_health.take_damage(result.amount)
	CombatFx.spawn_damage_number(get_parent(), global_position + Vector3.UP * 2.4, result)
	if _health.is_dead():
		_die()
	else:
		CombatFx.flash(_body)


func _physics_process(delta: float) -> void:
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	if _dead:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	_validate_attack_target()
	if _attack_target != null:
		var to_target: Vector3 = _attack_target.global_position - global_position
		to_target.y = 0.0
		if to_target.length() <= _attack_range:
			_face(to_target)
			velocity = Vector3.ZERO
			move_and_slide()
			_try_attack()
			return
		# Out of range: keep closing in on the (moving) target.
		_agent.target_position = _attack_target.global_position

	# Before the (runtime-baked, ADR 0009) navigation mesh is ready, and after
	# arrival, the agent reports the path as finished — we just stand still.
	if _agent.is_navigation_finished():
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var next_waypoint: Vector3 = _agent.get_next_path_position()
	var direction: Vector3 = next_waypoint - global_position
	direction.y = 0.0
	_face(direction)
	velocity = direction.normalized() * _move_speed
	move_and_slide()


## Drops the attack order once the target died or was freed.
func _validate_attack_target() -> void:
	if _attack_target == null:
		return
	if not is_instance_valid(_attack_target) or _attack_target.is_dead():
		_attack_target = null


func _face(direction: Vector3) -> void:
	if direction.length_squared() > FACING_EPSILON:
		# look_at points -Z (Godot's forward) at the target; keep the body upright
		# by looking at a point on our own height.
		look_at(global_position + direction, Vector3.UP)


func _try_attack() -> void:
	if _calculator == null or _attack_cooldown > 0.0:
		return
	_attack_cooldown = _seconds_between_attacks
	var defense: DefenseProfile = _attack_target.defense_profile(_attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(_attack, defense)
	_attack_target.take_hit(result)


## Minimal M2 death: input orders are ignored and the body goes dark. A real
## death animation/respawn flow is future work.
func _die() -> void:
	_dead = true
	_attack_target = null
	velocity = Vector3.ZERO
	var corpse_material: StandardMaterial3D = StandardMaterial3D.new()
	corpse_material.albedo_color = Color(0.25, 0.24, 0.23)
	corpse_material.roughness = 1.0
	_body.material_override = corpse_material
