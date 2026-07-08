extends GdUnitTestSuite
## Unit tests for [SkillSlots] (G9, issue #16, docs/0022) — the pure slot-unlock
## rule Player and main.gd both consult rather than hard-coding level numbers.


func test_slot_count_is_three() -> void:
	assert_int(SkillSlots.SLOT_COUNT).is_equal(3)


func test_slot_0_is_always_unlocked() -> void:
	assert_bool(SkillSlots.is_unlocked(0, 1)).is_true()
	assert_bool(SkillSlots.is_unlocked(0, 20)).is_true()


func test_slot_1_unlocks_at_level_10() -> void:
	assert_bool(SkillSlots.is_unlocked(1, 9)).is_false()
	assert_bool(SkillSlots.is_unlocked(1, 10)).is_true()
	assert_bool(SkillSlots.is_unlocked(1, 11)).is_true()


func test_slot_2_unlocks_at_level_20() -> void:
	assert_bool(SkillSlots.is_unlocked(2, 19)).is_false()
	assert_bool(SkillSlots.is_unlocked(2, 20)).is_true()


func test_unlock_level_reports_the_level_each_slot_needs() -> void:
	assert_int(SkillSlots.unlock_level(0)).is_equal(1)
	assert_int(SkillSlots.unlock_level(1)).is_equal(10)
	assert_int(SkillSlots.unlock_level(2)).is_equal(20)
