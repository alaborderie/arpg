extends Node3D
## Root of the boot scene.
##
## Godot note: a `.gd` script attached to a scene node is where per-scene behaviour
## lives. Per our architecture rule, scenes are *thin adapters* — they wire input,
## rendering and the scene tree to the pure logic in `res://domain/`. They must not
## contain game rules. For M0 this scene only arranges an isometric-angle camera over
## an empty ground plane so we can confirm the project boots and renders.

## Downward tilt of the camera, in degrees (0 = horizon, 90 = straight down).
const CAMERA_PITCH_DEGREES: float = 50.0
## Compass rotation of the camera around the scene, in degrees.
const CAMERA_YAW_DEGREES: float = 45.0
## How far back the orthographic camera sits from the focus point.
const CAMERA_DISTANCE: float = 24.0

@onready var _camera: Camera3D = $Camera3D
@onready var _sun: DirectionalLight3D = $Sun


func _ready() -> void:
	_position_isometric_camera()
	_orient_sun()


## Places the camera at a fixed pitch/yaw and aims it at the world origin, giving
## the classic angled top-down ARPG framing (Diablo/PoE style).
func _position_isometric_camera() -> void:
	var yaw: float = deg_to_rad(CAMERA_YAW_DEGREES)
	var pitch: float = deg_to_rad(CAMERA_PITCH_DEGREES)
	var offset: Vector3 = Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * CAMERA_DISTANCE
	_camera.position = offset
	_camera.look_at(Vector3.ZERO, Vector3.UP)


## Angles the key light so the flat-shaded geometry reads with clear light/shade.
func _orient_sun() -> void:
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
