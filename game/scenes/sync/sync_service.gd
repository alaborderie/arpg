class_name SyncService
extends Node
## Cloud-save sync adapter (M5, ADR 0013): registers this device with the
## server, then checks for a newer save at boot and applies it, and uploads
## after every local save. An adapter, not domain (ADR 0003) — it shapes and
## sends/receives HTTP but the actual last-write-wins decision only compares
## timestamps main.gd/SaveData already produce.
##
## Offline-first is the whole point: every network step is wrapped so a
## failure (refused connection, timeout, bad response) is logged with `print`
## (never push_error/push_warning — those would fail the boot-check's
## "clean, no errors or warnings" bar for what is, offline, a completely
## normal outcome) and the game continues exactly as if sync were disabled.
## Nothing here ever blocks a frame: every network call is awaited inside a
## coroutine, never from `_process`/input.
##
## Silent last-write-wins: if the server has a newer save, it is applied
## immediately and without any confirmation UI (see docs/0013 for why that is
## an acceptable stub for a single-device, single-player game).

signal remote_save_applied(envelope: Dictionary)

var _token: String = ""
var _boot_http: HTTPRequest
var _upload_http: HTTPRequest


func _ready() -> void:
	_boot_http = _make_request_node()
	_upload_http = _make_request_node()
	if not SyncConfig.enabled:
		return
	await _bootstrap()


## Uploads [param envelope] (the same Dictionary just written by SaveStore.save)
## if this device is registered. Fire-and-forget from the caller's point of
## view: main.gd calls this right after a local save without awaiting it, so
## saving never waits on the network.
func upload_after_save(envelope: Dictionary) -> void:
	if not SyncConfig.enabled or _token.is_empty():
		return
	var headers: PackedStringArray = _auth_headers(_token)
	var body: String = build_upload_body(envelope)
	var resp: Dictionary = await _send(_upload_http, "/v1/save", HTTPClient.METHOD_PUT, headers, body)
	if not resp.get("ok", false):
		return
	match int(resp.get("status", 0)):
		200:
			print("SyncService: uploaded save (saved_at_unix=%s)" % envelope.get("saved_at_unix", 0))
		409:
			print("SyncService: upload rejected, server already has a newer save")
		_:
			print("SyncService: upload failed with status %d" % int(resp.get("status", 0)))


## Registers the device (if not already) and applies a newer server save (if
## any) to both disk and the live session via `remote_save_applied`.
func _bootstrap() -> void:
	var device_id: String = SyncStore.get_or_create_device_id()
	var creds: Dictionary = SyncStore.load_credentials()
	var token: String = String(creds.get("token", ""))
	if token.is_empty():
		token = await _register_device(device_id)
	if token.is_empty():
		print("SyncService: server unreachable or registration failed; staying offline, will retry next boot")
		return
	_token = token
	await _check_for_newer_save()


func _register_device(device_id: String) -> String:
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var body: String = build_register_body(device_id)
	var resp: Dictionary = await _send(_boot_http, "/v1/auth/device", HTTPClient.METHOD_POST, headers, body)
	if not resp.get("ok", false) or int(resp.get("status", 0)) != 200:
		return ""
	var payload: Variant = resp.get("body")
	if payload is not Dictionary:
		return ""
	var token: String = String((payload as Dictionary).get("token", ""))
	if token.is_empty():
		return ""
	SyncStore.save_token(device_id, token)
	return token


func _check_for_newer_save() -> void:
	var headers: PackedStringArray = _auth_headers(_token)
	var resp: Dictionary = await _send(_boot_http, "/v1/save", HTTPClient.METHOD_GET, headers, "")
	if not resp.get("ok", false):
		return
	var status: int = int(resp.get("status", 0))
	if status == 404:
		print("SyncService: no save stored on the server yet")
		return
	if status != 200:
		print("SyncService: checking for a newer save failed with status %d" % status)
		return

	var remote: Dictionary = parse_save_response(resp.get("body"))
	if remote.is_empty():
		return
	var migrated: Dictionary = SaveData.migrate((remote.get("payload", {}) as Dictionary).duplicate(true))
	if migrated.is_empty():
		return

	var local: Dictionary = SaveStore.load()
	var local_saved_at: int = int(local.get("saved_at_unix", 0))
	var remote_saved_at: int = int(migrated.get("saved_at_unix", 0))
	if not should_apply_remote(remote_saved_at, local_saved_at):
		return

	SaveStore.save(migrated)
	print("SyncService: applied newer remote save (saved_at_unix=%d)" % remote_saved_at)
	remote_save_applied.emit(migrated)


## Sends one HTTP request and awaits its completion, translating every
## failure mode (couldn't start, connection refused, timeout, non-2xx status)
## into a plain `{"ok": bool, "status": int, "body": Variant}` Dictionary -
## callers branch on that, never on HTTPRequest's result codes directly.
func _send(
	http: HTTPRequest, path: String, method: HTTPClient.Method, headers: PackedStringArray, body: String
) -> Dictionary:
	var url: String = SyncConfig.base_url + path
	var err: Error = http.request(url, headers, method, body)
	if err != OK:
		print("SyncService: could not start request to %s (error %d)" % [path, err])
		return {"ok": false}

	var result: Array = await http.request_completed
	var http_result: int = result[0]
	var response_code: int = result[1]
	var response_body: PackedByteArray = result[3]

	if http_result != HTTPRequest.RESULT_SUCCESS:
		print("SyncService: %s unreachable (result=%d) - continuing offline" % [path, http_result])
		return {"ok": false}

	var parsed: Variant = null
	if response_body.size() > 0:
		parsed = JSON.parse_string(response_body.get_string_from_utf8())
	return {"ok": true, "status": response_code, "body": parsed}


func _auth_headers(token: String) -> PackedStringArray:
	return PackedStringArray(["Authorization: Bearer %s" % token])


func _make_request_node() -> HTTPRequest:
	var http: HTTPRequest = HTTPRequest.new()
	http.timeout = SyncConfig.REQUEST_TIMEOUT_SEC
	add_child(http)
	return http


## Pure request-building/response-parsing helpers below: no Node, no network,
## no file access - the part of this adapter that is honestly unit-testable
## headless without a running server (see game/tests/data/test_sync_service.gd).

## Body of `POST /v1/auth/device`.
static func build_register_body(device_id: String) -> String:
	return JSON.stringify({"device_id": device_id})


## Body of `PUT /v1/save`. `envelope` is the exact Dictionary [SaveStore] just
## wrote to disk; the server stores `payload` opaquely (docs/0013).
static func build_upload_body(envelope: Dictionary) -> String:
	return JSON.stringify(
		{
			"schema_version": envelope.get("schema_version", SaveData.CURRENT_SCHEMA_VERSION),
			"saved_at_unix": envelope.get("saved_at_unix", 0),
			"payload": envelope,
		}
	)


## Shapes a parsed `GET /v1/save` 200 response body into
## `{"schema_version": int, "saved_at_unix": int, "payload": Dictionary}`, or
## an empty Dictionary if `raw` isn't a usable response (wrong shape, missing
## payload). Pure - callers still run `payload` through `SaveData.migrate()`
## before trusting it, exactly as SaveStore.load() does for a local save.
static func parse_save_response(raw: Variant) -> Dictionary:
	if raw is not Dictionary:
		return {}
	var data: Dictionary = raw as Dictionary
	if data.get("payload") is not Dictionary:
		return {}
	return {
		"schema_version": int(data.get("schema_version", 0)),
		"saved_at_unix": int(data.get("saved_at_unix", 0)),
		"payload": data.get("payload"),
	}


## Last-write-wins comparison used both at boot and (implicitly, server-side)
## on upload: a remote save only wins if it is strictly newer.
static func should_apply_remote(remote_saved_at_unix: int, local_saved_at_unix: int) -> bool:
	return remote_saved_at_unix > local_saved_at_unix
