extends Node3D
## Root scene: composes the test map, player, monsters, loot and camera rig, and
## turns pointer input into orders — click a monster to attack it, click a ground
## drop to pick it up, click ground to move.
##
## Godot note: `_unhandled_input` receives events no UI control consumed, which is
## exactly what world-interaction input should listen to — once we grow menus and
## HUDs, clicks on them will never leak through to movement.
##
## Touch works through the same code path: the project enables (the default)
## `emulate_mouse_from_touch`, so taps arrive as left-mouse events and trigger the
## same actions. This is the boring, engine-blessed way to support both.
##
## Clicks are resolved on the next physics tick, not in the input callback:
## monster picking raycasts the physics space, and
## [PhysicsDirectSpaceState3D] may only be queried safely during physics
## processing (see docs/0010-click-targeting-and-combat-wiring.md).

## The infinite plane clicks are projected onto — the ground sits at y = 0. Picking
## against a mathematical plane needs no colliders and works even when the click is
## off the map; the NavigationAgent clamps the target to the walkable mesh.
const GROUND_PLANE: Plane = Plane(Vector3.UP, 0.0)
## Physics layer 2 is "monsters" (monster.tscn sets collision_layer = 3 = 1 | 2);
## the pick ray masks to it so ground and walls never swallow a monster click.
const MONSTER_PICK_MASK: int = 2
## Physics layer 3 is "ground drops" (ground_drop.tscn sets collision_layer = 4),
## following the same picking pattern as monsters (ADR 0010).
const DROP_PICK_MASK: int = 4
## One ray finds whichever clickable — monster or drop — is nearest the camera.
const PICK_MASK: int = MONSTER_PICK_MASK | DROP_PICK_MASK
## How far a pick ray reaches into the scene, in metres. Generous on purpose: the
## orthographic camera sits 24 units out, and rays are cheap.
const PICK_RAY_LENGTH: float = 200.0

const MONSTER_SCENE: PackedScene = preload("res://scenes/monster/monster.tscn")
const GROUND_DROP_SCENE: PackedScene = preload("res://scenes/loot/ground_drop.tscn")
## The one M2 monster type; its stats live in `shared/monsters.json`.
const MONSTER_ID: String = "fallen_imp"
## Where the imps stand on the test map — level layout, not balance data. Far
## corners on purpose: the chasers take a few seconds to reach the player's
## starting area, so movement (and its tests) get an uncontested window first.
const MONSTER_SPAWNS: Array[Vector3] = [
	Vector3(16.0, 0.0, -14.0),
	Vector3(14.0, 0.0, 16.0),
]

## Master seed for the scene's RNG streams. 0 (the default) means "randomize";
## integration tests (and, later, M4 saves / replays) set a fixed value before the
## scene enters the tree to make a whole run reproducible.
@export var rng_seed: int = 0

## One combat RNG stream and one calculator for the whole scene (ADR 0004): every
## hit, whoever swings, draws from the same reproducible sequence.
var _rng: RngService
var _calculator: DamageCalculator
## Loot rolls draw from their own stream, derived from the same master seed
## (ADR 0011): drops then depend only on the kill sequence, never on how many
## damage/crit rolls the fight happened to consume.
var _loot_rng: RngService
var _loot_roller: LootRoller
var _pending_click: Vector2 = Vector2.ZERO
var _has_pending_click: bool = false

@onready var _player: Player = $Player
@onready var _camera_rig: CameraRig = $CameraRig
@onready var _sun: DirectionalLight3D = $Sun
@onready var _monsters: Node3D = $Monsters
@onready var _drops: Node3D = $Drops
@onready var _inventory_panel: InventoryPanel = $InventoryPanel


func _ready() -> void:
	_orient_sun()
	var master_seed: int = rng_seed if rng_seed != 0 else randi()
	_rng = RngService.new(master_seed)
	_loot_rng = RngService.new(master_seed + 1)
	_calculator = DamageCalculator.new(_rng)
	_loot_roller = LootRoller.new(
		BalanceData.load_loot_tables(), BalanceData.load_items(), _loot_rng
	)
	_player.setup_combat(_calculator)
	_inventory_panel.setup(_player)
	_spawn_monsters()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_to") and event is InputEventMouseButton:
		_pending_click = (event as InputEventMouseButton).position
		_has_pending_click = true


func _physics_process(_delta: float) -> void:
	if not _has_pending_click:
		return
	_has_pending_click = false
	_resolve_click(_pending_click)


## Turns a click into an order: a monster under the cursor means "attack it", a
## ground drop means "pick it up", anything else projects onto the ground plane
## and means "walk there".
func _resolve_click(screen_pos: Vector2) -> void:
	var camera: Camera3D = _camera_rig.camera()
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_direction: Vector3 = camera.project_ray_normal(screen_pos)

	var picked: Object = _pick_clickable(ray_origin, ray_direction)
	var monster: Monster = picked as Monster
	if monster != null and not monster.is_dead():
		_player.order_attack(monster)
		return
	var drop: GroundDrop = picked as GroundDrop
	if drop != null:
		_player.order_pickup(drop)
		return

	var hit: Variant = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit != null:
		_player.move_to(hit)


## Raycasts the physics space for the nearest clickable body (monster or drop)
## under the cursor, or null. One ray, masked to the pickable layers only, so
## ground and walls never swallow the click (ADR 0010).
func _pick_clickable(ray_origin: Vector3, ray_direction: Vector3) -> Object:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		ray_origin, ray_origin + ray_direction * PICK_RAY_LENGTH, PICK_MASK
	)
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = result.get("collider", null)
	return collider


func _spawn_monsters() -> void:
	var monster_data: Dictionary = BalanceData.monster(MONSTER_ID)
	var combat_constants: Dictionary = BalanceData.load_combat().get("combat", {})
	if monster_data.is_empty():
		return
	for spawn: Vector3 in MONSTER_SPAWNS:
		var monster: Monster = MONSTER_SCENE.instantiate() as Monster
		monster.position = spawn
		_monsters.add_child(monster)
		monster.setup(monster_data, combat_constants, _calculator, _player)
		monster.died.connect(_on_monster_died)


## Rolls the dead monster's loot table and drops the result where it fell. The
## corpse is still valid during the `died` emission (freed right after).
func _on_monster_died(monster: Monster) -> void:
	var item: Dictionary = _loot_roller.roll_drop(monster.monster_id())
	if item.is_empty():
		return
	var drop: GroundDrop = GROUND_DROP_SCENE.instantiate() as GroundDrop
	drop.position = monster.global_position
	_drops.add_child(drop)
	drop.setup(item)


## Angles the key light so the flat-shaded geometry reads with clear light/shade.
func _orient_sun() -> void:
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
