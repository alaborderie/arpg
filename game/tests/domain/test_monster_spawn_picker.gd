extends GdUnitTestSuite
## Unit tests for [MonsterSpawnPicker] — pure spawn-selection math, no scene tree
## or NavigationServer needed.


func test_pick_monster_id_is_deterministic_for_a_given_seed() -> void:
	var ids: Array[String] = ["fallen_imp", "cinder_wraith"]
	var rng_a := RngService.new(7)
	var rng_b := RngService.new(7)
	for _i: int in 10:
		var picked_a: String = MonsterSpawnPicker.pick_monster_id(ids, rng_a)
		var picked_b: String = MonsterSpawnPicker.pick_monster_id(ids, rng_b)
		assert_str(picked_a).is_equal(picked_b)
		assert_bool(ids.has(picked_a)).is_true()


func test_pick_monster_id_on_empty_list_returns_empty_string() -> void:
	var rng := RngService.new(1)
	assert_str(MonsterSpawnPicker.pick_monster_id([], rng)).is_equal("")


func test_pick_monster_id_on_single_entry_always_returns_it() -> void:
	var ids: Array[String] = ["fallen_imp"]
	var rng := RngService.new(99)
	for _i: int in 5:
		assert_str(MonsterSpawnPicker.pick_monster_id(ids, rng)).is_equal("fallen_imp")


func test_ring_offset_stays_within_the_radius_band() -> void:
	var rng := RngService.new(11)
	for _i: int in 200:
		var offset: Vector3 = MonsterSpawnPicker.ring_offset(10.0, 20.0, rng)
		assert_float(offset.y).is_equal(0.0)
		var radius: float = offset.length()
		assert_float(radius).is_greater_equal(10.0)
		assert_float(radius).is_less_equal(20.0)


func test_ring_offset_is_deterministic_for_a_given_seed() -> void:
	var rng_a := RngService.new(42)
	var rng_b := RngService.new(42)
	for _i: int in 10:
		var offset_a: Vector3 = MonsterSpawnPicker.ring_offset(5.0, 15.0, rng_a)
		var offset_b: Vector3 = MonsterSpawnPicker.ring_offset(5.0, 15.0, rng_b)
		assert_float(offset_a.distance_to(offset_b)).is_equal_approx(0.0, 0.0001)


## G7 (issue #14, docs/0020): elite decision determinism, mirroring
## pick_monster_id/ring_offset's own determinism tests.
func test_roll_is_elite_is_deterministic_for_a_given_seed() -> void:
	var rng_a := RngService.new(21)
	var rng_b := RngService.new(21)
	for _i: int in 50:
		assert_bool(MonsterSpawnPicker.roll_is_elite(rng_a, 0.1)) \
			.is_equal(MonsterSpawnPicker.roll_is_elite(rng_b, 0.1))


func test_roll_is_elite_chance_zero_never_elite() -> void:
	var rng := RngService.new(3)
	for _i: int in 100:
		assert_bool(MonsterSpawnPicker.roll_is_elite(rng, 0.0)).is_false()


func test_roll_is_elite_chance_one_always_elite() -> void:
	var rng := RngService.new(4)
	for _i: int in 100:
		assert_bool(MonsterSpawnPicker.roll_is_elite(rng, 1.0)).is_true()


## Statistical sweep at the ticket's 1-in-10 default: over many draws the
## observed rate should land close to 0.1, not just "sometimes true".
func test_roll_is_elite_respects_the_configured_chance_statistically() -> void:
	var rng := RngService.new(123)
	const SAMPLES: int = 5000
	var elites: int = 0
	for _i: int in SAMPLES:
		if MonsterSpawnPicker.roll_is_elite(rng, 0.1):
			elites += 1
	var rate: float = float(elites) / float(SAMPLES)
	assert_float(rate).is_greater(0.07)
	assert_float(rate).is_less(0.13)


func test_ring_offset_does_not_cluster_at_the_centre() -> void:
	# A uniform-in-area draw would put most points near the inner radius; this
	# ring draw should average close to the middle of [min, max] instead.
	var rng := RngService.new(5)
	var total_radius: float = 0.0
	const SAMPLES: int = 500
	for _i: int in SAMPLES:
		total_radius += MonsterSpawnPicker.ring_offset(10.0, 20.0, rng).length()
	var average_radius: float = total_radius / SAMPLES
	assert_float(average_radius).is_greater(13.0)
	assert_float(average_radius).is_less(17.0)
