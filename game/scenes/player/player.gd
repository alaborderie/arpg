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
## G6 adds [method cast_at]: main.gd's Q handler calls it with the mouse's
## ground-plane point, and it casts the *equipped* skill from wherever the
## player currently stands — no walk-into-range, no target lock. It shares the
## per-slot cooldown (`_slot_cooldowns`/`_slot_seconds_between_attacks`, G9
## generalizes these from single fields into arrays — see below) and the
## damage-resolution core ([method _resolve_hit_on]) with the click-order path
## in [method _try_attack]; only *how a victim is found* differs (a locked
## target there, an aim direction here). Ranged fires a [Projectile] in its new
## directional mode (constant velocity, no target, hits the first monster it
## passes within [constant Projectile.HIT_RADIUS]); melee resolves instantly
## against every live monster within that slot's attack range and
## [constant CAST_ARC_DEGREES] of the aim direction. docs/0019.
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
## G8 adds [method add_support]: a support id (`shared/supports.json`) joins
## `_owned_supports`, and [SupportCatalog.contribution_for_owned] becomes one
## more entry in the same `contributions` array (docs/0021) — supports are
## global, applying to whichever skill/equipment is active, exactly like the
## level bonus. [signal level_up] fires once per level crossed by
## [method gain_xp] (main.gd owns deciding whether that level offers a pick,
## since only it holds the dedicated RNG stream and the choice UI). Two
## cast-pipeline reads join `_recompose_stats`'s output: `added_projectiles`
## (how many extra projectiles a ranged cast fans out, [method _fire_projectile]/
## [method _fire_projectile_directional]) and `life_on_kill` (a flat heal
## main.gd applies via [method heal] after a kill it caused).
##
## G9 (issue #16, docs/0022) generalizes the single skill into three
## independent slots — Q (slot 0, always unlocked), W (slot 1, [SkillSlots]'
## level 10) and E (slot 2, level 20) — each with its OWN skill, attack
## profile/range/speed and cooldown timer, composed from the SAME shared
## `contributions` (equipment + level + supports) [method _recompose_stats]
## already built for slot 0 — supports and gear still apply everywhere, only
## the skill's own damage/range/crit/speed differ per slot. [method cast_at]
## grew an optional `slot` parameter (default 0, so every pre-G9 call site —
## main.gd's Q handler, every existing scene test — keeps compiling and
## behaving identically); main.gd's W/E handlers pass 1/2. [method set_skill]/
## [method skill_id] are now thin slot-0 aliases over [method set_slot_skill]/
## [method slot_skill_id] for the same reason.
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
## Total width of a Q-cast melee swing's forward arc, centered on the aim
## direction (G6, docs/0019) — e.g. a dead-on aim hits everything within 45
## degrees either side. Chosen to read as "a swing in front of you", wider
## than a pure line but nowhere near a full circle.
const CAST_ARC_DEGREES: float = 90.0
## Height above the player's origin the health bar floats at — just clear of
## the capsule's head (G4, issue #11; the capsule is 1.8 m tall centered at
## y=0.9, so its top sits around y=1.8).
const HEALTH_BAR_HEIGHT: float = 2.1
## Green fill, distinct from a monster bar's default red (docs: HealthBar3D).
const HEALTH_BAR_COLOR: Color = Color(0.25, 0.75, 0.3)
## Angular step between fanned-out projectiles when `added_projectiles` (G8,
## docs/0021) puts more than one in the air at once — small enough to read as
## "a fan from one cast", nowhere near the melee arc's 90 degrees.
const SUPPORT_PROJECTILE_FAN_DEGREES: float = 12.0

## G10 (issue #17, docs/0023): aim-assist snap radius for a free-aim ranged
## cast. At cast time (not per-tick in [Projectile]) we look for the live
## monster whose position is closest to the aim *line* — the ray from the
## caster's position along the aim direction, out to the casting slot's own
## range — and, if its perpendicular distance to that line is within this
## radius, snap the cast onto it with [method Projectile.setup_homing]
## instead of firing a pure [constant Projectile.Mode.DIRECTIONAL] shot. This
## is deliberately generous (bigger than [constant Projectile.HIT_RADIUS]):
## it is what makes an aimed shot at a *moving* monster reliable, since a
## homing projectile re-tracks its target every tick and therefore cannot
## whiff from lateral drift during flight, unlike a fixed-direction shot.
const AIM_ASSIST_RADIUS: float = 1.5

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
## Emitted once per level gained (G8, docs/0021) — [param level] is the level
## just reached. main.gd listens to decide whether this level offers a
## support pick (it owns the dedicated RNG stream and choice UI); multiple
## levels crossed by one big XP grant each emit their own signal, in order, so
## main.gd can queue rather than stack their offers.
signal level_up(level: int)

## Effective stats: base config composed with equipped items (see _recompose_stats).
var _config: Dictionary = {}
## The pristine `player` object of `shared/player.json`.
var _base_config: Dictionary = {}
## The three skill slots (G9, docs/0022) — index 0 is Q (always unlocked),
## 1 is W ([SkillSlots] level 10), 2 is E (level 20). Each entry is a
## `shared/skills.json` entry, empty until main.gd calls [method set_slot_skill]
## for that slot (the pre-pick window for slot 0, or before a slot's own pick,
## while a choice screen has the tree paused). Sized to [constant SkillSlots.SLOT_COUNT].
var _slot_skills: Array[Dictionary] = [{}, {}, {}]
## Cached from each slot's `skill.kind` so _recompose_stats/_cast don't
## re-parse it every call. "melee" until that slot's skill is set.
var _slot_kinds: Array[String] = ["melee", "melee", "melee"]
## Per-slot composed attack range/speed/profile/cooldown — see _recompose_stats.
var _slot_attack_ranges: Array[float] = [DEFAULT_ATTACK_RANGE, DEFAULT_ATTACK_RANGE, DEFAULT_ATTACK_RANGE]
var _slot_seconds_between_attacks: Array[float] = [
	1.0 / DEFAULT_ATTACK_SPEED, 1.0 / DEFAULT_ATTACK_SPEED, 1.0 / DEFAULT_ATTACK_SPEED,
]
var _slot_attacks: Array[AttackProfile] = [null, null, null]
## Seconds until each slot's next cast/swing is allowed; 0 means ready. Ticks
## down independently per slot in _physics_process — W on cooldown never
## blocks Q or E.
var _slot_cooldowns: Array[float] = [0.0, 0.0, 0.0]
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
## The support catalog (G8, docs/0021), loaded once from `shared/supports.json` —
## same self-loading pattern as `_progression`.
var _support_catalog: SupportCatalog
## Owned support ids, duplicates allowed (stacking — docs/0021). Persisted
## as-is (SaveData).
var _owned_supports: Array[String] = []
## Composed `projectile_speed` (G8): `faster_projectiles` scales this via
## `PlayerStats.compose`; defaults to `Projectile.SPEED` before any data loads.
var _projectile_speed: float = Projectile.SPEED
## Composed `added_projectiles` (G8): how many EXTRA projectiles a ranged cast
## fans out beyond the first.
var _added_projectiles: int = 0
## Composed `life_on_kill` (G8): flat heal main.gd applies via [method heal]
## after a kill this player caused.
var _life_on_kill: int = 0
var _move_speed: float = DEFAULT_MOVE_SPEED
var _health: Health
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
## G5 (issue #12): the low-poly body is several stacked box parts (legs,
## torso, arms, head) under the "Body" Node3D rather than one capsule mesh —
## gathered once here so hit-flash and the death tint can apply to every part
## at once (see CombatFx.flash_all, _die).
@onready var _body_parts: Array[MeshInstance3D] = _collect_body_parts()


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
	_support_catalog = SupportCatalog.new(BalanceData.load_supports())
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


## Slot 0 / Q's current outgoing-hit profile (base + equipment). Read-only
## access for UI and tests; hits themselves are resolved in _try_attack. Use
## [method slot_skill]/`_slot_attacks` (no public getter yet — nothing outside
## this class has needed slot 1/2's profile directly) for another slot.
func attack_profile() -> AttackProfile:
	return _slot_attacks[0]


func inventory() -> Inventory:
	return _inventory


## Sets slot 0 / Q's skill (G2) and recomposes stats so it takes effect
## immediately — called once by main.gd after a fresh pick, a save load, or a
## test's `starting_skill_id` pin. [param skill] is a `shared/skills.json` entry
## (see [SkillCatalog]); an empty Dictionary is a no-op safety net for a bad id.
## A thin alias over [method set_slot_skill] (G9, docs/0022) kept under its
## original name since every pre-G9 caller already spells it this way.
func set_skill(skill: Dictionary) -> void:
	set_slot_skill(0, skill)


## Slot 0 / Q's skill id, or "" before one has been set. Read by main.gd to
## persist the choice (M4/G2, [SaveData]). A thin alias over
## [method slot_skill_id] (G9, docs/0022).
func skill_id() -> String:
	return slot_skill_id(0)


## Sets [param slot]'s skill (G9, docs/0022 — [param slot] is 0/Q, 1/W or 2/E)
## and recomposes stats so it takes effect immediately. Called by main.gd after
## a fresh Q pick, a level-10/20 W/E pick, a save load (including the
## retroactive-unlock catch-up), or a test driving a slot directly. [param skill]
## is a `shared/skills.json` entry; an empty Dictionary is a no-op safety net —
## for a bad id, AND for the ordinary "this slot has no pick yet" case a save's
## `secondary_skill_id`/`tertiary_skill_id` produces before level 10/20.
func set_slot_skill(slot: int, skill: Dictionary) -> void:
	if skill.is_empty():
		return
	_slot_skills[slot] = skill
	_recompose_stats()


## [param slot]'s skill id, or "" before that slot has a pick. Read by main.gd
## to persist the choice (SaveData), by tests, and by the slot HUD.
func slot_skill_id(slot: int) -> String:
	return String(_slot_skills[slot].get("id", ""))


## [param slot]'s full `shared/skills.json` entry (empty if unset) — the slot
## HUD reads this for the name/element it displays.
func slot_skill(slot: int) -> Dictionary:
	return _slot_skills[slot]


## True once [param slot] has unlocked per [SkillSlots] (slot 0 always; slot 1
## at level 10, slot 2 at level 20).
func is_slot_unlocked(slot: int) -> bool:
	return SkillSlots.is_unlocked(slot, _level)


## The level [param slot] unlocks at (mirrors [SkillSlots.unlock_level]) — the
## slot HUD's "Lv N" locked-slot label reads this directly.
func slot_unlock_level(slot: int) -> int:
	return SkillSlots.unlock_level(slot)


## Fraction of [param slot]'s cooldown remaining, 0.0 (ready) to 1.0 (just
## cast) — the slot HUD's dimming reads this; no other code needs a fraction
## rather than the raw seconds-remaining internal state.
func slot_cooldown_fraction(slot: int) -> float:
	var total: float = _slot_seconds_between_attacks[slot]
	if total <= 0.0:
		return 0.0
	return clampf(_slot_cooldowns[slot] / total, 0.0, 1.0)


## Every slot's currently-bound skill id, empty slots omitted — main.gd passes
## this to [SkillCatalog.offer] as the level-10/20 offer's exclusion list
## (docs/0022: a fresh W/E offer never repeats a skill already sitting in
## another slot).
func owned_skill_ids() -> Array[String]:
	var ids: Array[String] = []
	for slot: int in SkillSlots.SLOT_COUNT:
		var id: String = slot_skill_id(slot)
		if not id.is_empty():
			ids.append(id)
	return ids


## Owned support ids (G8, docs/0021), duplicates preserved — read by main.gd
## to persist the choice (SaveData) and by tests to assert what got granted.
func owned_supports() -> Array[String]:
	return _owned_supports.duplicate()


## Grants [param support_id] (a `shared/supports.json` id) and recomposes
## stats so it takes effect immediately — called by main.gd after a level-up
## pick, a save load, or a test driving the effect directly. A no-op for an
## unknown id (same "degrade instead of crash" convention as [method set_skill]).
## Owning the same id twice is exactly the intended stacking behaviour
## (docs/0021) — nothing here deduplicates.
func add_support(support_id: String) -> void:
	if _support_catalog == null or _support_catalog.support(support_id).is_empty():
		return
	_owned_supports.append(support_id)
	_recompose_stats()


## The current composed flat heal-per-kill (G8, docs/0021's `life_on_kill`
## support) — main.gd reads this to apply the heal right after a kill this
## player caused.
func life_on_kill() -> int:
	return _life_on_kill


## Heals up to [param amount] hit points, clamped to the current max — never
## raises above it, mirroring [Health.take_damage]'s own clamping. A no-op for
## a non-positive amount. Used by [method life_on_kill]'s caller (main.gd) and
## available directly for tests.
func heal(amount: int) -> void:
	if amount <= 0 or _health == null:
		return
	_health.current = mini(_health.max_health, _health.current + amount)
	_update_health_bar()


## Grants [param amount] XP (G3, docs/0017) — main.gd calls this from
## `_on_monster_died` with the dead [Monster]'s `xp_reward`. A no-op for a
## non-positive amount (never emits, never zero-heals). If the new total
## crosses one or more level thresholds, recomposes stats for the new level
## (so the attack_speed/cast_speed/max_health bonus takes effect immediately)
## and heals to the new max — the one explicit level-up heal, documented in
## docs/0017 as the classic ARPG choice; a bare recompose alone never heals
## (see _recompose_stats). [signal level_up] fires once per level crossed, in
## order (G8, docs/0021) — a single big XP grant that crosses several levels
## emits several signals, so main.gd's queueing (not this function's concern)
## can collapse them into one offer at a time instead of stacking UIs. Always
## emits [signal xp_changed] on success so the XP bar UI redraws even when a
## kill doesn't cross a level threshold.
func gain_xp(amount: int) -> void:
	if amount <= 0 or _progression == null:
		return
	_xp += amount
	var new_level: int = _progression.level_for_total_xp(_xp)
	if new_level != _level:
		var old_level: int = _level
		_level = new_level
		_recompose_stats()
		_health.current = _health.max_health
		_update_health_bar()
		for crossed_level: int in range(old_level + 1, new_level + 1):
			level_up.emit(crossed_level)
	xp_changed.emit()


## Restores health, position, bag, equipped items, level, XP and owned
## supports from a migrated save envelope (M4, G3, G8 — see [SaveData] for the
## shape). Called by main once combat is wired up. Level/XP/supports are
## restored *before* the first recompose so the restored level's max-health
## bonus (and any owned support's effect) is already in `_config` when the
## saved health is clamped against it — clamping against the level-1/no-support
## default max first, then again after a second recompose, would silently cap
## a higher-level (or support-boosted) save's health at the wrong ceiling. A
## restored death (health <= 0) re-applies the death state.
func load_state(save: Dictionary) -> void:
	var player_data: Dictionary = save.get("player", {})
	_level = SaveData.level_from_player(save)
	_xp = SaveData.xp_from_player(save)
	_owned_supports = SaveData.supports_from_player(save)
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
##
## G8 (docs/0021): [SupportCatalog.contribution_for_owned] is one more
## contribution appended alongside equipment/level — supports are global, so
## this is the single place their effect reaches every stat the composition
## pipeline already understands. `_projectile_speed`/`_added_projectiles`/
## `_life_on_kill` are synced from the composed output the same way
## `_move_speed` already is.
##
## G9 (docs/0022): `contributions` (equipment + level + supports) is now
## composed once per slot, against each slot's OWN skill overlay — a support
## like `added_projectiles` or `increased_damage` therefore reaches whichever
## slot casts, not just slot 0. `_config` itself stays slot 0's composed
## Dictionary: `move_speed`/`max_health`/`projectile_speed`/`added_projectiles`/
## `life_on_kill` never come from a skill overlay (no skill sets those fields —
## see [SkillCatalog.attack_config]), so reading them off slot 0's composition
## is exactly as correct as any other slot's would be, and avoids composing a
## fourth, skill-less Dictionary just for these five fields.
func _recompose_stats() -> void:
	var contributions: Array[Dictionary] = []
	for item: Dictionary in _inventory.equipped_items():
		var base: Dictionary = _item_bases_by_id.get(String(item.get("base_id", "")), {})
		contributions.append(ItemStats.contribution(item, base))
	contributions.append(_progression.bonus_contribution(_level))
	if _support_catalog != null:
		contributions.append(_support_catalog.contribution_for_owned(_owned_supports))

	for slot: int in SkillSlots.SLOT_COUNT:
		var skill_base: Dictionary = _base_config.duplicate(true)
		var skill: Dictionary = _slot_skills[slot]
		if not skill.is_empty():
			skill_base.merge(SkillCatalog.attack_config(skill), true)
		var composed: Dictionary = PlayerStats.compose(skill_base, contributions)
		_slot_kinds[slot] = String(skill.get("kind", "melee"))
		_slot_attack_ranges[slot] = float(composed.get("attack_range", DEFAULT_ATTACK_RANGE))
		var speed_key: String = "cast_speed" if _slot_kinds[slot] == "ranged" else "attack_speed"
		_slot_seconds_between_attacks[slot] = 1.0 / maxf(
			float(composed.get(speed_key, DEFAULT_ATTACK_SPEED)), 0.01
		)
		_slot_attacks[slot] = CombatProfiles.attack_from_data(composed)
		if slot == 0:
			_config = composed

	_move_speed = float(_config.get("move_speed", DEFAULT_MOVE_SPEED))
	_projectile_speed = float(_config.get("projectile_speed", Projectile.SPEED))
	_added_projectiles = maxi(0, int(_config.get("added_projectiles", 0)))
	_life_on_kill = maxi(0, int(_config.get("life_on_kill", 0)))
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
		CombatFx.flash_all(_body_parts)
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
	# Each slot's cooldown ticks down independently (G9, docs/0022) — W on
	# cooldown never delays Q or E.
	for slot: int in SkillSlots.SLOT_COUNT:
		_slot_cooldowns[slot] = maxf(_slot_cooldowns[slot] - delta, 0.0)
	if _dead:
		velocity = Vector3.ZERO
		move_and_slide()
		return

	_validate_attack_target()
	_validate_pickup_target()
	if _attack_target != null:
		var to_target: Vector3 = _attack_target.global_position - global_position
		to_target.y = 0.0
		# The click-order path always swings slot 0 / Q's skill, unchanged since G2.
		if to_target.length() <= _slot_attack_ranges[0]:
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
	if _calculator == null or _slot_cooldowns[0] > 0.0:
		return
	_slot_cooldowns[0] = _slot_seconds_between_attacks[0]
	if _slot_kinds[0] == "ranged":
		_fire_projectile()
		return
	_resolve_hit_on(_attack_target, 0)


## Ranged-skill attack (G2, docs/0016): a simple target-locked homing
## [Projectile] instead of an instant hit — it resolves the actual damage
## through the same [DamageCalculator]/[DefenseProfile] path on impact, so
## melee and ranged skills share every rule except when the hit lands. The
## click-order path always swings slot 0 / Q's skill (G9, docs/0022) — order_attack
## never targeted a slot, so this stays as it was pre-G9.
##
## G8 (docs/0021): `added_projectiles` spawns that many extras, all homing on
## the same target — there's no "direction" to fan a lock-on shot around, so
## more projectiles here just means more separate hits on the one target
## (each spawned with a small sideways offset, purely cosmetic, so they don't
## render exactly on top of one another).
func _fire_projectile() -> void:
	var count: int = 1 + _added_projectiles
	var right: Vector3 = global_transform.basis.x
	for i: int in count:
		var offset: float = (float(i) - float(count - 1) / 2.0) * 0.3
		var projectile: Projectile = PROJECTILE_SCENE.instantiate() as Projectile
		get_parent().add_child(projectile)
		projectile.global_position = (
			global_position + Vector3.UP * PROJECTILE_SPAWN_HEIGHT + right * offset
		)
		projectile.setup_homing(_attack_target, _slot_attacks[0], _calculator, _projectile_speed)


## The Q/W/E-cast entry point (G6, issue #13, docs/0019; G9, issue #16,
## docs/0022) — main.gd's `cast_primary`/`cast_secondary`/`cast_tertiary`
## handlers call this with the mouse's ground-plane point and [param slot]
## (0/1/2; defaults to 0 so every pre-G9 call site — Q's own handler, every
## existing scene test — keeps compiling and behaving identically). Casts
## [param slot]'s skill from wherever the player currently stands: no
## walk-into-range (unlike [method order_attack]), no target lock, gated by
## THAT slot's own cooldown alone (a cast while its slot is on cooldown, or
## before its slot has unlocked per [SkillSlots], is silently ignored — no
## queueing, and a locked slot behaves exactly like an on-cooldown one).
## Faces the player toward [param aim_point] (Y-zeroed, same convention as
## movement facing) before the cast resolves — but only when the cast actually
## fires, so a rejected press does nothing at all, not even turn the character.
func cast_at(aim_point: Vector3, slot: int = 0) -> void:
	if _dead or _calculator == null or not is_slot_unlocked(slot) or _slot_cooldowns[slot] > 0.0:
		return
	var to_aim: Vector3 = aim_point - global_position
	to_aim.y = 0.0
	if to_aim.length_squared() > FACING_EPSILON:
		_face(to_aim)
	else:
		# Aiming (near) on top of ourselves: keep whatever direction we already
		# face rather than feeding a zero vector into range/arc math.
		to_aim = -global_transform.basis.z
	_slot_cooldowns[slot] = _slot_seconds_between_attacks[slot]
	_cast(to_aim, slot)


## The small core [param aim_direction]/[param slot] fans out into a ranged or
## melee cast (G6; G9 added [param slot]). Kept separate from [method cast_at]
## so a support-modified skill (G8, which changes what feeds each slot's
## composed fields upstream in _recompose_stats) never needs this or
## [method cast_at] touched.
func _cast(aim_direction: Vector3, slot: int) -> void:
	if _slot_kinds[slot] == "ranged":
		_fire_projectile_directional(aim_direction, slot)
	else:
		_melee_cast(aim_direction, slot)


## Fires a directional [Projectile] (G6, docs/0019) for [param slot] (G9,
## docs/0022): constant velocity along [param direction], no target, travels up
## to that slot's own `_slot_attack_ranges` metres before despawning, damaging
## the first live monster it passes within [constant Projectile.HIT_RADIUS] —
## see [method Projectile.setup_directional].
##
## G8 (docs/0021): `added_projectiles` (a GLOBAL support contribution, applied
## identically to every slot's composition — docs/0022) fans out that many
## extras around [param direction], each rotated
## [constant SUPPORT_PROJECTILE_FAN_DEGREES] further from center (symmetric
## either side for an even count) — this is the "small fan" the ticket asks
## for, and it works identically whether one or several are in the air, so a
## base cast (count 1) is just a fan of one with a zero offset.
##
## G10 (issue #17, docs/0023): aim assist looks up ONE snap target (see
## [method _find_aim_assist_target]) for the whole fan, computed once here at
## cast time — never per-tick in [Projectile]. Only the fan's center-most
## projectile (index `(count - 1) / 2`, integer division — the exact center
## for an odd count, the one just left of center for an even count) is
## switched to [method Projectile.setup_homing] on that target; every other
## projectile in the fan keeps flying its own fanned direction as a plain
## [constant Projectile.Mode.DIRECTIONAL] shot. A single un-fanned cast
## (`count == 1`) is the common case: it homes exactly when a target was
## found and flies directional otherwise, which is the whole free-aim/aim-
## assist behavior this ticket asks for.
func _fire_projectile_directional(direction: Vector3, slot: int) -> void:
	var forward: Vector3 = direction.normalized()
	var count: int = 1 + _added_projectiles
	var assist_target: Monster = _find_aim_assist_target(forward, _slot_attack_ranges[slot])
	var homing_index: int = (count - 1) / 2
	for i: int in count:
		var angle_degrees: float = (float(i) - float(count - 1) / 2.0) * SUPPORT_PROJECTILE_FAN_DEGREES
		var fanned_direction: Vector3 = forward.rotated(Vector3.UP, deg_to_rad(angle_degrees))
		var projectile: Projectile = PROJECTILE_SCENE.instantiate() as Projectile
		get_parent().add_child(projectile)
		projectile.global_position = global_position + Vector3.UP * PROJECTILE_SPAWN_HEIGHT
		if assist_target != null and i == homing_index:
			projectile.setup_homing(assist_target, _slot_attacks[slot], _calculator, _projectile_speed)
		else:
			projectile.setup_directional(
				fanned_direction, _slot_attack_ranges[slot], _slot_attacks[slot], _calculator,
				_projectile_speed
			)


## G10 (issue #17, docs/0023): the aim-assist lookup for a free-aim ranged
## cast. Scans the "monsters" group for the live monster whose perpendicular
## distance to the aim ray — from [member global_position] along [param
## direction] (already a unit vector), clamped to [param max_distance] — is
## smallest, and returns it if that distance is within
## [constant AIM_ASSIST_RADIUS]; otherwise null (pure directional flight,
## e.g. genuine free-fire at empty ground). A monster behind the caster
## (negative projection onto the ray) or beyond the skill's own range never
## qualifies — this is deliberately the skill's own reach, not "anywhere
## near the aim line forever". Ties broken by perpendicular distance alone;
## the exact tie-break doesn't matter at this game's live monster count
## (~5-10, ADR 0015).
func _find_aim_assist_target(direction: Vector3, max_distance: float) -> Monster:
	var best: Monster = null
	var best_distance: float = AIM_ASSIST_RADIUS
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		var monster: Monster = node as Monster
		if monster == null or monster.is_dead():
			continue
		var to_monster: Vector3 = monster.global_position - global_position
		to_monster.y = 0.0
		var along: float = to_monster.dot(direction)
		if along < 0.0 or along > max_distance:
			continue
		var perpendicular: Vector3 = to_monster - direction * along
		var distance: float = perpendicular.length()
		if distance <= best_distance:
			best = monster
			best_distance = distance
	return best


## Resolves a melee Q/W/E-cast instantly (G6, docs/0019; G9, docs/0022) for
## [param slot]: every live monster in the "monsters" group within that slot's
## `_slot_attack_ranges` and [constant CAST_ARC_DEGREES] of [param aim_direction]
## takes a hit via [method _resolve_hit_on] — a monster standing (almost) on
## top of the player is hit regardless of angle, since a direction to it is
## meaningless at zero distance. No auto-walk into range: anything outside
## that slot's range right now is simply missed.
func _melee_cast(aim_direction: Vector3, slot: int) -> void:
	var forward: Vector3 = aim_direction.normalized()
	var half_arc: float = deg_to_rad(CAST_ARC_DEGREES / 2.0)
	var attack_range: float = _slot_attack_ranges[slot]
	for node: Node in get_tree().get_nodes_in_group("monsters"):
		var monster: Monster = node as Monster
		if monster == null or monster.is_dead():
			continue
		var to_monster: Vector3 = monster.global_position - global_position
		to_monster.y = 0.0
		var distance: float = to_monster.length()
		if distance > attack_range:
			continue
		if distance > FACING_EPSILON and forward.angle_to(to_monster.normalized()) > half_arc:
			continue
		_resolve_hit_on(monster, slot)


## The shared damage-resolution core (G6, docs/0019; G9 added [param slot],
## docs/0022): builds [param monster]'s defense against [param slot]'s attack
## damage type, resolves the hit through the same injected [DamageCalculator],
## and hands the result to [method Monster.take_hit] — the one path every
## attack (click-order melee, any slot's cast) that lands an instant hit goes
## through, so a future change to the pipeline only has to happen here.
func _resolve_hit_on(monster: Monster, slot: int) -> void:
	var attack: AttackProfile = _slot_attacks[slot]
	var defense: DefenseProfile = monster.defense_profile(attack.damage_type)
	var result: DamageResult = _calculator.calculate_hit(attack, defense)
	monster.take_hit(result)


## Minimal M2 death: input orders are ignored and the body goes dark. A real
## death animation/respawn flow is future work. G5: one shared corpse material
## applied to every body part (a [Material] resource can be referenced by
## several [MeshInstance3D]s at once) so the whole silhouette tints, not just
## one piece of it.
func _die() -> void:
	_dead = true
	_attack_target = null
	velocity = Vector3.ZERO
	var corpse_material: StandardMaterial3D = StandardMaterial3D.new()
	corpse_material.albedo_color = Color(0.25, 0.24, 0.23)
	corpse_material.roughness = 1.0
	for part: MeshInstance3D in _body_parts:
		part.material_override = corpse_material


## Gathers every [MeshInstance3D] under the "Body" node (see player.tscn) once
## at [member _body_parts] init — the low-poly body is several stacked box
## parts rather than one mesh (G5, issue #12).
func _collect_body_parts() -> Array[MeshInstance3D]:
	var parts: Array[MeshInstance3D] = []
	for child: Node in $Body.get_children():
		if child is MeshInstance3D:
			parts.append(child as MeshInstance3D)
	return parts
