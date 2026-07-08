extends GdUnitTestSuite
## Unit tests for [PlayerStats] — composing base player data + item contributions
## into the entity Dictionary [CombatProfiles] consumes.

## Mirrors the `player` object of `shared/player.json` (schema v2).
const BASE_PLAYER: Dictionary = {
	"move_speed": 6.0,
	"max_health": 100,
	"armor": 0,
	"damage": {"type": "physical", "base_min": 4, "base_max": 7},
	"crit_chance": 0.05,
	"crit_multiplier": 1.5,
	"attack_speed": 1.5,
	"attack_range": 1.8,
}


func test_no_items_composes_to_the_base_stats() -> void:
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [])
	var damage: Dictionary = composed.get("damage", {})
	assert_int(int(damage.get("base_min", 0))).is_equal(4)
	assert_int(int(composed.get("armor", -1))).is_equal(0)
	assert_float(float(composed.get("attack_speed", 0.0))).is_equal_approx(1.5, 0.0001)
	assert_float(float(composed.get("crit_chance", 0.0))).is_equal_approx(0.05, 0.0001)
	assert_int(int(composed.get("max_health", -1))).is_equal(100)


func test_compose_does_not_mutate_the_base_dictionary() -> void:
	var weapon: Dictionary = {"damage": {"type": "fire", "base_min": 2, "base_max": 5}, "armor": 3}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [weapon])
	assert_bool(composed == BASE_PLAYER).is_false()
	var base_damage: Dictionary = BASE_PLAYER.get("damage", {})
	assert_str(String(base_damage.get("type", ""))).is_equal("physical")
	assert_int(int(BASE_PLAYER.get("armor", -1))).is_equal(0)


func test_weapon_damage_replaces_unarmed_damage() -> void:
	var weapon: Dictionary = {"damage": {"type": "fire", "base_min": 2, "base_max": 5}}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [weapon])
	var damage: Dictionary = composed.get("damage", {})
	assert_str(String(damage.get("type", ""))).is_equal("fire")
	assert_int(int(damage.get("base_min", 0))).is_equal(2)
	assert_int(int(damage.get("base_max", 0))).is_equal(5)


func test_armor_and_resistances_add_across_items() -> void:
	var vest: Dictionary = {"armor": 9, "resistances": {"fire": 25}}
	var weapon: Dictionary = {"armor": 2, "resistances": {"fire": 10, "lightning": 15}}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [vest, weapon])
	assert_int(int(composed.get("armor", 0))).is_equal(11)
	var resistances: Dictionary = composed.get("resistances", {})
	assert_int(int(resistances.get("fire", 0))).is_equal(35)
	assert_int(int(resistances.get("lightning", 0))).is_equal(15)


func test_attack_speed_percentages_sum_then_scale_once() -> void:
	var a: Dictionary = {"attack_speed_pct": 10.0}
	var b: Dictionary = {"attack_speed_pct": 5.0}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [a, b])
	# 1.5 * (1 + 15/100) = 1.725 — additive percentages, one multiplication.
	assert_float(float(composed.get("attack_speed", 0.0))).is_equal_approx(1.725, 0.0001)


func test_crit_chance_adds_percentage_points_and_clamps() -> void:
	var precise: Dictionary = {"crit_chance_pct": 2.0}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [precise])
	assert_float(float(composed.get("crit_chance", 0.0))).is_equal_approx(0.07, 0.0001)
	var absurd: Dictionary = {"crit_chance_pct": 500.0}
	var clamped: Dictionary = PlayerStats.compose(BASE_PLAYER, [absurd])
	assert_float(float(clamped.get("crit_chance", 0.0))).is_equal_approx(1.0, 0.0001)


## G3 (docs/0017): the level-bonus contribution key, same "sum then scale once"
## rule as attack_speed/cast_speed.
func test_max_health_percentages_sum_then_scale_once() -> void:
	var level_bonus: Dictionary = {"max_health_pct": 21.0}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [level_bonus])
	# 100 * 1.21 = 121.
	assert_int(int(composed.get("max_health", 0))).is_equal(121)


func test_max_health_pct_compounded_by_progression_curve_matches_1_1_pow_level() -> void:
	# The exact shape ProgressionCurve.bonus_contribution hands PlayerStats: at
	# level 3 with a 10%/level bonus, (1.1^2 - 1) * 100 = 21%.
	var level_three_bonus: Dictionary = {"max_health_pct": 21.0}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [level_three_bonus])
	assert_int(int(composed.get("max_health", 0))).is_equal(
		roundi(float(BASE_PLAYER.get("max_health", 0)) * pow(1.1, 2))
	)


func test_composed_stats_feed_combat_profiles_end_to_end() -> void:
	# The whole point of composition: the output is a drop-in entity Dictionary.
	var weapon: Dictionary = {"damage": {"type": "fire", "base_min": 8, "base_max": 8}}
	var composed: Dictionary = PlayerStats.compose(BASE_PLAYER, [weapon])
	var attack: AttackProfile = CombatProfiles.attack_from_data(composed)
	assert_int(attack.damage_type).is_equal(AttackProfile.DamageType.FIRE)
	assert_int(attack.base_min).is_equal(8)
	assert_int(attack.base_max).is_equal(8)
