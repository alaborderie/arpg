class_name ProgressionCurve
extends RefCounted
## The XP curve and per-level bonus formula (G3).
##
## Domain class (ADR 0003): built from the plain parsed `shared/progression.json`
## Dictionary an adapter (`main.gd`/[Player], via [BalanceData]) hands in; no file
## access, no Node, no randomness (nothing here needs [RngService] — the curve is
## a pure function of total XP and level).
##
## Curve shape: the XP required to go from level `L` to `L + 1` is
## `xp_base * xp_growth^(L - 1)`, rounded to the nearest integer — a classic
## exponential ARPG curve, `xp_growth > 1` guaranteeing each step is strictly
## larger than the last (monotonicity). Thresholds are precomputed once up to
## `max_level` at construction time so [method level_for_total_xp] and
## [method progress_for_total_xp] are cheap table lookups rather than repeated
## `pow()` calls on every kill.
##
## Per-level bonus: docs/0017 decided the ticket's "+10% attack speed/cast
## speed/max life per level, multiplicative (x1.1^level)" compounds true-to-spec
## when nothing else is touching those stats — [method bonus_contribution]
## returns a single contribution Dictionary whose `_pct` values already encode
## `(1 + level_bonus_pct/100)^(level-1) - 1` as a percentage, so
## [PlayerStats.compose]'s single "sum then scale once" pass reproduces exact
## multiplicative compounding *for this one contribution*. See docs/0017 for the
## documented deviation when an item affix also contributes to the same stat.

## Fallbacks if `shared/progression.json` cannot be read; keep the game
## playable (a flat, slow curve) rather than crash. Not the balance source.
const DEFAULT_MAX_LEVEL: int = 20
const DEFAULT_XP_BASE: float = 20.0
const DEFAULT_XP_GROWTH: float = 1.2
const DEFAULT_LEVEL_BONUS_PCT: float = 10.0

var _max_level: int
var _level_bonus_pct: float
## Index `i` (0-based) holds the total XP required to REACH level `i + 1` from
## zero — index 0 is always 0 (level 1 needs no XP). Size is `_max_level`.
var _cumulative_xp_for_level: Array[int] = []


## [param progression_data] is the `progression` object of `shared/progression.json`.
func _init(progression_data: Dictionary) -> void:
	_max_level = maxi(2, int(progression_data.get("max_level", DEFAULT_MAX_LEVEL)))
	_level_bonus_pct = float(progression_data.get("level_bonus_pct", DEFAULT_LEVEL_BONUS_PCT))
	var xp_base: float = float(progression_data.get("xp_base", DEFAULT_XP_BASE))
	var xp_growth: float = float(progression_data.get("xp_growth", DEFAULT_XP_GROWTH))
	_build_thresholds(xp_base, xp_growth)


func _build_thresholds(xp_base: float, xp_growth: float) -> void:
	_cumulative_xp_for_level = [0]
	var cumulative: int = 0
	for level: int in range(1, _max_level):
		var step: int = maxi(1, roundi(xp_base * pow(xp_growth, level - 1)))
		cumulative += step
		_cumulative_xp_for_level.append(cumulative)


func max_level() -> int:
	return _max_level


## Total XP required to reach [param level] from zero (level 1 is always 0).
## Clamps [param level] into `[1, max_level]` so an out-of-range value degrades
## instead of indexing out of bounds.
func xp_required_for_level(level: int) -> int:
	var index: int = clampi(level, 1, _max_level) - 1
	return _cumulative_xp_for_level[index]


## The level reached by accumulating [param total_xp], capped at `max_level`
## (further XP still accrues — [method progress_for_total_xp] just reports the
## bar as full — but the level itself never exceeds the curve's ceiling).
func level_for_total_xp(total_xp: int) -> int:
	var level: int = 1
	for candidate: int in range(2, _max_level + 1):
		if total_xp >= _cumulative_xp_for_level[candidate - 1]:
			level = candidate
		else:
			break
	return level


## Everything the XP bar UI needs in one call: `level`, `xp_into_level` (progress
## since the last level-up), `xp_to_next_level` (0 once `max_level` is reached —
## the bar should read as full/maxed), and `max_level` itself.
func progress_for_total_xp(total_xp: int) -> Dictionary:
	var level: int = level_for_total_xp(total_xp)
	var xp_into_level: int = total_xp - xp_required_for_level(level)
	var xp_to_next_level: int = 0
	if level < _max_level:
		xp_to_next_level = xp_required_for_level(level + 1) - xp_required_for_level(level)
	return {
		"level": level,
		"xp_into_level": xp_into_level,
		"xp_to_next_level": xp_to_next_level,
		"max_level": _max_level,
	}


## The one contribution Dictionary G3 adds to [Player]'s existing
## `contributions` array (docs/0016/0017): `attack_speed_pct`, `cast_speed_pct`
## and `max_health_pct` all carry the same compounded percentage,
## `(1 + level_bonus_pct/100)^(level-1) - 1`, expressed as a percentage so
## [PlayerStats.compose]'s existing "sum then scale by `(1 + pct/100)` once"
## rule reproduces `base * 1.1^(level-1)` exactly when this is the only
## contribution touching that stat. Level 1 always returns 0 for every key
## (no bonus until the first level-up).
func bonus_contribution(level: int) -> Dictionary:
	var clamped_level: int = clampi(level, 1, _max_level)
	var multiplier: float = pow(1.0 + _level_bonus_pct / 100.0, clamped_level - 1)
	var pct: float = (multiplier - 1.0) * 100.0
	return {
		"attack_speed_pct": pct,
		"cast_speed_pct": pct,
		"max_health_pct": pct,
	}
