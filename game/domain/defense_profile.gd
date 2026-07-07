class_name DefenseProfile
extends RefCounted
## Pure data describing a defender, consumed by [DamageCalculator].
##
## As with [AttackProfile], every value is a tunable sourced from data
## (`shared/monsters.json`, character stats, equipment) rather than hard-coded.

## Physical armour rating. Mitigation has diminishing returns and scales against
## the size of the incoming hit (see [DamageCalculator]).
var armor: int = 0
## Elemental resistance for the incoming damage type, in percent.
var resistance_pct: float = 0.0
## The `K` constant in the armour formula `armor / (armor + K * hit)`. Lives here
## (rather than in code) so global balance is tuned from `shared/combat.json` (M2).
var armor_constant: float = 10.0
## Hard cap on physical damage reduction, as a fraction in [0.0, 1.0].
var max_physical_reduction: float = 0.90
## Hard cap on elemental resistance, as a fraction in [0.0, 1.0].
var max_resistance: float = 0.75
