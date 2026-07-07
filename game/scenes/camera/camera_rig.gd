class_name CameraRig
extends Node3D
## Isometric-angle orthographic camera that follows a target smoothly.
##
## The rig node itself is the focus point: it glides toward [member target] every
## frame, while the child [Camera3D] sits at a fixed pitch/yaw offset looking at the
## rig. Moving the rig therefore pans the classic Diablo/PoE framing without ever
## changing the viewing angle.

## Downward tilt of the camera, in degrees (0 = horizon, 90 = straight down).
const PITCH_DEGREES: float = 50.0
## Compass rotation of the camera around the focus point, in degrees.
const YAW_DEGREES: float = 45.0
## How far back the orthographic camera sits from the focus point.
const DISTANCE: float = 24.0

## Node the rig glides toward each frame. Unset means the rig stays put.
@export var target: Node3D
## Follow stiffness: higher snaps harder. Applied frame-rate-independently.
@export var follow_speed: float = 8.0

@onready var _camera: Camera3D = $Camera3D


func _ready() -> void:
	var yaw: float = deg_to_rad(YAW_DEGREES)
	var pitch: float = deg_to_rad(PITCH_DEGREES)
	_camera.position = Vector3(
		sin(yaw) * cos(pitch),
		sin(pitch),
		cos(yaw) * cos(pitch)
	) * DISTANCE
	_camera.look_at(global_position, Vector3.UP)


func _process(delta: float) -> void:
	if target == null:
		return
	# Exponential smoothing with a delta-based factor so the glide feels identical
	# at any frame rate (a plain constant-factor lerp would not).
	var weight: float = 1.0 - exp(-follow_speed * delta)
	global_position = global_position.lerp(target.global_position, weight)


## The camera other systems should use for screen-to-world queries.
func camera() -> Camera3D:
	return _camera
