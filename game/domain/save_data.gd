class_name SaveData
extends RefCounted
## Versioned save envelope + migration pipeline (M4).
##
## Domain class (ADR 0003): pure Dictionary in/out, no Node, no file access — the
## disk adapter ([SaveStore] in `game/data/`) reads/writes bytes and hands this
## class the parsed Dictionary; this class never touches `FileAccess`.
##
## Envelope shape at CURRENT_SCHEMA_VERSION:
##   { "schema_version": int,
##     "saved_at_unix": int,        # wall-clock seconds; M5's last-write-wins key
##     "master_seed": int,          # main.gd's rng_seed (ADR 0004/0011)
##     "combat_rng_state": String,  # RngService.get_state(), the combat stream
##     "loot_rng_state": String,    # RngService.get_state(), the loot stream
##     "player": {
##       "health": int,
##       "position": {"x": float, "y": float, "z": float},
##       "bag": Array[Dictionary],       # Inventory.bag(), pickup order
##       "equipped": Dictionary,         # slot name -> item Dictionary
##     },
##     "progress": {
##       "monsters_killed": int,
##     } }
##
## Migration pipeline: `migrate()` walks a save's schema_version forward to
## CURRENT_SCHEMA_VERSION one step at a time via `_migrate_v<N>_to_v<N+1>`
## functions, so a save two versions behind still loads. A save whose
## schema_version is NEWER than CURRENT_SCHEMA_VERSION is rejected outright
## (returns an empty Dictionary) — this build must never guess at a shape it
## doesn't recognize. `_migrate_v0_to_v1` is a scaffold: M4 shipped with
## schema_version 1 from day one, so there is no real "v0" save in the wild, but
## the step demonstrates the mechanism every future migration must follow (fill
## in defaults for fields the older shape lacked, never fail on missing data) and
## is what the migration tests exercise.
##
## RNG state as a String, not a number: [RandomNumberGenerator]'s `state` is a
## full 64-bit value, and Godot's JSON only has a double-precision number type
## (53 bits of exact integer mantissa) — round-tripping a large state through a
## bare JSON number silently truncates it, desyncing the restored stream from
## the one that was actually saved. Formatting it as a decimal string sidesteps
## JSON's number type entirely; `int(String)` parses it back exactly.

const CURRENT_SCHEMA_VERSION: int = 1


## Builds a fresh envelope at CURRENT_SCHEMA_VERSION from raw scene state. Callers
## (main.gd) own gathering the pieces — this function only shapes them.
static func build(
	master_seed: int,
	combat_rng_state: int,
	loot_rng_state: int,
	player_health: int,
	player_position: Vector3,
	bag: Array[Dictionary],
	equipped: Dictionary,
	monsters_killed: int,
	saved_at_unix: int
) -> Dictionary:
	return {
		"schema_version": CURRENT_SCHEMA_VERSION,
		"saved_at_unix": saved_at_unix,
		"master_seed": master_seed,
		"combat_rng_state": "%d" % combat_rng_state,
		"loot_rng_state": "%d" % loot_rng_state,
		"player": {
			"health": player_health,
			"position": _vector3_to_dict(player_position),
			"bag": bag.duplicate(true),
			"equipped": equipped.duplicate(true),
		},
		"progress": {
			"monsters_killed": monsters_killed,
		},
	}


## Migrates [param raw] forward to CURRENT_SCHEMA_VERSION. Returns an empty
## Dictionary (after logging with push_error) when [param raw] is empty, has no
## numeric `schema_version`, is from a schema_version NEWER than this build
## understands, or falls off the end of the known migration chain.
static func migrate(raw: Dictionary) -> Dictionary:
	if raw.is_empty():
		return {}
	var version_value: Variant = raw.get("schema_version")
	if version_value is not int and version_value is not float:
		push_error("SaveData: missing or non-numeric schema_version")
		return {}
	var version: int = int(version_value)
	if version > CURRENT_SCHEMA_VERSION:
		push_error(
			"SaveData: save schema_version %d is newer than this build supports (%d)"
				% [version, CURRENT_SCHEMA_VERSION]
		)
		return {}
	var data: Dictionary = raw.duplicate(true)
	while version < CURRENT_SCHEMA_VERSION:
		match version:
			0:
				data = _migrate_v0_to_v1(data)
				version = 1
			_:
				push_error("SaveData: no migration path from schema_version %d" % version)
				return {}
	return data


## The player's saved position as a [Vector3]. [param data] is a migrated envelope.
static func position_from_player(data: Dictionary) -> Vector3:
	var player: Dictionary = data.get("player", {})
	return _dict_to_vector3(player.get("position", {}))


## The player's saved bag, converted back to a typed array of item Dictionaries.
## [param data] is a migrated envelope.
static func bag_from_player(data: Dictionary) -> Array[Dictionary]:
	var player: Dictionary = data.get("player", {})
	var bag: Array[Dictionary] = []
	for entry: Variant in player.get("bag", []):
		if entry is Dictionary:
			bag.append(entry as Dictionary)
	return bag


## The player's saved equipped-slot Dictionary (slot name -> item). [param data]
## is a migrated envelope.
static func equipped_from_player(data: Dictionary) -> Dictionary:
	var player: Dictionary = data.get("player", {})
	return (player.get("equipped", {}) as Dictionary).duplicate(true)


static func _vector3_to_dict(position: Vector3) -> Dictionary:
	return {"x": position.x, "y": position.y, "z": position.z}


static func _dict_to_vector3(data: Dictionary) -> Vector3:
	return Vector3(float(data.get("x", 0.0)), float(data.get("y", 0.0)), float(data.get("z", 0.0)))


## Scaffolded migration (see class doc): a hypothetical v0 predates the
## loot/combat RNG stream split (ADR 0011) and the `progress` block, so it may be
## missing `loot_rng_state`, `progress`, `player.bag`, or `player.equipped`. Every
## missing field gets a safe default; nothing here ever raises on absence. Once a
## save shape ships for real, evolving it means adding a new
## `_migrate_vN_to_vN+1` step, never editing an old one (same discipline as the
## fixed-draw-order rule in loot_roller.gd, ADR 0011).
static func _migrate_v0_to_v1(data: Dictionary) -> Dictionary:
	var migrated: Dictionary = data.duplicate(true)
	migrated["schema_version"] = 1
	if not migrated.has("loot_rng_state"):
		# Copy verbatim (whatever shape the old field was in, string or number) —
		# this scaffold isn't the place to also retrofit the String-state fix.
		migrated["loot_rng_state"] = migrated.get("combat_rng_state", "0")
	if not migrated.has("progress"):
		migrated["progress"] = {"monsters_killed": 0}
	var player: Dictionary = (migrated.get("player", {}) as Dictionary).duplicate(true)
	if not player.has("bag"):
		player["bag"] = []
	if not player.has("equipped"):
		player["equipped"] = {}
	migrated["player"] = player
	return migrated
