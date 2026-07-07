class_name SaveStore
extends RefCounted
## Disk adapter for save files (M4).
##
## An adapter (ADR 0003/0008 pattern): this class is the only place that touches
## `FileAccess`/`DirAccess` for saves. Shaping, versioning and migration are
## [SaveData]'s job (pure Dictionary in/out); this class only serializes that
## Dictionary to/from `user://`, following the same "loaders return an empty
## Dictionary and push_error on failure" convention as [BalanceData].
##
## Single save slot for now (M4 UX, see docs/0012): one JSON file, overwritten on
## every save. Multiple slots are a straightforward extension of the same shape
## if a later milestone wants them.

const SAVE_PATH: String = "user://saves/save.json"


## True if a save file exists at the default slot.
static func has_save() -> bool:
	return FileAccess.file_exists(SAVE_PATH)


## Writes [param envelope] (already shaped at SaveData.CURRENT_SCHEMA_VERSION) as
## JSON. Returns true on success.
static func save(envelope: Dictionary) -> bool:
	var dir: String = SAVE_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		push_error("SaveStore: cannot open %s for writing (%s)" % [SAVE_PATH, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(envelope, "\t"))
	return true


## Reads the save at the default slot and migrates it to the current schema via
## [SaveData]. Returns an empty Dictionary (after logging) when no save exists,
## the file is unreadable or not valid JSON, or SaveData rejects its contents
## (unknown/newer schema_version).
static func load() -> Dictionary:
	if not has_save():
		return {}
	var file: FileAccess = FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		push_error("SaveStore: cannot open %s (%s)" % [SAVE_PATH, FileAccess.get_open_error()])
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("SaveStore: %s is not a JSON object" % SAVE_PATH)
		return {}
	return SaveData.migrate(parsed as Dictionary)


## Deletes the save file, if any. Exposed for a future "reset save" action and
## used by tests to stay hermetic (see CLAUDE.md: clean up saves in teardown).
static func delete() -> void:
	if has_save():
		DirAccess.remove_absolute(SAVE_PATH)
