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
##     "supports_offer_rng_state": String, # G8: the support-offer stream (docs/0021)
##     "player": {
##       "health": int,
##       "position": {"x": float, "y": float, "z": float},
##       "bag": Array[Dictionary],       # Inventory.bag(), pickup order
##       "equipped": Dictionary,         # slot name -> item Dictionary
##       "skill_id": String,             # G2: the chosen skill (shared/skills.json id)
##       "level": int,                   # G3: current level (docs/0017)
##       "xp": int,                      # G3: total accumulated XP
##       "supports": Array[String],      # G8: owned support ids, duplicates allowed (docs/0021)
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
## is what the migration tests exercise. `_migrate_v1_to_v2` is G2's real, first
## non-scaffold step: a pre-G2 save has no `player.skill_id` (skills didn't
## exist), so it defaults to `"quick_strike"` — a plain, no-frills melee skill
## that best matches what "the basic attack" used to mean (docs/0016).
## `_migrate_v2_to_v3` is G3's step: a pre-G3 save has no `player.level`/
## `player.xp` (levels didn't exist), so it defaults to level 1, XP 0 — a
## returning save keeps its `progress.monsters_killed` untouched and simply
## starts the XP/level curve from scratch (docs/0017). `_migrate_v3_to_v4` is
## G8's step: a pre-G8 save has no `player.supports` (supports didn't exist),
## so it defaults to an empty array — a returning save simply owns no supports
## yet. `supports_offer_rng_state` is deliberately left unset by this step
## rather than defaulted to a placeholder: main.gd's load path already treats
## a missing RNG-state key as "keep the freshly constructed stream's own
## state" (the same `.get(key, _rng.get_state())` idiom `combat_rng_state`/
## `loot_rng_state` restoration already uses), which is exactly correct here —
## a pre-G8 save never drew from this stream, so there is no real state to
## restore (docs/0021).
##
## RNG state as a String, not a number: [RandomNumberGenerator]'s `state` is a
## full 64-bit value, and Godot's JSON only has a double-precision number type
## (53 bits of exact integer mantissa) — round-tripping a large state through a
## bare JSON number silently truncates it, desyncing the restored stream from
## the one that was actually saved. Formatting it as a decimal string sidesteps
## JSON's number type entirely; `int(String)` parses it back exactly.

const CURRENT_SCHEMA_VERSION: int = 4
## The skill a pre-G2 save (or any save missing `skill_id`) migrates to. See
## docs/0016 for why this particular skill.
const DEFAULT_SKILL_ID: String = "quick_strike"
## Level/XP a pre-G3 save (or any save missing `level`/`xp`) migrates to: a
## returning player simply starts the new curve from the bottom (docs/0017).
const DEFAULT_LEVEL: int = 1
const DEFAULT_XP: int = 0
## Supports a pre-G8 save (or any save missing `player.supports`) migrates to:
## no supports owned — see docs/0021.
const DEFAULT_SUPPORTS: Array[String] = []


## Builds a fresh envelope at CURRENT_SCHEMA_VERSION from raw scene state. Callers
## (main.gd) own gathering the pieces — this function only shapes them.
static func build(
	master_seed: int,
	combat_rng_state: int,
	loot_rng_state: int,
	supports_offer_rng_state: int,
	player_health: int,
	player_position: Vector3,
	bag: Array[Dictionary],
	equipped: Dictionary,
	skill_id: String,
	level: int,
	xp: int,
	supports: Array[String],
	monsters_killed: int,
	saved_at_unix: int
) -> Dictionary:
	return {
		"schema_version": CURRENT_SCHEMA_VERSION,
		"saved_at_unix": saved_at_unix,
		"master_seed": master_seed,
		"combat_rng_state": "%d" % combat_rng_state,
		"loot_rng_state": "%d" % loot_rng_state,
		"supports_offer_rng_state": "%d" % supports_offer_rng_state,
		"player": {
			"health": player_health,
			"position": _vector3_to_dict(player_position),
			"bag": bag.duplicate(true),
			"equipped": equipped.duplicate(true),
			"skill_id": skill_id,
			"level": level,
			"xp": xp,
			"supports": supports.duplicate(),
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
			1:
				data = _migrate_v1_to_v2(data)
				version = 2
			2:
				data = _migrate_v2_to_v3(data)
				version = 3
			3:
				data = _migrate_v3_to_v4(data)
				version = 4
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


## The player's saved skill id (G2, `shared/skills.json`). [param data] is a
## migrated envelope — always present at CURRENT_SCHEMA_VERSION thanks to
## `_migrate_v1_to_v2`, but this still falls back to DEFAULT_SKILL_ID so a
## caller handed a raw/unmigrated Dictionary never reads an empty skill id.
static func skill_id_from_player(data: Dictionary) -> String:
	var player: Dictionary = data.get("player", {})
	var skill_id: String = String(player.get("skill_id", ""))
	return skill_id if not skill_id.is_empty() else DEFAULT_SKILL_ID


## The player's saved level (G3). [param data] is a migrated envelope — always
## present at CURRENT_SCHEMA_VERSION thanks to `_migrate_v2_to_v3`, but this
## still falls back to DEFAULT_LEVEL so a caller handed a raw/unmigrated
## Dictionary never reads a level below 1.
static func level_from_player(data: Dictionary) -> int:
	var player: Dictionary = data.get("player", {})
	return maxi(DEFAULT_LEVEL, int(player.get("level", DEFAULT_LEVEL)))


## The player's saved total XP (G3). [param data] is a migrated envelope; see
## [method level_from_player] for the same raw-Dictionary safety note.
static func xp_from_player(data: Dictionary) -> int:
	var player: Dictionary = data.get("player", {})
	return maxi(DEFAULT_XP, int(player.get("xp", DEFAULT_XP)))


## The player's saved owned-support ids (G8), duplicates preserved (stacking —
## see docs/0021). [param data] is a migrated envelope — always present at
## CURRENT_SCHEMA_VERSION thanks to `_migrate_v3_to_v4`, but this still falls
## back to an empty array so a caller handed a raw/unmigrated Dictionary never
## reads a malformed list.
static func supports_from_player(data: Dictionary) -> Array[String]:
	var player: Dictionary = data.get("player", {})
	var supports: Array[String] = []
	for entry: Variant in player.get("supports", []):
		supports.append(String(entry))
	return supports


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


## G2 (docs/0016): a pre-G2 save has no `player.skill_id` — skills didn't exist
## yet, every player used the same hard-coded basic attack. Defaulting to
## DEFAULT_SKILL_ID ("quick_strike", tuned to match that old basic attack
## exactly — see shared/skills.json) means a returning save loads into
## something numerically indistinguishable from what the player already had.
static func _migrate_v1_to_v2(data: Dictionary) -> Dictionary:
	var migrated: Dictionary = data.duplicate(true)
	migrated["schema_version"] = 2
	var player: Dictionary = (migrated.get("player", {}) as Dictionary).duplicate(true)
	if not player.has("skill_id") or String(player.get("skill_id", "")).is_empty():
		player["skill_id"] = DEFAULT_SKILL_ID
	migrated["player"] = player
	return migrated


## G3 (docs/0017): a pre-G3 save has no `player.level`/`player.xp` — levels
## didn't exist yet. Defaulting to level 1 / 0 XP means a returning player
## starts the curve from the bottom; `progress.monsters_killed` is untouched by
## this step (it already survived any earlier migration).
static func _migrate_v2_to_v3(data: Dictionary) -> Dictionary:
	var migrated: Dictionary = data.duplicate(true)
	migrated["schema_version"] = 3
	var player: Dictionary = (migrated.get("player", {}) as Dictionary).duplicate(true)
	if not player.has("level"):
		player["level"] = DEFAULT_LEVEL
	if not player.has("xp"):
		player["xp"] = DEFAULT_XP
	migrated["player"] = player
	return migrated


## G8 (docs/0021): a pre-G8 save has no `player.supports` — supports didn't
## exist yet. Defaulting to an empty array means a returning player simply
## owns no supports; `supports_offer_rng_state` is deliberately left absent
## (see the class doc) rather than defaulted here.
static func _migrate_v3_to_v4(data: Dictionary) -> Dictionary:
	var migrated: Dictionary = data.duplicate(true)
	migrated["schema_version"] = 4
	var player: Dictionary = (migrated.get("player", {}) as Dictionary).duplicate(true)
	if not player.has("supports"):
		player["supports"] = DEFAULT_SUPPORTS.duplicate()
	migrated["player"] = player
	return migrated
