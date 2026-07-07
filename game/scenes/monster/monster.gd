class_name Monster
extends CharacterBody3D
## One monster on the map: `melee_chaser` AI (chase the player, swing when in
## range), health, death, hit feedback.
##
## Adapter (ADR 0003): every number here — health, damage, speeds, range — arrives
## in [method setup] as the plain `monsters.json` entry Dictionary; the domain
## classes ([Health], [CombatProfiles], [DamageCalculator]) own the rules. The
## scene only moves the body and shows the outcome.
##
## The [NavigationAgent3D] desired distances stay at 1.0: the baked navmesh floats
## ~0.5 above the ground plane and the agent's waypoint-advance check is a 3D
## distance, so anything close to 0.5 stalls agents in place (see player.gd).

## Emitted once, right before the corpse is freed. main.gd listens and rolls loot
## (M3): position and `monster_id()` are still valid during the emission.
signal died(monster: Monster)

## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001

var _data: Dictionary = {}
var _combat_constants: Dictionary = {}
var _calculator: DamageCalculator
var _target: Player
var _health: Health
var _attack: AttackProfile
var _move_speed: float = 0.0
var _attack_range: float = 1.0
var _seconds_between_attacks: float = 1.0
## Seconds until the next swing is allowed; 0 means ready.
var _attack_cooldown: float = 0.0

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _body: MeshInstance3D = $Body


## Injects everything this monster needs: its `monsters.json` entry, the `combat`
## constants object, the scene-shared calculator (one RNG stream, ADR 0004) and
## the player to hunt. Until this is called the monster stands inert.
func setup(
	data: Dictionary,
	combat_constants: Dictionary,
	calculator: DamageCalculator,
	target: Player
) -> void:
	_data = data
	_combat_constants = combat_constants
	_calculator = calculator
	_target = target
	_health = Health.new(int(data.get("max_health", 1)))
	_attack = CombatProfiles.attack_from_data(data)
	_move_speed = float(data.get("move_speed", 0.0))
	_attack_range = float(data.get("attack_range", 1.0))
	_seconds_between_attacks = 1.0 / maxf(float(data.get("attack_speed", 1.0)), 0.01)


func is_dead() -> bool:
	return _health != null and _health.is_dead()


## This monster's `monsters.json` id — the key loot tables reference.
func monster_id() -> String:
	return String(_data.get("id", ""))


func current_health() -> int:
	return _health.current if _health != null else 0


## This monster's defence against one incoming hit, built fresh from data so a
## later gear/buff system only has to change the underlying Dictionaries.
func defense_profile(incoming: AttackProfile.DamageType) -> DefenseProfile:
	return CombatProfiles.defense_from_data(_data, incoming, _combat_constants)


## Applies an already-resolved hit. Feedback here, rules in the domain.
func take_hit(result: DamageResult) -> void:
	if _health == null or _health.is_dead():
		return
	_health.take_damage(result.amount)
	CombatFx.spawn_damage_number(get_parent(), global_position + Vector3.UP * 2.2, result)
	if _health.is_dead():
		died.emit(self)
		queue_free()
	else:
		CombatFx.flash(_body)


func _physics_process(delta: float) -> void:
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	if _target == null or is_dead() or _target.is_dead():
		_stand_still()
		return

	var to_target: Vector3 = _target.global_position - global_position
	to_target.y = 0.0
	if to_target.length() <= _attack_range:
		_face(to_target)
		_stand_still()
		_try_attack()
		return

	_agent.target_position = _target.global_position
	if _agent.is_navigation_finished():
		# Path not ready yet (navmesh still baking) or target unreachable.
		_stand_still()
		return
	var next_waypoint: Vector3 = _agent.get_next_path_position()
	var direction: Vector3 = next_waypoint - global_position
	direction.y = 0.0
	_face(direction)
	velocity = direction.normalized() * _move_speed
	move_and_slide()


func _stand_still() -> void:
	velocity = Vector3.ZERO
	move_and_slide()


func _face(direction: Vector3) -> void:
	if direction.length_squared() > FACING_EPSILON:
		look_at(global_position + direction, Vector3.UP)


func _try_attack() -> void:
	if _attack_cooldown > 0.0:
		return
	_attack_cooldown = _seconds_between_attacks
	var defense: DefenseProfile = _target.defense_profile(_attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(_attack, defense)
	_target.take_hit(result)
