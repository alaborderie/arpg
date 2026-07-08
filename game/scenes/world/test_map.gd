extends NavigationRegion3D
## M1 test map: a flat ground plane with box obstacles.
##
## Godot notes: a [NavigationRegion3D] owns a [NavigationMesh] — the walkable-surface
## data the NavigationServer paths across. Baking scans this node's child **static
## colliders** (the navmesh's parsed-geometry mode; visual meshes live on the GPU and
## are expensive to read back at runtime), carves out everything an agent cannot
## squeeze through, and registers the result with the server. We bake **at runtime**
## on scene load rather than committing baked polygons into the .tscn (ADR 0009).
##
## G5 (issue #12) adds two purely-cosmetic passes, both run from [method _ready]
## *before* the bake so any collidable prop they scatter is already in the tree
## when [method NavigationRegion3D.bake_navigation_mesh] scans static colliders:
## tinted ground patches (so the 200x200 plane doesn't read flat) and scattered
## low-poly props (rocks/trees/ruins block movement the same
## StaticBody3D-plus-box-collider way the hand-placed walls/pillars already do;
## small pebbles are decorative only and carry no collider). Both passes place
## things with [method _hash01], a fixed sine-hash of an integer index rather
## than `randi()`/`randf()` — not because scene-layer code is bound by ADR
## 0004's domain-determinism rule, but because there's no reason a cosmetic
## layout should vary run to run when a pure function of an index does the job
## and keeps re-running the boot check reproducible.

## Half the ground plane's side length that scattering stays inside of, with a
## margin short of the true 100 m edge so nothing pokes past the visible plane.
const MAP_HALF_EXTENT: float = 95.0
## Never place scattered dressing this close to the origin — the player's
## spawn point (main.tscn places [Player] at the scene origin) must stay clear.
const SAFE_ZONE_RADIUS: float = 12.0

## Ground patches: large, thin, unshaded-adjacent tinted quads sitting a hair
## above the ground plane (same z-fight-avoidance idiom as HealthBar3D's
## FILL_LIFT) — cheap, textureless, Forward-Mobile-friendly color variation.
const GROUND_PATCH_COUNT: int = 16
const GROUND_PATCH_MIN_SIZE: float = 20.0
const GROUND_PATCH_MAX_SIZE: float = 40.0
const GROUND_PATCH_LIFT: float = 0.01
## A handful of natural ground variants around the base green/grey palette
## (test_map.tscn's StandardMaterial3D_ground): dry grass, moss, sand, dark rock.
const GROUND_PATCH_PALETTE: Array[Color] = [
	Color(0.34, 0.38, 0.24),
	Color(0.22, 0.3, 0.24),
	Color(0.42, 0.38, 0.28),
	Color(0.24, 0.24, 0.22),
]

## Props: a grid of candidate cells across the play area, each independently
## rolling into a collidable prop, a decorative pebble, or nothing — "scattered"
## rather than a uniform lattice, without needing engine randomness.
const PROP_GRID_CELLS: int = 10
const PROP_FILL_CHANCE: float = 0.32
const PEBBLE_FILL_CHANCE: float = 0.28

const ROCK_SCENE: PackedScene = preload("res://scenes/world/props/rock.tscn")
const TREE_SCENE: PackedScene = preload("res://scenes/world/props/tree.tscn")
const RUIN_SCENE: PackedScene = preload("res://scenes/world/props/ruin.tscn")
const PEBBLE_SCENE: PackedScene = preload("res://scenes/world/props/pebble.tscn")


func _ready() -> void:
	_scatter_ground_patches()
	_scatter_props()
	# Synchronous bake (`on_thread = false`): the map is tiny, and a threaded bake
	# lands in the NavigationServer's map at an unpredictable later frame — headless
	# test runs showed paths staying empty for 60+ frames. The force_update then
	# integrates the fresh mesh into the map immediately, so "scene ready" reliably
	# means "paths are queryable next frame" on every platform, every run. Both
	# scatter passes above must run first: baking scans whatever static colliders
	# already exist in the tree (ADR 0009), so a prop added after the bake would
	# never carve the navmesh.
	bake_navigation_mesh(false)
	NavigationServer3D.map_force_update(get_navigation_map())


## Scatters [constant GROUND_PATCH_COUNT] large tinted quads across the ground
## plane. Purely visual — no collider, no navmesh interaction — so this can run
## in any order relative to [method _scatter_props].
func _scatter_ground_patches() -> void:
	var patches_root: Node3D = Node3D.new()
	patches_root.name = "GroundPatches"
	add_child(patches_root)
	for i in range(GROUND_PATCH_COUNT):
		var x: float = (_hash01(i * 5 + 1) - 0.5) * 2.0 * MAP_HALF_EXTENT
		var z: float = (_hash01(i * 5 + 2) - 0.5) * 2.0 * MAP_HALF_EXTENT
		var size: float = lerpf(GROUND_PATCH_MIN_SIZE, GROUND_PATCH_MAX_SIZE, _hash01(i * 5 + 3))
		var palette_index: int = int(_hash01(i * 5 + 4) * GROUND_PATCH_PALETTE.size()) % GROUND_PATCH_PALETTE.size()

		var plane: PlaneMesh = PlaneMesh.new()
		plane.size = Vector2(size, size)
		var material: StandardMaterial3D = StandardMaterial3D.new()
		material.albedo_color = GROUND_PATCH_PALETTE[palette_index]
		material.roughness = 1.0
		var instance: MeshInstance3D = MeshInstance3D.new()
		instance.mesh = plane
		instance.material_override = material
		instance.position = Vector3(x, GROUND_PATCH_LIFT, z)
		patches_root.add_child(instance)


## Walks a [constant PROP_GRID_CELLS] x PROP_GRID_CELLS grid over the play
## area; each cell independently rolls (via [method _hash01]) into a
## collidable prop (rock/tree/ruin — a [StaticBody3D] plus a box collider, the
## same pattern the hand-placed walls/pillars/blocks already use, so the
## runtime navmesh bake picks them up automatically per ADR 0009), a
## decorative pebble (no collider), or nothing. A jittered-within-cell offset
## plus a safe zone around the origin keep the result looking scattered rather
## than gridded, without touching the player's spawn point.
func _scatter_props() -> void:
	var props_root: Node3D = Node3D.new()
	props_root.name = "Props"
	add_child(props_root)
	var cell_size: float = (MAP_HALF_EXTENT * 2.0) / float(PROP_GRID_CELLS)
	for row in range(PROP_GRID_CELLS):
		for col in range(PROP_GRID_CELLS):
			var index: int = row * PROP_GRID_CELLS + col
			var cell_x: float = -MAP_HALF_EXTENT + cell_size * (col + 0.5)
			var cell_z: float = -MAP_HALF_EXTENT + cell_size * (row + 0.5)
			var jitter_x: float = (_hash01(index * 3 + 1) - 0.5) * cell_size * 0.8
			var jitter_z: float = (_hash01(index * 3 + 2) - 0.5) * cell_size * 0.8
			var position: Vector3 = Vector3(cell_x + jitter_x, 0.0, cell_z + jitter_z)
			if Vector2(position.x, position.z).length() < SAFE_ZONE_RADIUS:
				continue

			var roll: float = _hash01(index * 3 + 3)
			var rotation_y: float = _hash01(index * 7 + 9) * TAU
			if roll < PROP_FILL_CHANCE:
				_place_prop(props_root, position, rotation_y, _hash01(index * 7 + 5))
			elif roll < PROP_FILL_CHANCE + PEBBLE_FILL_CHANCE:
				_place_pebble(props_root, position, rotation_y)


func _place_prop(root: Node3D, position: Vector3, rotation_y: float, kind_roll: float) -> void:
	var scene: PackedScene = ROCK_SCENE
	if kind_roll < 0.34:
		scene = ROCK_SCENE
	elif kind_roll < 0.67:
		scene = TREE_SCENE
	else:
		scene = RUIN_SCENE
	var instance: Node3D = scene.instantiate() as Node3D
	instance.position = position
	instance.rotation.y = rotation_y
	root.add_child(instance)


func _place_pebble(root: Node3D, position: Vector3, rotation_y: float) -> void:
	var instance: Node3D = PEBBLE_SCENE.instantiate() as Node3D
	instance.position = position
	instance.rotation.y = rotation_y
	root.add_child(instance)


## A fixed sine-hash of [param n] into [0, 1) — the same "index in, float out"
## trick shader code uses for pseudo-random-looking but fully deterministic
## noise. Not `randf()`: this needs to place the same prop in the same spot
## every run without spending an RNG stream on cosmetics ADR 0004 was never
## about (that ADR governs domain gameplay randomness, not scene dressing).
func _hash01(n: int) -> float:
	var v: float = sin(float(n) * 12.9898) * 43758.5453
	return v - floor(v)
