# 21. Support spells: level-up picks that modify your skills

- Status: accepted
- Date: 2026-07-08

## Context

G8 (issue #15) adds PoE-support-gem-lite passives: on most level-ups the
player picks 1 of 3 **support spells**, global modifiers that change how the
*equipped* skill behaves (slot-2/3 arrive in G9). Several sub-decisions fall
out: where each support's effect lives (the existing `PlayerStats.compose`
contributions pipeline, ADR 0011, or the G6 cast pipeline for anything that
changes projectile count), whether duplicates should be offerable/stackable,
where the offer's randomness comes from and whether that stream's state must
survive a save (ADR 0012's reasoning applies differently here than it did to
G2's one-shot skill offer), how levels 10/20 stay reserved for G9 without
forking the level-up path, how a big XP grant crossing several levels avoids
stacking pick screens, and how the save envelope grows to carry owned
supports.

## Decision

**`shared/supports.json`, 12 supports, one flat file — not a variant column
on `skills.json`.** Supports are orthogonal to which skill is equipped (G9
will eventually let more than one skill exist, and every support still
applies to whichever is active), so they get their own catalog
(`SupportCatalog`, `game/domain/support_catalog.gd`) mirroring `SkillCatalog`'s
shape exactly: `_init` indexes by id, `support(id)`/`all_supports()` are plain
lookups, `offer(rng, count)` draws distinct entries without replacement via
the same "pop a random index from the remaining pool" fixed order
`SkillCatalog.offer`/`LootRoller._roll_affixes` already document. Each entry
carries `id`, `name`, `description` (for the picker UI), `family` (`stat` or
`pipeline` — documentation/UI metadata only; both are summed identically),
`stat` (which contribution key it feeds) and `value`; the four
`added_flat_<element>_damage` entries also carry `element`.

The list, and where each one's effect lives:

| id | mechanism | contribution key |
|---|---|---|
| `increased_damage` | stat | `damage_pct` |
| `increased_attack_cast_speed` | stat | `attack_cast_speed_pct` (fans into both `attack_speed_pct`/`cast_speed_pct`) |
| `added_flat_fire_damage` / `_cold_` / `_lightning_` / `_poison_damage` | stat | `added_flat_damage` (keyed by element) |
| `increased_crit_chance` | stat | `crit_chance_pct` (the same key item affixes already populate) |
| `increased_crit_multiplier` | stat | `crit_multiplier_pct` (new compose rule) |
| `increased_range` | stat | `range_pct` (new compose rule, feeds `attack_range`) |
| `faster_projectiles` | stat | `projectile_speed_pct` (new compose rule, feeds the new `projectile_speed` stat) |
| `life_on_kill` | stat | `life_on_kill` (flat, summed) |
| `added_projectiles` | pipeline | `added_projectiles` (flat, summed; read directly by `Player`'s cast methods) |

**Chain and multistrike are deliberately not implemented.** The ticket asks
for them only "if genuinely cheap given G6's projectile design." Chain (an
extra bounce onto a second target after the first hit) would need a
directional `Projectile` to *survive* its first hit instead of freeing itself
immediately, re-run the nearest-monster sweep excluding whatever it just hit,
and redirect - not outrageous, but it changes `_resolve_hit_on`'s
"hit-then-free" contract that every mode currently shares, and a second bounce
target needs its own exclusion state the projectile doesn't carry today.
Multistrike (repeat the whole attack N times) interacts with the
cooldown/facing contract `cast_at` (ADR 0019) deliberately keeps simple - a
repeat needs its own timing that isn't "the same cooldown, N times" without
either overlapping repeats or stalling the next real cast. Both are real
scope, not a one-line add; twelve supports already clears "10+", so both are
left as documented future work rather than rushed in.

**Duplicates: an offer is drawn from the FULL support pool every time, never
excluding what the player already owns, and stacking is a straightforward
sum.** `SupportCatalog.offer` takes no "owned" parameter at all. Two reasons:
mechanically, every stat this ticket adds is either a summed percentage
(`PlayerStats.compose`'s existing "sum then scale once" rule, extended to the
new keys) or a summed flat value - stacking the same support twice is exactly
"the contribution counted twice," no special-casing needed. Design-wise,
excluding owned supports would shrink the offer pool every level (mattering
a lot with only 12 entries), and a player reasonably might want to reinforce
a support they already have rather than being forced into breadth. This is
the "your call, document it" decision the ticket calls out.

**Stat-family routing extends `PlayerStats.compose` directly; `attack_range`
and `projectile_speed` turned out to be reachable through composition after
all.** The ticket flagged `range`/`projectile_speed` as possibly needing a
different path ("skill-profile building where composition doesn't reach").
In practice both are already plain fields flowing through `_config` the same
way `attack_speed`/`cast_speed`/`max_health` do - G3 already proved this
"add one more `_pct` rule to `compose`" pattern scales to new stats, so
`range_pct`/`projectile_speed_pct`/`crit_multiplier_pct`/`damage_pct` are four
more rules in the same function rather than a parallel mechanism.
`projectile_speed` needed one new baseline field, `shared/player.json`'s
`projectile_speed: 18.0` (schema_version 2 -> 3), matching `Projectile.SPEED`'s
pre-G8 hard-coded value exactly so an unmodified player casts identically to
before. `damage_pct`/`added_flat_damage` are the one genuinely new shape:
after the existing implicit-damage-replace rule picks a `damage` dict (a
weapon's, or the skill's own), `added_flat_damage` (if the composed damage's
own `type` has a nonzero entry) adds first, then `damage_pct` scales - the
same "(implicit + added) * scale" order `ItemStats.contribution` already uses
for a weapon's own affixes, kept consistent rather than reinvented.

**`added_flat_<element>_damage` only ever applies to a hit whose own type
matches the element - a genuine, documented simplification of the PoE
original.** The whole damage-resolution pipeline (`AttackProfile`,
`DamageCalculator`, `CombatProfiles`) tracks exactly one damage type per hit;
true "added lightning damage on a physical attack" would need a hit to carry
multiple typed damage instances, resolved and mitigated separately - a bigger
change to `DamageCalculator`'s contract than this ticket's scope justifies.
Choosing "the flat bonus only counts when your skill's own element already
matches" keeps the single-type-per-hit invariant intact and still gives each
of the four supports a real (if narrower) effect; a future ticket that wants
true off-element added damage needs to teach the pipeline to resolve more
than one `AttackProfile` per hit.

**`life_on_kill`/`added_projectiles` are new, flat (non-percentage) compose
outputs `Player` reads directly - `CombatProfiles` never sees them.**
`PlayerStats.compose`'s contract is "produce the entity Dictionary
`CombatProfiles` consumes" (ADR 0010/0011); these two fields are consumed one
level up, by `Player._recompose_stats` (`_life_on_kill`, `_added_projectiles`)
and `main.gd` (`_on_monster_died` calls `_player.heal(_player.life_on_kill())`
after every kill - a no-op at the default 0). Composing them in the same
Dictionary anyway, rather than a parallel structure, means one contributions
array and one function still cover every support's math, stat or pipeline.

**`added_projectiles` fans out N projectiles in both cast modes, per the
"must work in both homing and directional" pitfall.** Directional
(`_fire_projectile_directional`): each extra projectile is the aim direction
rotated by `SUPPORT_PROJECTILE_FAN_DEGREES` (12°) times an offset centered on
zero (so an even fan is symmetric either side of dead-on aim) - a base cast
(count 1) is simply a fan of one with zero offset, no special case. Homing
(`_fire_projectile`): there is no "direction" to fan around a locked target,
so extra projectiles are just extra separate homing shots at the same
target (a small cosmetic sideways spawn offset only, so they don't render
exactly stacked) - more hits on the one target, not a wider net. Melee casts
never read `_added_projectiles` at all - it is a documented no-op for melee,
the same "some supports just don't touch some skill kinds" shape G2 already
established for `attack_speed` vs. `cast_speed`. `Projectile.setup_homing`/
`setup_directional` both grew an optional trailing `speed` parameter
(defaulting to the unchanged `SPEED` constant) so `faster_projectiles`
(`projectile_speed_pct`) can scale travel speed per-cast without every
existing call site needing an update.

**Offers come from a fifth dedicated RNG stream, `master_seed + 4` - and,
unlike G2's one-shot skill-offer stream, its position DOES persist in the
save.** ADR 0015/0016 chose not to persist the spawn stream (`+2`, ephemeral
world state forever) and the skill-offer stream (`+3`, drawn from exactly
once, before any save is even possible) for two different reasons that both
happen to add up to "doesn't matter if a reload replays it differently."
Neither reason applies to the support-offer stream: it is drawn from
repeatedly across the *entire* run, both before and after saves exist, so a
reload that replayed it from the derived seed instead of resuming would show
a **different** 3-card offer than the one a player already saw and chose
from at that exact point in their save - the practical failure mode being "I
save-scummed my way to a better level-10 offer by reloading," which is
exactly the kind of replay-inconsistency ADR 0012's RNG-state-persistence
discipline exists to prevent for combat/loot. So `supports_offer_rng_state`
joins the envelope alongside `combat_rng_state`/`loot_rng_state`, restored
the same way (`main.gd`'s `.get(key, current_state)` no-op-if-absent idiom,
which also quietly handles a pre-G8 save that never touched this stream at
all).

**The reserved-levels seam for G9: `main.gd._level_up_reward(level)`.**
`Player.gain_xp` emits a new `level_up(level)` signal once per level crossed
(a big XP grant crossing several levels emits several signals, in order) -
`main.gd` connects it directly to `_level_up_reward`, which:

```gdscript
func _level_up_reward(level: int) -> void:
	if skip_support_offers or level == 10 or level == 20:
		return
	_pending_support_offers.append(_support_catalog.offer(_support_offer_rng, 3))
	if not get_tree().paused:
		_show_next_support_offer()
```

is the *entire* dispatcher. G9 claims levels 10/20 by editing only this
function - e.g. branching those two levels to its own skill-unlock UI instead
of returning - with zero changes anywhere else in the level-up path
(`Player.gain_xp`, the queueing below, `SupportChoiceUI`). `skip_support_offers`
is the scene-test bypass knob mentioned in the same breath: the same idiom as
`starting_skill_id`/`forced_elite`, defaulting false, pinned true by every
existing scene test that can cross a level threshold for an unrelated reason
(`test_xp_progression.gd`, `test_health_bars.gd`) so G8 doesn't retroactively
break G3/G4's suites; the new G8 suite (`test_support_choice.gd`) is the one
place that deliberately leaves it false.

**A big XP grant crossing several eligible levels queues offers instead of
stacking screens.** `main.gd._pending_support_offers` is a plain queue of
already-drawn 3-support offers; `_level_up_reward` only calls
`_show_next_support_offer` (which pauses the tree and calls
`SupportChoiceUI.setup`) when the tree isn't already paused - a second
level-up signal arriving in the same frame (because `gain_xp` emitted several
before yielding back to the caller) just appends to the queue instead.
`_on_support_chosen` pops the next queued offer (staying paused, no
unpause/repause flicker) instead of unpausing, only unpausing once the queue
is actually empty. This is the "queue or collapse" choice the ticket poses -
queue was chosen over collapsing (e.g. showing one enlarged N-pick screen)
because it keeps `SupportChoiceUI` exactly as simple as `SkillChoiceUI`
(always exactly 3 cards), at the cost of clicking through more than one
screen back-to-back on a rare big-XP-grant frame - an acceptable trade for
how rarely multi-level jumps happen versus a bespoke variable-count UI.

**Save: `schema_version` 4, `_migrate_v3_to_v4`.** `player.supports` (an
`Array[String]`, duplicates preserved) joins the envelope; a pre-G8 save gets
an empty array, the same "never fail on missing data" discipline every prior
migration step follows. `Player.load_state` restores `_owned_supports` before
the first recompose (same ordering reasoning as G3's level restore in ADR
0017 - a support's effect must already be in `_config` before the saved
health value is clamped against the ceiling it implies).

**Test knob and UI**: `SupportChoiceUI` (`game/scenes/ui/support_choice_ui.gd`/
`.tscn`) is `SkillChoiceUI` copied nearly verbatim - `process_mode = ALWAYS`,
same pause idiom, a card per offered support exposing `support_id` via
`set_meta` for tests, a `_value_text` helper formatting `_pct` stats as
percentages and everything else as a flat `+N`. `skip_support_offers` is
documented above; `Player.add_support(id)` (the same seam
`_on_support_chosen` calls) is also the correct way for scene tests to grant
a specific support deterministically without driving the RNG offer or the UI
at all - `test_support_choice.gd` uses it directly for the
`added_projectiles`-spawns-two-projectiles and stat-changes-a-number cases,
reserving the real pick-and-pause flow for its own dedicated test.

## Consequences

- `shared/supports.json` + `shared/schemas/supports.schema.json` are wired
  into `make validate-data` and the CI `data` job alongside the other shared
  files. `shared/player.json`'s `schema_version` 2 -> 3 for the new
  `projectile_speed` field.
- `PlayerStats.compose` gained six new contribution keys
  (`damage_pct`, `range_pct`, `projectile_speed_pct`, `crit_multiplier_pct`,
  `life_on_kill`, `added_projectiles`) and one new merge-by-key Dictionary
  (`added_flat_damage`) - all additive to the existing rules, so every G1-G7
  scene/domain test that exercises `compose` kept its exact expected numbers
  with zero changes needed to the code (only to callers of
  `SaveData.build`, whose signature grew).
- `Projectile.setup_homing`/`setup_directional` both grew an optional
  trailing `speed` parameter defaulting to the unchanged `SPEED` constant -
  every pre-G8 call site keeps compiling and behaving identically.
- `main.gd` gained a fifth RNG stream, a second catalog, a new export knob,
  a support-choice UI reference and a small offer queue - all additive next
  to the existing skill-choice wiring, matching the pattern G2/G3/G7 already
  established for growing this scene's `_ready`.
- Every existing scene test that can cross a level threshold for a reason
  unrelated to G8 (`test_xp_progression.gd`, `test_health_bars.gd`) now pins
  `skip_support_offers = true` - the same "pin the new knob or get the full
  default experience" rule G1/G2/G7 already established for
  `target_population`/`starting_skill_id`/`forced_elite`.
- G9 (W/E slots, issue's own "Blocks: G9" note) has exactly one seam to
  extend: `main.gd._level_up_reward`'s `level == 10 or level == 20` branch,
  today a no-op, becomes G9's skill-slot-unlock UI dispatch. Supports
  themselves stay global exactly as designed - G9 adding more skill slots
  doesn't change anything about how a support's contribution is computed or
  applied, since `PlayerStats.compose` already runs once over whatever the
  (possibly multi-skill, post-G9) equipped configuration produces.
