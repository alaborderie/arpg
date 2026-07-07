# 11. Loot rolling, inventory, and the equipment stat pipeline

- Status: accepted
- Date: 2026-07-08

## Context

M3 needs monsters to drop items, a player to pick them up and store them, and
equipping an item to actually change combat numbers — without forking the
`CombatProfiles` pipeline ADR 0010 built for base stats, and without breaking
ADR 0004 determinism (same seed + same kill order ⇒ same items) or ADR 0003
(domain/scene separation).

Three sub-decisions fall out of that: how a roll is structured and seeded, what
shape a "rolled item" is, and how equipped items feed back into the player's
effective stats.

## Decision

**Two data files, one roll pipeline.** `shared/items.json` holds `bases`
(implicit stats per equipment slot: a weapon's damage range, an armor piece's
flat armor) and the `affixes` pool (prefix/suffix, one `stat`, a rolled range,
eligible slots). `shared/loot_tables.json` holds the global `rarities` (weight
+ affix-count range) and per-monster `tables` (`drop_chance`, `base_pool`).
`LootRoller` (domain) draws from its injected `RngService` in a **fixed order**
per kill — drop roll, base pick, rarity pick, affix count, then affixes without
replacement — documented at the top of `loot_roller.gd` as part of the
determinism contract: reordering those draws is a save/replay-breaking change,
same caution as ADR 0004 already asks for combat rolls.

**A rolled item is a plain Dictionary**, not a domain object:
`{base_id, name, slot, rarity, affixes: [{id, stat, value}]}`. This is the same
choice ADR 0003 already made for `shared/*.json`-shaped data — it means the
item is trivially the thing M4 persists as-is (no serialization step), the
thing gdUnit assertions compare with `==`, and the thing that crosses the
domain/scene boundary without a translation layer. `ItemStats.contribution()`
resolves the *display* name pieces (`affix_name`, `kind`) once at roll time and
discards them from the persisted shape — only `id`/`stat`/`value` need to
survive, because the base and affix tables can always be rejoined by id later.

**A dedicated loot RNG stream.** `main.gd` seeds `_loot_rng` at
`master_seed + 1`, separate from the combat stream. Loot rolls then depend
*only* on the kill sequence, never on how many crit/damage rolls a particular
fight happened to consume — two playthroughs that kill monsters in the same
order get the same drops even if the fights themselves played out differently
(different positioning, different number of swings to land the kill). The
alternative — one shared stream — would make loot an accident of combat RNG
consumption, which is a strictly worse contract for the same determinism goal
and actively hostile to replay/verification later (ADR 0004, M6).

**Equipment recomposes the effective stat Dictionary, it doesn't branch the
combat code.** `PlayerStats.compose(base_player, contributions)` takes the
`player` object from `shared/player.json` and one `ItemStats.contribution()`
Dictionary per equipped item, and returns a Dictionary of the *exact same
shape* — so `CombatProfiles.attack_from_data()` / `defense_from_data()` (ADR
0010) consume it unchanged. Composition rules, chosen per stat because a
single rule doesn't fit all of them:
- `damage` — a weapon *replaces* the unarmed damage range (slots are unique,
  so at most one contribution ever carries `damage`).
- `armor` — additive (implicit + affixes + base armor).
- `attack_speed` / `crit_chance` — affixes are percentage modifiers; they sum
  first, then apply once to the base, rather than compounding per item. Crit
  chance clamps to `[0, 1]`.
- `resistances` — additive per element.

`Player._recompose_stats()` is the *one* funnel: every equip/unequip calls it,
it rebuilds `_config` from `_base_config` + `_inventory.equipped_items()`, and
every derived field (`_attack`, `_move_speed`, `_attack_range`,
`_seconds_between_attacks`) is re-read from the fresh `_config` in the same
place. There is no second code path for "player with gear."

**`Inventory` is a plain domain class over Dictionaries** — a `_bag: Array`
and an `_equipped: Dictionary` (slot name → item), swap-equip semantics (the
previous occupant of a slot lands back in the bag slot the new item came
from), bag-full and empty-slot guards returning `bool`. No Node, no signals;
`Player` re-emits `inventory_changed` for the UI after any successful mutation.

**Picking follows the ADR 0010 pattern one layer further.** `GroundDrop` sits
alone on physics layer 3 (`collision_layer = 4`, `collision_mask = 0`); the
click ray in `main.gd` now masks `MONSTER_PICK_MASK | DROP_PICK_MASK` so one
raycast finds either a monster or a drop, keeping the "one ray, additive
masks" shape ADR 0010 established instead of adding a second ray or a second
`_unhandled_input` branch.

## Consequences

- The rolled-item Dictionary shape is now a de facto save-file fragment: M4
  can serialize `Inventory.bag()` / `equipped_items()` directly. Persisting
  player state also means persisting `rng_seed` (or the `RngService` state via
  `get_state()`/`set_state()`) for both streams if resumed sessions need to
  keep rolling loot deterministically from where they left off.
- Two RNG streams (combat, loot) instead of one is a small amount of extra
  bookkeeping in `main.gd` and in any future save format, traded for drops
  that are stable under unrelated combat-timing changes.
- `PlayerStats.compose` duplicates the base Dictionary and every mutated
  sub-Dictionary (`damage`, `resistances`) rather than mutating in place, so
  `_base_config` — the pristine `shared/player.json` object — is never
  corrupted by equip/unequip churn. This costs a few small allocations per
  recompose, acceptable at "recompose on equip change," not per frame.
- Rarity and affix-count tuning lives entirely in `shared/loot_tables.json`
  (ADR 0005): adding a new rarity tier or reweighting drop odds never touches
  GDScript.
