extends GdUnitTestSuite
## Unit tests for [ProgressionCurve] — the XP-to-level curve and the per-level
## bonus formula (G3, docs/0017).
##
## A small, self-contained progression Dictionary (not the real
## `shared/progression.json`) so these numbers stay stable if the real balance
## data is retuned later — same idiom as test_skill_catalog.gd's SKILLS_DATA.
## Hand-worked thresholds: xp_base=10, xp_growth=2.0 doubles the requirement
## every level (10, 20, 40, 80 XP to go from 1->2, 2->3, 3->4, 4->5), so
## cumulative XP to *reach* level 2/3/4/5 is 10/30/70/150. max_level=5 caps it.
const PROGRESSION_DATA: Dictionary = {
	"max_level": 5,
	"xp_base": 10.0,
	"xp_growth": 2.0,
	"level_bonus_pct": 10.0,
}


func _curve() -> ProgressionCurve:
	return ProgressionCurve.new(PROGRESSION_DATA)


func test_xp_required_for_level_matches_hand_worked_thresholds() -> void:
	var curve: ProgressionCurve = _curve()
	assert_int(curve.xp_required_for_level(1)).is_equal(0)
	assert_int(curve.xp_required_for_level(2)).is_equal(10)
	assert_int(curve.xp_required_for_level(3)).is_equal(30)
	assert_int(curve.xp_required_for_level(4)).is_equal(70)
	assert_int(curve.xp_required_for_level(5)).is_equal(150)


func test_thresholds_strictly_increase() -> void:
	# Curve monotonicity: xp_growth > 1 must make every step strictly larger
	# than the last, and the cumulative total must strictly increase too.
	var curve: ProgressionCurve = _curve()
	var previous: int = -1
	for level: int in range(1, curve.max_level() + 1):
		var required: int = curve.xp_required_for_level(level)
		assert_int(required).is_greater(previous)
		previous = required


func test_level_for_total_xp_matches_the_boundaries() -> void:
	var curve: ProgressionCurve = _curve()
	assert_int(curve.level_for_total_xp(0)).is_equal(1)
	assert_int(curve.level_for_total_xp(9)).is_equal(1)
	assert_int(curve.level_for_total_xp(10)).is_equal(2)
	assert_int(curve.level_for_total_xp(29)).is_equal(2)
	assert_int(curve.level_for_total_xp(30)).is_equal(3)
	assert_int(curve.level_for_total_xp(69)).is_equal(3)
	assert_int(curve.level_for_total_xp(70)).is_equal(4)
	assert_int(curve.level_for_total_xp(149)).is_equal(4)
	assert_int(curve.level_for_total_xp(150)).is_equal(5)


func test_level_never_exceeds_max_level_however_much_xp_accrues() -> void:
	var curve: ProgressionCurve = _curve()
	assert_int(curve.level_for_total_xp(1000000)).is_equal(5)


func test_progress_breakdown_mid_level() -> void:
	var curve: ProgressionCurve = _curve()
	# 45 XP: level 3 (needs 30), 15 into it, 40 more (70 - 30) to reach level 4.
	var progress: Dictionary = curve.progress_for_total_xp(45)
	assert_int(int(progress.get("level", 0))).is_equal(3)
	assert_int(int(progress.get("xp_into_level", -1))).is_equal(15)
	assert_int(int(progress.get("xp_to_next_level", -1))).is_equal(40)
	assert_int(int(progress.get("max_level", 0))).is_equal(5)


func test_progress_reports_zero_xp_to_next_once_maxed() -> void:
	var curve: ProgressionCurve = _curve()
	var progress: Dictionary = curve.progress_for_total_xp(500)
	assert_int(int(progress.get("level", 0))).is_equal(5)
	assert_int(int(progress.get("xp_to_next_level", -1))).is_equal(0)


func test_bonus_contribution_is_zero_at_level_one() -> void:
	var curve: ProgressionCurve = _curve()
	var bonus: Dictionary = curve.bonus_contribution(1)
	assert_float(float(bonus.get("attack_speed_pct", -1.0))).is_equal_approx(0.0, 0.0001)
	assert_float(float(bonus.get("cast_speed_pct", -1.0))).is_equal_approx(0.0, 0.0001)
	assert_float(float(bonus.get("max_health_pct", -1.0))).is_equal_approx(0.0, 0.0001)


func test_bonus_contribution_at_level_two_is_one_bonus_step() -> void:
	var curve: ProgressionCurve = _curve()
	var bonus: Dictionary = curve.bonus_contribution(2)
	# (1 + 10/100)^1 - 1 = 0.10 -> 10%.
	assert_float(float(bonus.get("attack_speed_pct", -1.0))).is_equal_approx(10.0, 0.0001)
	assert_float(float(bonus.get("cast_speed_pct", -1.0))).is_equal_approx(10.0, 0.0001)
	assert_float(float(bonus.get("max_health_pct", -1.0))).is_equal_approx(10.0, 0.0001)


## The ticket's compounding requirement: x1.1^level, not a flat 10% * level.
func test_bonus_contribution_at_level_five_compounds_multiplicatively() -> void:
	var curve: ProgressionCurve = _curve()
	var bonus: Dictionary = curve.bonus_contribution(5)
	# (1 + 10/100)^4 - 1 = 1.1^4 - 1 = 0.4641 -> 46.41%, NOT 40% (flat 10%*4).
	assert_float(float(bonus.get("attack_speed_pct", -1.0))).is_equal_approx(46.41, 0.01)
	assert_float(float(bonus.get("cast_speed_pct", -1.0))).is_equal_approx(46.41, 0.01)
	assert_float(float(bonus.get("max_health_pct", -1.0))).is_equal_approx(46.41, 0.01)


func test_bonus_contribution_clamps_above_max_level() -> void:
	var curve: ProgressionCurve = _curve()
	var at_max: Dictionary = curve.bonus_contribution(5)
	var beyond_max: Dictionary = curve.bonus_contribution(50)
	assert_float(float(beyond_max.get("attack_speed_pct", -1.0))) \
		.is_equal_approx(float(at_max.get("attack_speed_pct", -2.0)), 0.0001)
