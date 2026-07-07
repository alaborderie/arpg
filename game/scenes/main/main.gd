extends Node3D
## Root scene: composes the test map, player and camera rig, and turns pointer
## input into movement orders.
##
## Godot note: `_unhandled_input` receives events no UI control consumed, which is
## exactly what world-interaction input should listen to — once we grow menus and
## HUDs, clicks on them will never leak through to movement.
##
## Touch works through the same code path: the project enables (the default)
## `emulate_mouse_from_touch`, so taps arrive as left-mouse events and trigger the
## same `move_to` action. This is the boring, engine-blessed way to support both.

## The infinite plane clicks are projected onto — the ground sits at y = 0. Picking
## against a mathematical plane needs no colliders and works even when the click is
## off the map; the NavigationAgent clamps the target to the walkable mesh.
const GROUND_PLANE: Plane = Plane(Vector3.UP, 0.0)

@onready var _player: Player = $Player
@onready var _camera_rig: CameraRig = $CameraRig
@onready var _sun: DirectionalLight3D = $Sun


func _ready() -> void:
	_orient_sun()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_to") and event is InputEventMouseButton:
		_order_move_to_screen_point((event as InputEventMouseButton).position)


## Projects [param screen_pos] through the camera onto the ground plane and sends the
## player there.
func _order_move_to_screen_point(screen_pos: Vector2) -> void:
	var camera: Camera3D = _camera_rig.camera()
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_direction: Vector3 = camera.project_ray_normal(screen_pos)
	var hit: Variant = GROUND_PLANE.intersects_ray(ray_origin, ray_direction)
	if hit != null:
		_player.move_to(hit)


## Angles the key light so the flat-shaded geometry reads with clear light/shade.
func _orient_sun() -> void:
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
