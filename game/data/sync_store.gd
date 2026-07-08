class_name SyncStore
extends RefCounted
## Disk adapter for the device's sync credentials (M5): a self-generated device
## id, persisted once and reused forever, plus the bearer token the server
## hands back for it (empty until registration succeeds at least once).
##
## Same shape as [SaveStore] (ADR 0008/0012 pattern): the only place that
## touches `FileAccess`/`DirAccess` for this data, returning an empty
## Dictionary and logging with push_error on failure instead of raising.
##
## The device id is not domain randomness (ADR 0004's RngService rule is about
## reproducible gameplay outcomes); it is a one-time, adapter-level identifier
## with no gameplay effect, so it is generated straight from Godot's [Crypto]
## CSPRNG rather than routed through an RngService stream.

const CREDENTIALS_PATH: String = "user://sync/credentials.json"
## Random bytes of entropy in a generated device id (before hex encoding).
const DEVICE_ID_BYTES: int = 16


## Returns the persisted device id, generating and saving a new one on first
## call. Stable across restarts and across reinstalls that keep `user://`.
static func get_or_create_device_id() -> String:
	var creds: Dictionary = load_credentials()
	var existing: String = String(creds.get("device_id", ""))
	if not existing.is_empty():
		return existing
	var generated: String = _generate_device_id()
	_write({"device_id": generated, "token": ""})
	return generated


## Returns `{"device_id": String, "token": String}`, or both fields empty if
## no credentials file exists yet or it is unreadable/malformed.
static func load_credentials() -> Dictionary:
	if not FileAccess.file_exists(CREDENTIALS_PATH):
		return {}
	var file: FileAccess = FileAccess.open(CREDENTIALS_PATH, FileAccess.READ)
	if file == null:
		push_error("SyncStore: cannot open %s (%s)" % [CREDENTIALS_PATH, FileAccess.get_open_error()])
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if parsed is not Dictionary:
		push_error("SyncStore: %s is not a JSON object" % CREDENTIALS_PATH)
		return {}
	return parsed as Dictionary


## Persists the bearer token the server returned for `device_id`. Returns true
## on success.
static func save_token(device_id: String, token: String) -> bool:
	return _write({"device_id": device_id, "token": token})


## Deletes the credentials file, if any. Exposed for tests to stay hermetic,
## same convention as [SaveStore.delete].
static func delete() -> void:
	if FileAccess.file_exists(CREDENTIALS_PATH):
		DirAccess.remove_absolute(CREDENTIALS_PATH)


static func _write(data: Dictionary) -> bool:
	var dir: String = CREDENTIALS_PATH.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file: FileAccess = FileAccess.open(CREDENTIALS_PATH, FileAccess.WRITE)
	if file == null:
		push_error("SyncStore: cannot open %s for writing (%s)" % [CREDENTIALS_PATH, FileAccess.get_open_error()])
		return false
	file.store_string(JSON.stringify(data))
	return true


static func _generate_device_id() -> String:
	var crypto: Crypto = Crypto.new()
	var bytes: PackedByteArray = crypto.generate_random_bytes(DEVICE_ID_BYTES)
	return bytes.hex_encode()
