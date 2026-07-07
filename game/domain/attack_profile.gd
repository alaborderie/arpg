class_name AttackProfile
extends RefCounted
## Pure data describing a single outgoing hit, consumed by [DamageCalculator].
##
## Every field here is a *tunable* that will ultimately be assembled from
## `shared/*.json` (weapon bases, skill data, affixes) — never a magic constant
## baked into logic. See docs/0005-data-driven-balance.md.

## Damage element. PHYSICAL is mitigated by armour; the rest by resistances.
enum DamageType { PHYSICAL, FIRE, COLD, LIGHTNING }

## Inclusive base damage range; the actual hit rolls uniformly within it.
var base_min: int = 1
var base_max: int = 1
## Flat damage added before percentage scaling (e.g. from support gems/affixes).
var added_flat: float = 0.0
## Sum of all "increased" modifiers, in percent. These stack additively.
var increased_pct: float = 0.0
## Product of all "more"/"less" modifiers. These stack multiplicatively (1.0 = none).
var more_multiplier: float = 1.0
## Probability of a critical strike, in [0.0, 1.0].
var crit_chance: float = 0.0
## Damage multiplier applied on a critical strike (1.5 = +50%).
var crit_multiplier: float = 1.5
var damage_type: DamageType = DamageType.PHYSICAL
