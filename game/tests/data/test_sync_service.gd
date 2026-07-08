extends GdUnitTestSuite
## Tests for [SyncService]'s pure request-building and response-parsing
## helpers (M5, ADR 0013) - the part of the sync adapter that is honestly
## testable headless without a running server. The actual HTTP round trip is
## covered by the Go server's table-driven tests (server/internal/httpapi);
## CLAUDE.md/the M5 brief are explicit that gdUnit must not spin up the Go
## server, so these tests stub the payloads instead.


func test_build_register_body_shapes_device_id() -> void:
	var body: String = SyncService.build_register_body("device-123")
	var parsed: Dictionary = JSON.parse_string(body) as Dictionary

	assert_str(String(parsed.get("device_id", ""))).is_equal("device-123")


func test_build_upload_body_wraps_the_envelope_opaquely() -> void:
	var envelope: Dictionary = {
		"schema_version": 1,
		"saved_at_unix": 1700000000,
		"master_seed": 42,
		"player": {"health": 85},
	}
	var body: String = SyncService.build_upload_body(envelope)
	var parsed: Dictionary = JSON.parse_string(body) as Dictionary

	assert_int(int(parsed.get("schema_version", 0))).is_equal(1)
	assert_int(int(parsed.get("saved_at_unix", 0))).is_equal(1700000000)
	# The whole envelope rides along as an opaque nested payload, unmodified -
	# the server never parses it (docs/0013), so the client must send it
	# byte-for-byte identical to what SaveStore just wrote to disk.
	var payload: Dictionary = parsed.get("payload", {})
	assert_int(int(payload.get("master_seed", 0))).is_equal(42)
	assert_int(int((payload.get("player", {}) as Dictionary).get("health", 0))).is_equal(85)


func test_build_upload_body_defaults_missing_fields() -> void:
	var body: String = SyncService.build_upload_body({})
	var parsed: Dictionary = JSON.parse_string(body) as Dictionary

	assert_int(int(parsed.get("schema_version", -1))).is_equal(SaveData.CURRENT_SCHEMA_VERSION)
	assert_int(int(parsed.get("saved_at_unix", -1))).is_equal(0)


func test_parse_save_response_extracts_metadata_and_payload() -> void:
	var raw: Dictionary = {
		"schema_version": 1,
		"saved_at_unix": 1700000000,
		"payload": {"master_seed": 7},
	}
	var parsed: Dictionary = SyncService.parse_save_response(raw)

	assert_bool(parsed.is_empty()).is_false()
	assert_int(int(parsed.get("schema_version", 0))).is_equal(1)
	assert_int(int(parsed.get("saved_at_unix", 0))).is_equal(1700000000)
	assert_int(int((parsed.get("payload", {}) as Dictionary).get("master_seed", 0))).is_equal(7)


func test_parse_save_response_rejects_non_dictionary_input() -> void:
	assert_dict(SyncService.parse_save_response(null)).is_empty()
	assert_dict(SyncService.parse_save_response("not a dictionary")).is_empty()
	assert_dict(SyncService.parse_save_response([1, 2, 3])).is_empty()


func test_parse_save_response_rejects_missing_payload() -> void:
	var raw: Dictionary = {"schema_version": 1, "saved_at_unix": 123}
	assert_dict(SyncService.parse_save_response(raw)).is_empty()


func test_should_apply_remote_only_when_strictly_newer() -> void:
	assert_bool(SyncService.should_apply_remote(2000, 1000)).is_true()
	assert_bool(SyncService.should_apply_remote(1000, 1000)).is_false()
	assert_bool(SyncService.should_apply_remote(500, 1000)).is_false()
	# No local save at all is saved_at_unix == 0 - any real remote save wins.
	assert_bool(SyncService.should_apply_remote(1, 0)).is_true()
