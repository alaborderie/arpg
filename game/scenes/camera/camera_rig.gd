class_name CameraRig
extends Node3D
## Isometric-angle orthographic camera locked onto a target — no smoothing lag.
##
## The rig node itself is the focus point: every frame it snaps straight to
## [member target]'s position (no lerp/glide), while the child [Camera3D] sits at a
## fixed pitch/yaw offset looking at the rig. Moving the rig therefore pans the
## classic Diablo/PoE framing without ever changing the viewing angle.
##
## G1 (the larger 200x200 map) dropped the exponential-smoothing follow this rig
## used to do: on a small test map the lag was barely noticeable, but it reads as
## drift once the player can walk far in one direction, and the ticket calls for
## the camera to feel perfectly centered at all times. A hard-lock is also simpler
## and, unlike smoothing, has no per-frame accumulated floating-point drift.

## Downward tilt of the camera, in degrees (0 = horizon, 90 = straight down).
const PITCH_DEGREES: float = 50.0
## Compass rotation of the camera around the focus point, in degrees.
const YAW_DEGREES: float = 45.0
## How far back the orthographic camera sits from the focus point.
const DISTANCE: float = 24.0

## Node the rig locks onto each frame. Unset means the rig stays put.
@export var target: Node3D

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
	if target != null:
		global_position = target.global_position


func _process(_delta: float) -> void:
	if target == null:
		return
	global_position = target.global_position


## The camera other systems should use for screen-to-world queries.
func camera() -> Camera3D:
	return _camera
