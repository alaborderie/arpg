class_name SkillSlots
extends RefCounted
## Pure slot-unlock rules for G9's multi-skill-slot system (docs/0022): slot 0
## (Q) is unlocked from the start, slot 1 (W) unlocks at level 10, slot 2 (E)
## at level 20.
##
## Domain class (ADR 0003): no [Node], no file access, no randomness — just the
## level-gate rule, kept out of [Player] (a scene adapter) so it is unit-testable
## in isolation and both [Player] and `main.gd` consult the same single source
## instead of each hard-coding the level numbers.

const SLOT_COUNT: int = 3
## Index 0 is 1 (always unlocked — no level requirement below the minimum
## level 1 already starts at) rather than 0, so [method is_unlocked] stays a
## plain `>=` comparison with no special-cased slot 0 branch.
const UNLOCK_LEVELS: Array[int] = [1, 10, 20]


## True once [param level] has reached the level [param slot] unlocks at.
static func is_unlocked(slot: int, level: int) -> bool:
	return level >= unlock_level(slot)


## The level [param slot] unlocks at (1 for slot 0, meaning "always").
static func unlock_level(slot: int) -> int:
	return UNLOCK_LEVELS[clampi(slot, 0, SLOT_COUNT - 1)]
