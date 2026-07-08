class_name MonsterSpawner
extends Node3D
## Keeps the world populated with monsters forever: maintains a target alive
## population in a ring around the player, cleans up far-away ground drops
## ("corpses" nobody came back for) so an infinite run doesn't accumulate
## clutter, and never touches a live monster near the player.
##
## Adapter (ADR 0003): [MonsterSpawnPicker] (domain) supplies which monster id to
## spawn and a raw ring offset from an injected [RngService] stream (ADR 0004);
## this Node does the engine-only parts — snapping that offset onto the baked
## navmesh via [NavigationServer3D], instancing [Monster], and periodic polling.
## Design rationale (ring radii, the dedicated RNG stream, why the spawn stream
## is deliberately not saved) is in docs/0015.
##
## Test knob: set [member target_population] / [member forced_monster_id] /
## [member forced_elite] via `.set()` before this node enters the tree — same
## idiom `main.gd`'s `rng_seed` export already uses — for fully deterministic
## scene tests. Population 0 disables spawning outright; a nonzero population
## plus a forced id reproduces a fixed roster without ever touching the spawn
## RNG stream (so it can't perturb the loot/combat streams' sequences),
## matching the fixed two-imp roster the M1-M4 scene tests were written
## against. [member forced_elite] mirrors that: -1 (default) lets the spawn
## stream's elite roll decide per spawn, 0/1 force every spawn non-elite/elite
## without ever drawing from the stream (G7, docs/0020) — every existing scene
## test that pins a kill sequence to a swept seed now also pins this to 0, the
## same "pin the new knob or get the full default experience" rule G1/G2 set.

## Default alive-population the spawner tries to maintain around the player.
## Halved 10 -> 5 for G7 (issue #14, docs/0020): fewer, spicier monsters now
## that a fraction of them are elites.
const DEFAULT_TARGET_POPULATION: int = 5
## Never spawn closer than this to the player — keeps a fresh spawn from
## dropping in right on top of them.
const MIN_SPAWN_RADIUS: float = 14.0
## Never spawn farther than this from the player — spawns stay "around" them
## rather than scattering across the whole 200x200 map.
const MAX_SPAWN_RADIUS: float = 30.0
## Ground drops farther than this from the player are corpses nobody is going
## back for; despawn them so Drops doesn't grow unbounded over an infinite run.
## Comfortably above MAX_SPAWN_RADIUS so a drop from a monster that just spawned
## (or wandered a little before dying) is never swept up immediately.
const DROP_DESPAWN_RADIUS: float = 45.0
## How often (seconds) the spawner re-checks population/cleanup. Every physics
## tick would be wasted work for something this coarse-grained.
const TICK_INTERVAL: float = 0.5
## How many navmesh-snap attempts a single spawn gets before giving up for this
## tick (e.g. the player is pressed into a map corner). Cheap; just retried
## next tick.
const MAX_PLACEMENT_ATTEMPTS: int = 8
## Both current monster ids (shared/monsters.json); picked from uniformly unless
## [member forced_monster_id] pins one for a test.
const MONSTER_IDS: Array[String] = ["fallen_imp", "cinder_wraith"]

const MONSTER_SCENE: PackedScene = preload("res://scenes/monster/monster.tscn")

## Alive-population target; 0 disables spawning (test knob, see class doc).
@export var target_population: int = DEFAULT_TARGET_POPULATION
## Non-empty forces every spawn to this monster id instead of picking from
## MONSTER_IDS (test knob, see class doc).
@export var forced_monster_id: String = ""
## -1 (default): the spawn stream's elite roll decides per spawn. 0/1: force
## every spawn non-elite/elite, skipping that draw entirely (test knob, see
## class doc; G7, docs/0020).
@export var forced_elite: int = -1

## Emitted right after a monster is instanced and set up, so main.gd can wire
## its `died` signal the same way it always has (loot rolling unchanged).
signal monster_spawned(monster: Monster)

var _player: Player
var _monsters: Node3D
var _drops: Node3D
var _calculator: DamageCalculator
var _combat_constants: Dictionary = {}
var _monster_data_by_id: Dictionary = {}
## The `elite` block of shared/combat.json (G7, docs/0020): multipliers Monster
## applies when a spawn rolls elite, loaded once here and handed to every
## Monster.setup() call so tuning the numbers never touches GDScript.
var _elite_config: Dictionary = {}
## Cached from _elite_config's `spawn_chance` so MonsterSpawnPicker.roll_is_elite
## (pure domain math) never has to know about BalanceData/file access.
var _elite_chance: float = 0.1
var _rng: RngService
## Primed at TICK_INTERVAL so the first refill happens on the first tick after
## [member _map_ready] flips, not TICK_INTERVAL later.
var _time_since_tick: float = TICK_INTERVAL
## Latches true once the navigation map answers queries. Spawning before that
## would burn RNG draws against a map that returns the zero vector for
## everything (ADR 0009's "mesh is unavailable for a few frames" caveat: the
## test map bakes synchronously in _ready, but the NavigationServer only
## exposes the mesh to queries after its next sync, one physics frame later).
## Gating on readiness instead of a fixed delay keeps the spawn stream
## deterministic: no draws are consumed until the map answers, however many
## frames the sync takes on a given platform.
var _map_ready: bool = false


## Injects everything the spawner needs. [param rng] is a dedicated stream
## (ADR 0004/0011 pattern) — main.gd seeds it separately from combat/loot so
## spawn choices never perturb either of those sequences. The first refill runs
## on the first physics frame after this call (see _time_since_tick).
func setup(
	player: Player,
	monsters: Node3D,
	drops: Node3D,
	calculator: DamageCalculator,
	rng: RngService
) -> void:
	_player = player
	_monsters = monsters
	_drops = drops
	_calculator = calculator
	_rng = rng
	var combat_data: Dictionary = BalanceData.load_combat()
	_combat_constants = combat_data.get("combat", {})
	_elite_config = combat_data.get("elite", {})
	_elite_chance = float(_elite_config.get("spawn_chance", 0.1))
	for monster_id: String in MONSTER_IDS:
		var data: Dictionary = BalanceData.monster(monster_id)
		if not data.is_empty():
			_monster_data_by_id[monster_id] = data


func _physics_process(delta: float) -> void:
	if _player == null:
		return
	if not _map_ready:
		_map_ready = _probe_map_ready()
		if not _map_ready:
			return
	_time_since_tick += delta
	if _time_since_tick < TICK_INTERVAL:
		return
	_time_since_tick = 0.0
	_refill()
	_despawn_far_drops()


## Whether the navigation map answers queries yet. An unsynced/empty map returns
## exactly Vector3.ZERO from map_get_closest_point; a genuine snapped point on
## this map never does — the baked mesh floats ~0.5 above the ground plane, so
## real answers always carry a nonzero y. Costs one query, zero RNG draws.
func _probe_map_ready() -> bool:
	var snapped: Vector3 = NavigationServer3D.map_get_closest_point(
		get_world_3d().navigation_map, _player.global_position + Vector3.UP
	)
	return not snapped.is_equal_approx(Vector3.ZERO)


## Tops the alive population back up to [member target_population]. Bounded by
## MAX_PLACEMENT_ATTEMPTS per spawn so a run of bad navmesh snaps can never hang.
func _refill() -> void:
	if target_population <= 0 or _player == null:
		return
	var alive: int = _count_alive_monsters()
	while alive < target_population:
		var spawn_position: Variant = _pick_spawn_position()
		if spawn_position == null:
			return
		_spawn_at(spawn_position)
		alive += 1


func _count_alive_monsters() -> int:
	var count: int = 0
	for child: Node in _monsters.get_children():
		if child is Monster:
			count += 1
	return count


## One validated spawn point, or null if none was found this tick. Draws a ring
## offset around the player (domain math, RNG-driven) and snaps it onto the
## baked navmesh; retries if the snap lands too close to the player (e.g. the
## raw offset fell outside the navmesh and got pulled back toward its edge, or
## the map hasn't synced yet and every query returns the zero vector).
func _pick_spawn_position() -> Variant:
	var map: RID = get_world_3d().navigation_map
	for _attempt: int in MAX_PLACEMENT_ATTEMPTS:
		var offset: Vector3 = MonsterSpawnPicker.ring_offset(
			MIN_SPAWN_RADIUS, MAX_SPAWN_RADIUS, _rng
		)
		var candidate: Vector3 = _player.global_position + offset
		var snapped: Vector3 = NavigationServer3D.map_get_closest_point(map, candidate)
		var flat_gap: Vector3 = snapped - _player.global_position
		flat_gap.y = 0.0
		if flat_gap.length() >= MIN_SPAWN_RADIUS:
			# Monsters stand on the ground plane (y = 0), like the fixed M2
			# spawns did; the navmesh point itself floats ~0.5 above it.
			snapped.y = 0.0
			return snapped
	return null


func _spawn_at(spawn_position: Vector3) -> void:
	var monster_id: String = (
		forced_monster_id if forced_monster_id != ""
		else MonsterSpawnPicker.pick_monster_id(MONSTER_IDS, _rng)
	)
	var data: Dictionary = _monster_data_by_id.get(monster_id, {})
	if data.is_empty():
		return
	# G7 (docs/0020): forced_elite skips the draw entirely, same reasoning
	# forced_monster_id already documents — pinning a test's elite state must
	# never shift the stream position later spawns/ring offsets depend on.
	var is_elite: bool = (
		forced_elite == 1 if forced_elite != -1
		else MonsterSpawnPicker.roll_is_elite(_rng, _elite_chance)
	)
	var monster: Monster = MONSTER_SCENE.instantiate() as Monster
	monster.position = spawn_position
	_monsters.add_child(monster)
	monster.setup(data, _combat_constants, _calculator, _player, is_elite, _elite_config)
	monster_spawned.emit(monster)


## Frees ground drops far enough from the player that nobody is coming back for
## them. Live monsters are never touched here, wherever they are.
func _despawn_far_drops() -> void:
	if _drops == null or _player == null:
		return
	for child: Node in _drops.get_children():
		var drop: GroundDrop = child as GroundDrop
		if drop == null:
			continue
		if drop.global_position.distance_to(_player.global_position) > DROP_DESPAWN_RADIUS:
			drop.queue_free()
