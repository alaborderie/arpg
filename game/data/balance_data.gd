class_name BalanceData
extends RefCounted
## Static loader for the shared balance data in `res://shared/*.json`.
##
## `res://shared` is a symlink to the repo-root `shared/` directory (ADR 0008), so the
## client and the Go server read the same files. This class is an *adapter*: it may
## touch the filesystem, unlike `res://domain/` classes (ADR 0003). Domain code never
## loads files — scenes fetch data here and pass plain values in.
##
## Loaders return an empty Dictionary on failure (missing file, malformed JSON) after
## logging with push_error; callers keep sane defaults so the game still boots.

const PLAYER_PATH: String = "res://shared/player.json"
const MONSTERS_PATH: String = "res://shared/monsters.json"
const COMBAT_PATH: String = "res://shared/combat.json"
const ITEMS_PATH: String = "res://shared/items.json"
const LOOT_TABLES_PATH: String = "res://shared/loot_tables.json"
const SKILLS_PATH: String = "res://shared/skills.json"
const PROGRESSION_PATH: String = "res://shared/progression.json"


## Returns the parsed `player.json` document, e.g. `{schema_version, player: {...}}`.
static func load_player() -> Dictionary:
	return _load_json_object(PLAYER_PATH)


## Returns the parsed `monsters.json` document, e.g. `{schema_version, monsters: [...]}`.
static func load_monsters() -> Dictionary:
	return _load_json_object(MONSTERS_PATH)


## Returns the parsed `combat.json` document, e.g. `{schema_version, combat: {...}}`.
static func load_combat() -> Dictionary:
	return _load_json_object(COMBAT_PATH)


## Returns the parsed `items.json` document, e.g. `{schema_version, bases: [...], affixes: [...]}`.
static func load_items() -> Dictionary:
	return _load_json_object(ITEMS_PATH)


## Returns the parsed `loot_tables.json` document, e.g. `{schema_version, rarities: [...], tables: [...]}`.
static func load_loot_tables() -> Dictionary:
	return _load_json_object(LOOT_TABLES_PATH)


## Returns the parsed `skills.json` document, e.g. `{schema_version, skills: [...]}`.
static func load_skills() -> Dictionary:
	return _load_json_object(SKILLS_PATH)


## Returns the parsed `progression.json` document, e.g.
## `{schema_version, progression: {...}}` (G3, [ProgressionCurve], docs/0017).
static func load_progression() -> Dictionary:
	return _load_json_object(PROGRESSION_PATH)


## Returns the `monsters.json` entry whose `id` is [param monster_id], or an empty
## Dictionary (after logging) if no such monster exists.
static func monster(monster_id: String) -> Dictionary:
	var monsters: Array = load_monsters().get("monsters", [])
	for entry: Variant in monsters:
		if entry is Dictionary and String((entry as Dictionary).get("id", "")) == monster_id:
			return entry as Dictionary
	push_error("BalanceData: no monster with id '%s' in %s" % [monster_id, MONSTERS_PATH])
	return {}


static func _load_json_object(path: String) -> Dictionary:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("BalanceData: cannot open %s (%s)" % [path, FileAccess.get_open_error()])
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("BalanceData: %s is not a JSON object" % path)
		return {}
	return parsed
