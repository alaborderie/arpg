extends Node3D
## Root scene: composes the test map, player, monsters and camera rig, and turns
## pointer input into orders — click a monster to attack it, click ground to move.
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
## How far a pick ray reaches into the scene, in metres. Generous on purpose: the
## orthographic camera sits 24 units out, and rays are cheap.
const PICK_RAY_LENGTH: float = 200.0

const MONSTER_SCENE: PackedScene = preload("res://scenes/monster/monster.tscn")
## The one M2 monster type; its stats live in `shared/monsters.json`.
const MONSTER_ID: String = "fallen_imp"
## Where the imps stand on the test map — level layout, not balance data. Far
## corners on purpose: the chasers take a few seconds to reach the player's
## starting area, so movement (and its tests) get an uncontested window first.
const MONSTER_SPAWNS: Array[Vector3] = [
	Vector3(16.0, 0.0, -14.0),
	Vector3(14.0, 0.0, 16.0),
]

## One RNG stream and one calculator for the whole scene (ADR 0004): every hit,
## whoever swings, draws from the same reproducible sequence.
var _rng: RngService
var _calculator: DamageCalculator
var _pending_click: Vector2 = Vector2.ZERO
var _has_pending_click: bool = false

@onready var _player: Player = $Player
@onready var _camera_rig: CameraRig = $CameraRig
@onready var _sun: DirectionalLight3D = $Sun
@onready var _monsters: Node3D = $Monsters


func _ready() -> void:
	_orient_sun()
	_rng = RngService.new(randi())
	_calculator = DamageCalculator.new(_rng)
	_player.setup_combat(_calculator)
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


## Turns a click into an order: a monster under the cursor means "attack it",
## anything else projects onto the ground plane and means "walk there".
func _resolve_click(screen_pos: Vector2) -> void:
	var camera: Camera3D = _camera_rig.camera()
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_direction: Vector3 = camera.project_ray_normal(screen_pos)

	var monster: Monster = _pick_monster(ray_origin, ray_direction)
	if monster != null and not monster.is_dead():
		_player.order_attack(monster)
		return

	var hit: Variant = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit != null:
		_player.move_to(hit)


## Raycasts the physics space for a monster body under the cursor, or null.
func _pick_monster(ray_origin: Vector3, ray_direction: Vector3) -> Monster:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		ray_origin, ray_origin + ray_direction * PICK_RAY_LENGTH, MONSTER_PICK_MASK
	)
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = result.get("collider", null)
	return collider as Monster


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


## Angles the key light so the flat-shaded geometry reads with clear light/shade.
func _orient_sun() -> void:
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
