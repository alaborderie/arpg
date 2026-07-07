extends GdUnitTestSuite
## Unit tests for [Health] — pure hit-point state, no scene tree needed.


func test_starts_at_full_health() -> void:
	var health := Health.new(24)
	assert_int(health.max_health).is_equal(24)
	assert_int(health.current).is_equal(24)
	assert_bool(health.is_alive()).is_true()
	assert_bool(health.is_dead()).is_false()


func test_maximum_is_clamped_to_at_least_one() -> void:
	var health := Health.new(0)
	assert_int(health.max_health).is_equal(1)
	assert_int(health.current).is_equal(1)


func test_take_damage_reduces_current_and_returns_applied() -> void:
	var health := Health.new(24)
	var applied: int = health.take_damage(10)
	assert_int(applied).is_equal(10)
	assert_int(health.current).is_equal(14)
	assert_bool(health.is_alive()).is_true()


func test_lethal_damage_kills_exactly_at_zero() -> void:
	var health := Health.new(24)
	var applied: int = health.take_damage(24)
	assert_int(applied).is_equal(24)
	assert_int(health.current).is_equal(0)
	assert_bool(health.is_dead()).is_true()


func test_overkill_is_truncated_to_remaining_health() -> void:
	var health := Health.new(10)
	var applied: int = health.take_damage(999)
	assert_int(applied).is_equal(10)
	assert_int(health.current).is_equal(0)
	assert_bool(health.is_dead()).is_true()


func test_damage_to_a_corpse_applies_nothing() -> void:
	var health := Health.new(10)
	health.take_damage(10)
	var applied: int = health.take_damage(5)
	assert_int(applied).is_equal(0)
	assert_int(health.current).is_equal(0)


func test_negative_damage_is_ignored() -> void:
	var health := Health.new(10)
	var applied: int = health.take_damage(-7)
	assert_int(applied).is_equal(0)
	assert_int(health.current).is_equal(10)
