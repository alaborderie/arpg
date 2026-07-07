extends GdUnitTestSuite
## Unit tests for [DamageCalculator].
##
## These exercise pure domain logic with no scene tree, so they run under
## `godot --headless` (see `make test-game`). gdUnit4 note: a test suite extends
## [GdUnitTestSuite]; every `test_*` method is a case, and assertions use the fluent
## `assert_int(x).is_equal(y)` style.
##
## Many cases pin `base_min == base_max` so the base roll is fixed, letting us assert
## exact numbers independent of the RNG; the determinism cases instead use a real
## range and check reproducibility.


func _attack(overrides: Dictionary = {}) -> AttackProfile:
	var a := AttackProfile.new()
	a.base_min = overrides.get("base_min", 10)
	a.base_max = overrides.get("base_max", 10)
	a.added_flat = overrides.get("added_flat", 0.0)
	a.increased_pct = overrides.get("increased_pct", 0.0)
	a.more_multiplier = overrides.get("more_multiplier", 1.0)
	a.crit_chance = overrides.get("crit_chance", 0.0)
	a.crit_multiplier = overrides.get("crit_multiplier", 2.0)
	a.damage_type = overrides.get("damage_type", AttackProfile.DamageType.PHYSICAL)
	return a


func _defense(overrides: Dictionary = {}) -> DefenseProfile:
	var d := DefenseProfile.new()
	d.armor = overrides.get("armor", 0)
	d.resistance_pct = overrides.get("resistance_pct", 0.0)
	d.armor_constant = overrides.get("armor_constant", 10.0)
	d.max_physical_reduction = overrides.get("max_physical_reduction", 0.90)
	d.max_resistance = overrides.get("max_resistance", 0.75)
	return d


func _calc(seed_value: int) -> DamageCalculator:
	return DamageCalculator.new(RngService.new(seed_value))


func test_base_hit_with_no_modifiers_returns_base_damage() -> void:
	var result := _calc(1).calculate_hit(_attack(), _defense())
	assert_int(result.amount).is_equal(10)
	assert_bool(result.is_critical).is_false()
	assert_float(result.mitigation_applied).is_equal_approx(0.0, 0.0001)


func test_added_flat_is_applied_before_scaling() -> void:
	var result := _calc(1).calculate_hit(_attack({"added_flat": 5.0}), _defense())
	# 10 + 5 = 15
	assert_int(result.amount).is_equal(15)


func test_increased_damage_scales_additively() -> void:
	var result := _calc(1).calculate_hit(_attack({"increased_pct": 150.0}), _defense())
	# 10 * (1 + 1.5) = 25
	assert_int(result.amount).is_equal(25)


func test_more_multiplier_scales_multiplicatively() -> void:
	var overrides := {"increased_pct": 100.0, "more_multiplier": 1.5}
	var result := _calc(1).calculate_hit(_attack(overrides), _defense())
	# 10 * (1 + 1.0) * 1.5 = 30
	assert_int(result.amount).is_equal(30)


func test_guaranteed_crit_applies_multiplier() -> void:
	var overrides := {"crit_chance": 1.0, "crit_multiplier": 2.5}
	var result := _calc(1).calculate_hit(_attack(overrides), _defense())
	# 10 * 2.5 = 25
	assert_int(result.amount).is_equal(25)
	assert_bool(result.is_critical).is_true()


func test_zero_crit_chance_never_crits() -> void:
	for s in range(25):
		var result := _calc(s).calculate_hit(_attack({"crit_chance": 0.0}), _defense())
		assert_bool(result.is_critical).is_false()


func test_armor_reduces_physical_damage_with_diminishing_returns() -> void:
	# incoming = 10, armor = 100, K = 10 -> reduction = 100 / (100 + 10*10) = 0.5
	var result := _calc(1).calculate_hit(
		_attack({"base_min": 10, "base_max": 10}),
		_defense({"armor": 100, "armor_constant": 10.0})
	)
	# 10 * (1 - 0.5) = 5
	assert_int(result.amount).is_equal(5)
	assert_float(result.mitigation_applied).is_equal_approx(0.5, 0.0001)


func test_physical_reduction_is_capped() -> void:
	var result := _calc(1).calculate_hit(
		_attack({"base_min": 100, "base_max": 100}),
		_defense({"armor": 1000000, "max_physical_reduction": 0.90})
	)
	# Raw reduction ~0.999 is clamped to 0.90 -> 100 * 0.10 = 10
	assert_int(result.amount).is_equal(10)
	assert_float(result.mitigation_applied).is_equal_approx(0.90, 0.0001)


func test_elemental_resistance_is_capped() -> void:
	var result := _calc(1).calculate_hit(
		_attack({"base_min": 100, "base_max": 100, "damage_type": AttackProfile.DamageType.FIRE}),
		_defense({"resistance_pct": 200.0, "max_resistance": 0.75})
	)
	# Resistance clamped to 0.75 -> 100 * 0.25 = 25
	assert_int(result.amount).is_equal(25)


func test_damage_is_never_below_one() -> void:
	var result := _calc(1).calculate_hit(
		_attack({"base_min": 1, "base_max": 1, "damage_type": AttackProfile.DamageType.FIRE}),
		_defense({"resistance_pct": 75.0})
	)
	# 1 * 0.25 = 0.25 -> floor 0 -> clamped up to the minimum of 1
	assert_int(result.amount).is_equal(1)


func test_base_roll_stays_within_range() -> void:
	for s in range(50):
		var result := _calc(s).calculate_hit(_attack({"base_min": 5, "base_max": 15}), _defense())
		assert_int(result.amount).is_between(5, 15)


func test_same_seed_and_inputs_are_deterministic() -> void:
	var attack := _attack({"base_min": 5, "base_max": 50, "crit_chance": 0.5})
	var defense := _defense({"armor": 40})
	var first := _calc(12345).calculate_hit(attack, defense)
	var second := _calc(12345).calculate_hit(attack, defense)
	assert_int(second.amount).is_equal(first.amount)
	assert_bool(second.is_critical).is_equal(first.is_critical)


func test_different_seeds_produce_a_spread() -> void:
	var attack := _attack({"base_min": 1, "base_max": 1000, "crit_chance": 0.5})
	var defense := _defense()
	var seen := {}
	for s in range(20):
		seen[_calc(s).calculate_hit(attack, defense).amount] = true
	assert_int(seen.size()).is_greater(1)
