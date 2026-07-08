extends GdUnitTestSuite
## Tests for [SyncStore] — the disk adapter for the device's sync credentials
## (M5, ADR 0013): a self-generated device id plus the bearer token the
## server hands back for it.


func after_test() -> void:
	# Keep headless runs hermetic - never leak a stray device id/token into a
	# later, unrelated test (same discipline as SaveStore in test_save_data.gd
	# / test_save_load.gd, see docs/0012).
	SyncStore.delete()


func test_get_or_create_device_id_persists_across_calls() -> void:
	SyncStore.delete()
	var first: String = SyncStore.get_or_create_device_id()
	assert_str(first).is_not_empty()

	var second: String = SyncStore.get_or_create_device_id()
	assert_str(second).is_equal(first)


func test_get_or_create_device_id_generates_different_ids_when_reset() -> void:
	SyncStore.delete()
	var first: String = SyncStore.get_or_create_device_id()
	SyncStore.delete()
	var second: String = SyncStore.get_or_create_device_id()

	assert_str(first).is_not_equal(second)


func test_load_credentials_is_empty_before_any_write() -> void:
	SyncStore.delete()
	assert_dict(SyncStore.load_credentials()).is_empty()


func test_save_token_round_trips() -> void:
	SyncStore.delete()
	var device_id: String = SyncStore.get_or_create_device_id()

	var wrote: bool = SyncStore.save_token(device_id, "test-token-123")
	assert_bool(wrote).is_true()

	var creds: Dictionary = SyncStore.load_credentials()
	assert_str(String(creds.get("device_id", ""))).is_equal(device_id)
	assert_str(String(creds.get("token", ""))).is_equal("test-token-123")


func test_save_token_does_not_change_the_device_id() -> void:
	SyncStore.delete()
	var device_id: String = SyncStore.get_or_create_device_id()
	SyncStore.save_token(device_id, "token-a")
	SyncStore.save_token(device_id, "token-b")

	assert_str(SyncStore.get_or_create_device_id()).is_equal(device_id)
	assert_str(String(SyncStore.load_credentials().get("token", ""))).is_equal("token-b")
