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
##
## G7 (issue #14, docs/0020): a monster spawned as an ELITE ([method setup]'s
## `is_elite`) gets a visual/stat pass — bigger, slower, tougher, worth more XP,
## rarer loot — but keeps the same [NavigationAgent3D] radius and
## [CollisionShape3D] capsule as a normal spawn: a visual-only scale-up, same
## precedent G5 already set for `cinder_wraith`'s taller hood vs. its shared
## capsule (docs/0018). Left unchanged deliberately rather than grown to match
## the bigger silhouette; re-measure if a scaled-up elite is ever seen visibly
## clipping through obstacles or stacking unrealistically with other monsters.

## Emitted once, right before the corpse is freed. main.gd listens and rolls loot
## (M3): position and `monster_id()` are still valid during the emission.
signal died(monster: Monster)
## Emitted whenever current health changes (a hit) — G4, issue #11. The
## floating health bar is updated directly from the same call site; this
## signal exists for the same reason [Player]'s does, any other observer can
## redraw without polling.
signal health_changed

## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001
## Height above the monster's origin the health bar floats at. G5 (issue #12)
## retuned this from 1.6: the two low-poly silhouettes built by
## [method _build_visual] are no longer identical capsules — fallen_imp tops
## out around y=1.2 but cinder_wraith's hood reaches ~y=1.49 — so this clears
## the taller of the two with the same ~0.3 m margin the old capsule had.
## (Collision stays the plain 1.2 m capsule below for both ids - visual swap
## only, per the ticket.)
const HEALTH_BAR_HEIGHT: float = 1.8

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
## G7 (issue #14, docs/0020): true when this spawn rolled (or was forced via
## MonsterSpawner.forced_elite) an ELITE variant — bigger, slower, tougher,
## worth more XP, and biased toward rarer loot. Set once in [method setup];
## an elite never becomes non-elite or vice versa post-spawn.
var _is_elite: bool = false
## The `elite` block of shared/combat.json (multipliers), only ever non-empty
## when [member _is_elite] is true — see [method _elite_multiplier].
var _elite_config: Dictionary = {}
## Floating world-space bar above the monster's head (G4, issue #11). Built in
## _ready, before [method setup] runs, so a red default full bar exists the
## instant the monster is added to the tree.
var _health_bar: HealthBar3D
## G5 (issue #12): the low-poly body's box parts (legs, torso, head, ...),
## built by [method _build_visual] once [method setup] knows `monster_id`.
## Populated by [method _add_box_part]; [method take_hit] flashes all of them
## together (CombatFx.flash_all) so a hit reads across the whole silhouette,
## not just one piece of it.
var _body_parts: Array[MeshInstance3D] = []

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
## Empty container the visual box parts are added under (see monster.tscn's
## doc-comment and [method _build_visual]) — a plain Node3D, not a mesh,
## because the silhouette itself is chosen at runtime by monster id.
@onready var _body: Node3D = $Body


func _ready() -> void:
	# G6 (docs/0019): free-aim casting needs to find every live monster without
	# a container reference (Player and Projectile are siblings of whatever
	# Node3D happens to hold monsters today) — a group is the boring, decoupled
	# way to do that.
	add_to_group("monsters")
	_health_bar = HealthBar3D.new()
	_health_bar.position = Vector3(0, HEALTH_BAR_HEIGHT, 0)
	_health_bar.name = "HealthBar3D"
	add_child(_health_bar)


## Injects everything this monster needs: its `monsters.json` entry, the `combat`
## constants object, the scene-shared calculator (one RNG stream, ADR 0004) and
## the player to hunt. Until this is called the monster stands inert.
##
## [param is_elite] and [param elite_config] are G7 additions (docs/0020):
## MonsterSpawner decides elite-or-not (domain-testable via
## [method MonsterSpawnPicker.roll_is_elite]) and hands the shared/combat.json
## `elite` multiplier block straight through — this scene adapter only ever
## applies the numbers, it never decides them.
func setup(
	data: Dictionary,
	combat_constants: Dictionary,
	calculator: DamageCalculator,
	target: Player,
	is_elite: bool = false,
	elite_config: Dictionary = {}
) -> void:
	_data = data
	_combat_constants = combat_constants
	_calculator = calculator
	_target = target
	_is_elite = is_elite
	_elite_config = elite_config if is_elite else {}
	_health = Health.new(
		int(round(int(data.get("max_health", 1)) * _elite_multiplier("max_health_multiplier")))
	)
	_attack = CombatProfiles.attack_from_data(data)
	_move_speed = float(data.get("move_speed", 0.0)) * _elite_multiplier("move_speed_multiplier")
	_attack_range = float(data.get("attack_range", 1.0))
	_seconds_between_attacks = 1.0 / maxf(float(data.get("attack_speed", 1.0)), 0.01)
	_build_visual(String(data.get("id", "")))
	if _is_elite:
		var scale: float = _elite_multiplier("visual_scale")
		_body.scale = Vector3.ONE * scale
	# Recomputed here (not left at _ready's default) now that elite state is
	# known — the same visual_scale factor that grew the silhouette grows the
	# bar's clearance above it, so it keeps the same ~0.3 m margin G5 tuned.
	_health_bar.position = Vector3(0, HEALTH_BAR_HEIGHT * _elite_multiplier("visual_scale"), 0)
	_update_health_bar()


func is_dead() -> bool:
	return _health != null and _health.is_dead()


## This monster's `monsters.json` id — the key loot tables reference.
func monster_id() -> String:
	return String(_data.get("id", ""))


## This monster's `monsters.json` `xp_reward` — main.gd grants it to the player
## on death (G3, docs/0017), the same way it already reads loot off `_data`.
## Elites (G7, docs/0020) grant `xp_multiplier` times as much.
func xp_reward() -> int:
	return int(round(int(_data.get("xp_reward", 0)) * _elite_multiplier("xp_multiplier")))


## Whether this spawn is an ELITE variant (G7, docs/0020). main.gd reads this
## the same way it already reads [method monster_id] to bias the loot roll
## toward higher rarities.
func is_elite() -> bool:
	return _is_elite


## [param key]'s value from the elite config, or 1.0 (no-op) when this monster
## isn't elite or the key is missing — every elite-affecting stat computation
## funnels through this so "not elite" is always exactly the pre-G7 numbers.
func _elite_multiplier(key: String) -> float:
	if not _is_elite:
		return 1.0
	return float(_elite_config.get(key, 1.0))


func current_health() -> int:
	return _health.current if _health != null else 0


## This monster's max HP — an elite's (G7, docs/0020) is already
## `max_health_multiplier` times the data value, computed once in [method setup].
## Mirrors [method Player.max_health]; scene tests use it to assert the elite
## HP bump directly rather than inferring it from a hit count.
func max_health() -> int:
	return _health.max_health if _health != null else 0


## This monster's effective move speed — already scaled by
## `move_speed_multiplier` for an elite (G7, docs/0020). Exposed for scene
## tests the same reason [method max_health] is.
func move_speed() -> float:
	return _move_speed


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
		# Empty the bar before the corpse (and the bar, its child) is freed —
		# "empties then hides" (G4 ticket) in the frame the kill lands.
		_update_health_bar()
		died.emit(self)
		queue_free()
	else:
		CombatFx.flash_all(_body_parts)
		_update_health_bar()


## Pushes the current health fraction to the floating bar and emits
## [signal health_changed]. Monster max health never changes post-spawn (no
## level system on this side), so reading `_health.max_health` here — rather
## than caching a denominator elsewhere — is just consistency with [Player]'s
## equivalent, not a correctness requirement.
func _update_health_bar() -> void:
	if _health_bar == null or _health == null:
		return
	_health_bar.set_fraction(float(_health.current) / float(_health.max_health))
	health_changed.emit()


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


## G5 (issue #12): builds this monster's low-poly silhouette under
## [member _body] from stacked box parts, chosen by [param id] so
## fallen_imp and cinder_wraith read as visually distinct creatures even
## though they share the same capsule collision (visual swap only, per the
## ticket). Falls back to the fallen_imp shape for any id this hasn't been
## taught yet, so a future monsters.json entry never ends up invisible.
func _build_visual(id: String) -> void:
	match id:
		"cinder_wraith":
			_build_cinder_wraith()
		_:
			_build_fallen_imp()


## Small hunched imp: solid, low, four box parts plus a pair of angled horns
## and a snout poking forward along -Z (the facing indicator every combatant
## needs — see player.tscn's "Nose"). Tops out around y=1.22, close to the
## old shared capsule mesh's 1.2 m height. Warm solid-red palette.
func _build_fallen_imp() -> void:
	var hide_color: Color = Color(0.63, 0.22, 0.2)
	var dark_color: Color = Color(0.35, 0.15, 0.12)
	_add_box_part(Vector3(0.32, 0.35, 0.3), Vector3(0, 0.175, 0), dark_color)
	_add_box_part(Vector3(0.44, 0.4, 0.36), Vector3(0, 0.55, 0), hide_color)
	_add_box_part(Vector3(0.26, 0.26, 0.26), Vector3(0, 0.88, 0), Color(0.5, 0.18, 0.16))
	_add_box_part(Vector3(0.14, 0.14, 0.24), Vector3(0, 0.85, -0.2), Color(0.2, 0.08, 0.08))
	_add_box_part(
		Vector3(0.06, 0.22, 0.06), Vector3(-0.09, 1.11, 0.02), Color(0.15, 0.05, 0.05), Vector3(0, 0, -20)
	)
	_add_box_part(
		Vector3(0.06, 0.22, 0.06), Vector3(0.09, 1.11, 0.02), Color(0.15, 0.05, 0.05), Vector3(0, 0, 20)
	)


## Tall, thin, hooded wraith: a wide skirt base, a slender floating cloak,
## trailing tendril arms, and a bright ember-orange glow at the front of the
## hood doubling as the facing indicator (-Z, same convention as the imp's
## snout). Deliberately taller (~1.49 m) and much narrower (0.3 m cloak vs
## the imp's 0.44 m torso) with a cold dark-purple/charcoal palette against
## the imp's warm solid red — distinct in silhouette *and* color, per the
## ticket's requirement that the two monster types read apart.
func _build_cinder_wraith() -> void:
	var cloak_color: Color = Color(0.22, 0.18, 0.22)
	var trim_color: Color = Color(0.2, 0.08, 0.05)
	var glow_color: Color = Color(1.0, 0.45, 0.1)
	_add_box_part(Vector3(0.55, 0.15, 0.5), Vector3(0, 0.075, 0), trim_color)
	_add_box_part(Vector3(0.3, 1.1, 0.26), Vector3(0, 0.7, 0), cloak_color)
	_add_box_part(Vector3(0.07, 0.6, 0.07), Vector3(-0.2, 0.7, 0), cloak_color)
	_add_box_part(Vector3(0.07, 0.6, 0.07), Vector3(0.2, 0.7, 0), cloak_color)
	_add_box_part(Vector3(0.24, 0.24, 0.24), Vector3(0, 1.37, 0), Color(0.15, 0.12, 0.15))
	_add_box_part(Vector3(0.1, 0.08, 0.05), Vector3(0, 1.37, -0.135), glow_color)


## Instances a flat-shaded [BoxMesh] part (matching every other mesh in the
## project — BoxMesh's per-face normals are already hard, no smoothing group),
## positions/tints it, and appends the resulting [MeshInstance3D] to
## [member _body_parts] so [method take_hit] can flash the whole silhouette at
## once. `rotation_degrees` defaults to no rotation — only the imp's angled
## horns need it.
func _add_box_part(
	size: Vector3,
	offset: Vector3,
	color: Color,
	rotation_degrees: Vector3 = Vector3.ZERO
) -> void:
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	var material: StandardMaterial3D = StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 1.0
	var instance: MeshInstance3D = MeshInstance3D.new()
	instance.mesh = mesh
	instance.material_override = material
	instance.position = offset
	instance.rotation_degrees = rotation_degrees
	_body.add_child(instance)
	_body_parts.append(instance)
