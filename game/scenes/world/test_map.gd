extends NavigationRegion3D
## M1 test map: a flat ground plane with box obstacles.
##
## Godot notes: a [NavigationRegion3D] owns a [NavigationMesh] — the walkable-surface
## data the NavigationServer paths across. Baking scans this node's child **static
## colliders** (the navmesh's parsed-geometry mode; visual meshes live on the GPU and
## are expensive to read back at runtime), carves out everything an agent cannot
## squeeze through, and registers the result with the server. We bake **at runtime**
## on scene load rather than committing baked polygons into the .tscn (ADR 0009).


func _ready() -> void:
	# Synchronous bake (`on_thread = false`): the map is tiny, and a threaded bake
	# lands in the NavigationServer's map at an unpredictable later frame — headless
	# test runs showed paths staying empty for 60+ frames. The force_update then
	# integrates the fresh mesh into the map immediately, so "scene ready" reliably
	# means "paths are queryable next frame" on every platform, every run.
	bake_navigation_mesh(false)
	NavigationServer3D.map_force_update(get_navigation_map())
