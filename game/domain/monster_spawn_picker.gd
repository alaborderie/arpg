class_name MonsterSpawnPicker
extends RefCounted
## Pure spawn-selection math for the infinite monster spawner
## (`game/scenes/world/monster_spawner.gd`): which monster to spawn and where
## around the player, given an injected [RngService] (ADR 0004) so a run's spawn
## sequence is reproducible.
##
## Domain class (ADR 0003): no Nodes, no [NavigationServer3D]. The scene adapter
## snaps the raw ring offset [method ring_offset] returns onto the baked navmesh
## and turns the id [method pick_monster_id] returns into an actual instanced
## [Monster] — this class only ever hands back plain data.
##
## Draw order per spawn attempt — ring offset (angle, then radius), monster id,
## then the elite roll (G7, docs/0020) — is part of the same determinism contract
## [LootRoller] documents (ADR 0004): reordering these draws would change what a
## given RNG stream position produces next, a save/replay-breaking change if a
## future milestone starts persisting the spawn stream (today it deliberately
## isn't — see docs/0015). A forced monster id or a forced elite/non-elite test
## knob (`MonsterSpawner.forced_monster_id`/`forced_elite`) skips its draw
## entirely rather than discarding it, so pinning either one never perturbs the
## stream position the other spawns (or the ring offsets) depend on.


## Picks uniformly among [param monster_ids]. Empty input returns "".
static func pick_monster_id(monster_ids: Array[String], rng: RngService) -> String:
	if monster_ids.is_empty():
		return ""
	return monster_ids[rng.randi_range(0, monster_ids.size() - 1)]


## A random offset from the origin, uniform in angle and in radius within
## [param min_radius, param max_radius] — a ring around a point, not a filled
## disc, so spawns don't cluster near the centre the way a uniform-in-area draw
## would. Y is always 0; callers project onto the ground/navmesh.
static func ring_offset(min_radius: float, max_radius: float, rng: RngService) -> Vector3:
	var angle: float = rng.randf_range(0.0, TAU)
	var radius: float = rng.randf_range(min_radius, max_radius)
	return Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)


## True with probability [param chance] (G7, docs/0020: elites spawn 1-in-10 by
## default) — whether this spawn is an ELITE variant of whichever monster id was
## picked. One [method RngService.randf] draw, same "ride the existing stream"
## rule the id/position draws already follow; [param chance] is caller-supplied
## (from `shared/combat.json`'s `elite` block) so this stays pure data-in,
## data-out with no file access.
static func roll_is_elite(rng: RngService, chance: float) -> bool:
	return rng.randf() < chance
