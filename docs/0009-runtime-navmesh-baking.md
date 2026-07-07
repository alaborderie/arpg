# 9. Bake navigation meshes at runtime, not in the editor

- Status: accepted
- Date: 2026-07-07

## Context

M1 movement paths across a `NavigationMesh` (Godot's walkable-surface data, owned by
a `NavigationRegion3D`). The usual Godot workflow bakes it in the editor and commits
the polygon soup inside the `.tscn`. But this project's maps are ultimately
**procedurally assembled** (core loop), so editor-baked meshes only ever cover
hand-made test maps; and committed bake blobs are unreviewable multi-kilobyte diffs
that silently go stale whenever someone nudges an obstacle.

## Decision

Maps call `bake_navigation_mesh()` in `_ready()` (threaded). The `.tscn` carries only
the bake *parameters* (`agent_radius`, cell sizes), never baked polygons. The navmesh
parses **static colliders** (`parsed_geometry_type = STATIC_COLLIDERS`), not visual
meshes: Godot warns that reading visual meshes back from the GPU at runtime stalls
rendering, and combat (M2) needs the colliders anyway. So "StaticBody3D + box shape"
is the entire workflow for blocking movement.

## Consequences

- Scene diffs stay small and reviewable; obstacles can never desync from the navmesh.
- This is the same code path procedural maps will need, so M-procgen changes nothing
  structurally.
- The mesh is unavailable for a few frames after load. `NavigationAgent3D` treats a
  missing map as "navigation finished", so early move orders are dropped harmlessly —
  acceptable for now; loading flow can gate on the bake-finished signal later.
- Runtime baking costs a moment of CPU on scene load (irrelevant at test-map scale;
  measure again when maps grow).
