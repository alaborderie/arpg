class_name Player
extends CharacterBody3D
## The player character: navigation-driven movement toward ordered destinations.
##
## Godot notes: [CharacterBody3D] is the engine's kinematic body — it moves by
## `move_and_slide()` from a `velocity` we set each physics tick, rather than by
## forces. The child [NavigationAgent3D] asks the NavigationServer for a path across
## the baked navigation mesh and hands us one waypoint at a time via
## `get_next_path_position()`.
##
## This scene is an adapter (ADR 0003): it turns "go there" commands into engine
## movement. It holds no game rules; its one balance number (move speed) comes from
## `shared/player.json` via [BalanceData].
##
## Tuning constraint: the agent's `path_desired_distance`/`target_desired_distance`
## (set in player.tscn) must stay comfortably ABOVE the vertical gap between the
## baked navmesh surface (~0.5 above the ground plane) and this body's origin (on
## the ground plane) — the agent's waypoint-advance check is a 3D distance, and at
## exactly the gap it oscillates in place forever.

## Fallback if `shared/player.json` cannot be read; keeps the scene playable.
const DEFAULT_MOVE_SPEED: float = 5.0
## Squared direction length under which we skip rotating (avoids look_at jitter).
const FACING_EPSILON: float = 0.0001

var _move_speed: float = DEFAULT_MOVE_SPEED

@onready var _agent: NavigationAgent3D = $NavigationAgent3D


func _ready() -> void:
	var player_config: Dictionary = BalanceData.load_player().get("player", {})
	_move_speed = float(player_config.get("move_speed", DEFAULT_MOVE_SPEED))


## Orders the player to walk to [param world_point]. The agent clamps the target to
## the closest reachable point on the navigation mesh, so clicks on obstacles or
## outside the map resolve to the nearest sensible destination.
func move_to(world_point: Vector3) -> void:
	_agent.target_position = world_point


func _physics_process(_delta: float) -> void:
	# Before the (runtime-baked, ADR 0009) navigation mesh is ready, and after
	# arrival, the agent reports the path as finished — we just stand still.
	if _agent.is_navigation_finished():
		velocity = Vector3.ZERO
		move_and_slide()
		return

	var next_waypoint: Vector3 = _agent.get_next_path_position()
	var direction: Vector3 = next_waypoint - global_position
	direction.y = 0.0
	if direction.length_squared() > FACING_EPSILON:
		# look_at points -Z (Godot's forward) at the target; keep the body upright
		# by looking at a point on our own height.
		look_at(global_position + direction, Vector3.UP)
	velocity = direction.normalized() * _move_speed
	move_and_slide()
