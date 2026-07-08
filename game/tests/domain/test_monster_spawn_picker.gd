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
