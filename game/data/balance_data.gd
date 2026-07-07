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


## Returns the parsed `player.json` document, e.g. `{schema_version, player: {...}}`.
static func load_player() -> Dictionary:
	return _load_json_object(PLAYER_PATH)


## Returns the parsed `monsters.json` document, e.g. `{schema_version, monsters: [...]}`.
static func load_monsters() -> Dictionary:
	return _load_json_object(MONSTERS_PATH)


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
