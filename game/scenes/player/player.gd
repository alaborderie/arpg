class_name Player
extends CharacterBody3D
## The player character: navigation-driven movement, plus M2 combat — an ordered
## melee attack against one [Monster], own health, and death — and M3 loot: an
## ordered pickup of one [GroundDrop], the [Inventory], and equipment. M4 adds
## [method load_state]: main.gd calls it once at boot when a save was found, to
## restore health/position/inventory in one shot (see [SaveData], docs/0012).
##
## Equipment data flow (M3): the player keeps the raw `player.json` object as
## `_base_config` and recomposes `_config` through [PlayerStats] + [ItemStats]
## whenever equipment changes. Everything downstream (attack profile, defence,
## speeds) reads `_config`, so gear changes numbers without forking any code path.
##
## G2 adds [method set_skill]: the chosen `shared/skills.json` entry replaces
## `_base_config`'s damage/range/crit/speed in that same recompose funnel, so
## equipment still composes on top unchanged. Melee skills swing exactly like
## the old basic attack; ranged skills fire a [Projectile] instead of resolving
## the hit instantly (see _try_attack/_fire_projectile). docs/0016.
##
## G3 adds [method gain_xp]: main.gd calls it with a dead monster's `xp_reward`
## (docs/0017). Levelling appends one more contribution Dictionary
## ([ProgressionCurve.bonus_contribution]) to the same array equipment already
## feeds, so the per-level attack_speed/cast_speed/max_health bonus goes through
## the exact same [PlayerStats.compose] funnel. `_recompose_stats` always syncs
## `_health.max_health` to whatever the composed stats say it should be
## (clamping `current` down if it shrank) but never heals on its own; a level-up
## is the one and only place that explicitly heals to full, right after
## recomposing for the new level — an equip/unequip recompose (no level change)
## never touches current health.
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
## How close (metres, between origins) the player must stand to grab a drop.
## Interaction feel, not balance — same layer as the swing-timing choice (ADR 0010).
const PICKUP_RANGE: float = 1.8
## Height above the player's origin a fired projectile spawns at — roughly
## chest/weapon height, purely cosmetic.
const PROJECTILE_SPAWN_HEIGHT: float = 1.0
## Height above the player's origin the health bar floats at — just clear of
## the capsule's head (G4, issue #11; the capsule is 1.8 m tall centered at
## y=0.9, so its top sits around y=1.8).
const HEALTH_BAR_HEIGHT: float = 2.1
## Green fill, distinct from a monster bar's default red (docs: HealthBar3D).
const HEALTH_BAR_COLOR: Color = Color(0.25, 0.75, 0.3)

const PROJECTILE_SCENE: PackedScene = preload("res://scenes/combat/projectile.tscn")

## Emitted whenever the bag or the equipped slots change (pickup, equip, unequip).
signal inventory_changed
## Emitted whenever XP or level changes (a kill, or a restored save) — the XP
## bar UI listens and re-reads [method xp_progress]/[method level] (G3, docs/0017).
signal xp_changed
## Emitted whenever current or max health changes (a hit, a level-up heal, an
## equip/unequip recompose, or a restored save) — G4, issue #11. The floating
## health bar updates itself directly from the same call sites; this signal
## exists for the same reason [signal xp_changed]/[signal inventory_changed]
## do — any other observer can redraw without polling.
signal health_changed

## Effective stats: base config composed with equipped items (see _recompose_stats).
var _config: Dictionary = {}
## The pristine `player` object of `shared/player.json`.
var _base_config: Dictionary = {}
## The active skill (G2, `shared/skills.json` entry) — replaces the unarmed
## baseline in _recompose_stats. Empty until main.gd calls [method set_skill]
## (the pre-pick window, while the choice screen has the tree paused).
var _skill: Dictionary = {}
## Cached from `_skill.kind` so _recompose_stats/_try_attack don't re-parse it
## every call. "melee" until a skill is set.
var _skill_kind: String = "melee"
## Item base definitions from `shared/items.json`, indexed by id.
var _item_bases_by_id: Dictionary = {}
var _combat_constants: Dictionary = {}
## The XP/level curve (G3, docs/0017), loaded once from `shared/progression.json`.
var _progression: ProgressionCurve
## Current level, starting at 1. Feeds one more contribution Dictionary into
## _recompose_stats via _progression.bonus_contribution.
var _level: int = 1
## Total accumulated XP (not "XP into the current level" — see xp_progress()
## for that breakdown). Persisted as-is (SaveData).
var _xp: int = 0
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
## Drop this player is ordered to grab; null while doing anything else.
var _pickup_target: GroundDrop
var _inventory: Inventory = Inventory.new()
var _dead: bool = false
## Floating world-space bar above the player's head (G4, issue #11).
var _health_bar: HealthBar3D

@onready var _agent: NavigationAgent3D = $NavigationAgent3D
@onready var _body: MeshInstance3D = $Body


func _ready() -> void:
	_base_config = BalanceData.load_player().get("player", {})
	_combat_constants = BalanceData.load_combat().get("combat", {})
	var bases: Array = BalanceData.load_items().get("bases", [])
	for entry: Variant in bases:
		if entry is Dictionary:
			var base: Dictionary = entry as Dictionary
			_item_bases_by_id[String(base.get("id", ""))] = base
	# Health stays on the base maximum initially: no health affixes exist in M3,
	# and level 1 (the default) carries no bonus (G3 changes this from level 2
	# on — see _recompose_stats).
	_health = Health.new(int(_base_config.get("max_health", DEFAULT_MAX_HEALTH)))
	_progression = ProgressionCurve.new(BalanceData.load_progression().get("progression", {}))
	_recompose_stats()
	_setup_health_bar()


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
	_pickup_target = null
	_agent.target_position = world_point


## Orders the player to attack [param target]: walk into range first if needed,
## then swing on cooldown until it (or this player) dies.
func order_attack(target: Monster) -> void:
	if _dead:
		return
	_pickup_target = null
	_attack_target = target


## Orders the player to pick up [param drop]: walk into PICKUP_RANGE first if
## needed, then move the item into the inventory (bag space permitting).
func order_pickup(drop: GroundDrop) -> void:
	if _dead:
		return
	_attack_target = null
	_pickup_target = drop
	_agent.target_position = drop.global_position


func is_dead() -> bool:
	return _dead


func current_health() -> int:
	return _health.current if _health != null else 0


## The current effective max health, after the level-bonus (and any future
## item) contribution — this is what a health bar's denominator should read
## (G4: this changes at runtime on a level-up, not just at boot).
func max_health() -> int:
	return _health.max_health if _health != null else 0


## Current level (G3, docs/0017), starting at 1.
func level() -> int:
	return _level


## Total accumulated XP. Read by main.gd to persist the save (SaveData).
func total_xp() -> int:
	return _xp


## Everything the XP bar UI needs in one call — see [ProgressionCurve.progress_for_total_xp].
func xp_progress() -> Dictionary:
	return _progression.progress_for_total_xp(_xp) if _progression != null else {}


## This player's defence against one incoming hit, built fresh from the composed
## stats — equipped armour and resistances are already folded into `_config`.
func defense_profile(incoming: AttackProfile.DamageType) -> DefenseProfile:
	return CombatProfiles.defense_from_data(_config, incoming, _combat_constants)


## The current outgoing-hit profile (base + equipment). Read-only access for UI
## and tests; hits themselves are resolved in _try_attack.
func attack_profile() -> AttackProfile:
	return _attack


func inventory() -> Inventory:
	return _inventory


## Sets the active skill (G2) and recomposes stats so it takes effect
## immediately — called once by main.gd after a fresh pick, a save load, or a
## test's `starting_skill_id` pin. [param skill] is a `shared/skills.json` entry
## (see [SkillCatalog]); an empty Dictionary is a no-op safety net for a bad id.
func set_skill(skill: Dictionary) -> void:
	if skill.is_empty():
		return
	_skill = skill
	_skill_kind = String(skill.get("kind", "melee"))
	_recompose_stats()


## The active skill's id, or "" before one has been set. Read by main.gd to
## persist the choice (M4/G2, [SaveData]).
func skill_id() -> String:
	return String(_skill.get("id", ""))


## Grants [param amount] XP (G3, docs/0017) — main.gd calls this from
## `_on_monster_died` with the dead [Monster]'s `xp_reward`. A no-op for a
## non-positive amount (never emits, never zero-heals). If the new total
## crosses one or more level thresholds, recomposes stats for the new level
## (so the attack_speed/cast_speed/max_health bonus takes effect immediately)
## and heals to the new max — the one explicit level-up heal, documented in
## docs/0017 as the classic ARPG choice; a bare recompose alone never heals
## (see _recompose_stats). Always emits [signal xp_changed] on success so the
## XP bar UI redraws even when a kill doesn't cross a level threshold.
func gain_xp(amount: int) -> void:
	if amount <= 0 or _progression == null:
		return
	_xp += amount
	var new_level: int = _progression.level_for_total_xp(_xp)
	if new_level != _level:
		_level = new_level
		_recompose_stats()
		_health.current = _health.max_health
		_update_health_bar()
	xp_changed.emit()


## Restores health, position, bag, equipped items, level and XP from a migrated
## save envelope (M4, G3 — see [SaveData] for the shape). Called by main once
## combat is wired up. Level/XP are restored *before* the first recompose so
## the restored level's max-health bonus is already in `_config` when the saved
## health is clamped against it — clamping against the level-1 default max
## first, then again after a second recompose, would silently cap a
## higher-level save's health at the wrong ceiling. A restored death
## (health <= 0) re-applies the death state.
func load_state(save: Dictionary) -> void:
	var player_data: Dictionary = save.get("player", {})
	_level = SaveData.level_from_player(save)
	_xp = SaveData.xp_from_player(save)
	_recompose_stats()
	_health.current = clampi(int(player_data.get("health", _health.max_health)), 0, _health.max_health)
	global_position = SaveData.position_from_player(save)
	_inventory.load_state(SaveData.bag_from_player(save), SaveData.equipped_from_player(save))
	_recompose_stats()
	inventory_changed.emit()
	xp_changed.emit()
	if _health.is_dead():
		_die()


## Equips the bag item at [param index] and recomposes stats. UI entry point.
func equip_bag_index(index: int) -> void:
	if _inventory.equip_bag_index(index):
		_recompose_stats()
		inventory_changed.emit()


## Moves the item in [param slot] back to the bag and recomposes stats. UI entry point.
func unequip_slot(slot: String) -> void:
	if _inventory.unequip(slot):
		_recompose_stats()
		inventory_changed.emit()


## Rebuilds the effective stats from base data + equipped items + the current
## level's bonus, and refreshes everything derived from them. The one funnel
## through which gear (and now level) acts (ADR 0011, docs/0017).
##
## G2 (docs/0016): the active skill's damage/range/crit/speed replace the same
## fields `_base_config` (the unarmed `shared/player.json` baseline) used to
## carry — equipment then composes on top exactly as before, including a
## weapon's implicit damage still overriding the skill's own damage number if
## one is equipped (the same "gear beats unarmed" precedent this pipeline
## already had). Melee skills read back `attack_speed`; ranged skills read
## `cast_speed` — see [PlayerStats.compose] for where both live.
##
## G3 (docs/0017): [ProgressionCurve.bonus_contribution] for the current level
## is appended to `contributions` right alongside equipment — one more
## Dictionary through the same funnel, no special-cased stat path. Afterwards,
## `_health.max_health` is synced to whatever `_config.max_health` came out to;
## if it changed, `current` is clamped down to fit (a hedge, not a heal — it
## only ever lowers `current`, never raises it). Healing to full on an actual
## level-up is [method gain_xp]'s job, done explicitly right after it calls
## this — that keeps an equip/unequip-only recompose (no level change, and
## today no item touches `max_health_pct` either) from ever refilling health as
## a side effect.
func _recompose_stats() -> void:
	var skill_base: Dictionary = _base_config.duplicate(true)
	if not _skill.is_empty():
		skill_base.merge(SkillCatalog.attack_config(_skill), true)

	var contributions: Array[Dictionary] = []
	for item: Dictionary in _inventory.equipped_items():
		var base: Dictionary = _item_bases_by_id.get(String(item.get("base_id", "")), {})
		contributions.append(ItemStats.contribution(item, base))
	contributions.append(_progression.bonus_contribution(_level))
	_config = PlayerStats.compose(skill_base, contributions)
	_move_speed = float(_config.get("move_speed", DEFAULT_MOVE_SPEED))
	_attack_range = float(_config.get("attack_range", DEFAULT_ATTACK_RANGE))
	var speed_key: String = "cast_speed" if _skill_kind == "ranged" else "attack_speed"
	_seconds_between_attacks = 1.0 / maxf(
		float(_config.get(speed_key, DEFAULT_ATTACK_SPEED)), 0.01
	)
	_attack = CombatProfiles.attack_from_data(_config)
	var new_max_health: int = maxi(1, int(_config.get("max_health", _health.max_health)))
	if new_max_health != _health.max_health:
		_health.max_health = new_max_health
		_health.current = mini(_health.current, new_max_health)
	_update_health_bar()


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
	_update_health_bar()


## Builds the floating health bar (G4, issue #11) once [member _health] exists
## and an initial [method _recompose_stats] has run. Placed above the head at
## [constant HEALTH_BAR_HEIGHT], tinted [constant HEALTH_BAR_COLOR] (green) to
## read as distinct from a monster's default red.
func _setup_health_bar() -> void:
	_health_bar = HealthBar3D.new()
	_health_bar.position = Vector3(0, HEALTH_BAR_HEIGHT, 0)
	_health_bar.name = "HealthBar3D"
	add_child(_health_bar)
	_health_bar.set_color(HEALTH_BAR_COLOR)
	_update_health_bar()


## Pushes the current health fraction to the floating bar and emits
## [signal health_changed]. Reads [method max_health] live rather than caching
## a denominator — it changes at runtime on every level-up (docs/0017's
## handoff note to this ticket). Called from every path that can move current
## or max health: [method take_hit], [method _recompose_stats] (equip/level
## changes), and [method gain_xp]'s explicit level-up heal. A no-op before the
## bar/health exist yet (the first [method _recompose_stats] call in _ready
## runs before [method _setup_health_bar]).
func _update_health_bar() -> void:
	if _health_bar == null or _health == null:
		return
	_health_bar.set_fraction(float(_health.current) / float(_health.max_health))
	health_changed.emit()


func _physics_process(delta: float) -> void:
	_attack_cooldown = maxf(_attack_cooldown - delta, 0.0)
	if _dead:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	_validate_attack_target()
	_validate_pickup_target()
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

	if _pickup_target != null:
		var to_drop: Vector3 = _pickup_target.global_position - global_position
		to_drop.y = 0.0
		if to_drop.length() <= PICKUP_RANGE:
			_complete_pickup()
			velocity = Vector3.ZERO
			move_and_slide()
			return

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


## Drops the pickup order if someone freed the drop out from under us.
func _validate_pickup_target() -> void:
	if _pickup_target != null and not is_instance_valid(_pickup_target):
		_pickup_target = null


## Grabs the ordered drop into the bag. A full bag leaves the drop on the ground
## (and clears the order, so we don't hover over it forever).
func _complete_pickup() -> void:
	var drop: GroundDrop = _pickup_target
	_pickup_target = null
	if _inventory.add(drop.item()):
		drop.queue_free()
		inventory_changed.emit()


func _face(direction: Vector3) -> void:
	if direction.length_squared() > FACING_EPSILON:
		# look_at points -Z (Godot's forward) at the target; keep the body upright
		# by looking at a point on our own height.
		look_at(global_position + direction, Vector3.UP)


func _try_attack() -> void:
	if _calculator == null or _attack_cooldown > 0.0:
		return
	_attack_cooldown = _seconds_between_attacks
	if _skill_kind == "ranged":
		_fire_projectile()
		return
	var defense: DefenseProfile = _attack_target.defense_profile(_attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(_attack, defense)
	_attack_target.take_hit(result)


## Ranged-skill attack (G2, docs/0016): a simple target-locked homing
## [Projectile] instead of an instant hit — it resolves the actual damage
## through the same [DamageCalculator]/[DefenseProfile] path on impact, so
## melee and ranged skills share every rule except when the hit lands.
func _fire_projectile() -> void:
	var projectile: Projectile = PROJECTILE_SCENE.instantiate() as Projectile
	get_parent().add_child(projectile)
	projectile.global_position = global_position + Vector3.UP * PROJECTILE_SPAWN_HEIGHT
	projectile.setup(_attack_target, _attack, _calculator)


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
