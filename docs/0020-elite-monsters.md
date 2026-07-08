# 20. Elite monsters: half population, 1-in-10 elite roll, loot bias

- Status: accepted
- Date: 2026-07-08

## Context

G7 (issue #14) wants fewer, spicier monsters: halve the maintained alive
population, give each spawn a 1-in-10 chance of being an ELITE variant of its
base type (bigger, slower, tougher, worth more XP, rarer loot), and keep every
existing determinism/domain-scene-separation guarantee (ADR 0003/0004) intact
— the elite roll rides the same spawn RNG stream G1 already dedicated to
monster choice and position (`master_seed + 2`, docs/0015), never a new one.
Three sub-decisions fall out: where the elite roll lives and how it's tested,
where the elite multipliers live, and how loot bias is expressed without
forking `LootRoller`'s determinism contract (ADR 0011).

## Decision

**Population halved via the existing constant.** `MonsterSpawner.
DEFAULT_TARGET_POPULATION` goes 10 -> 5; the `target_population` test knob
(docs/0015) is untouched, so every scene test that already pins a population
keeps working unchanged.

**The elite roll is one more domain draw on the existing spawn stream, decided
by `MonsterSpawnPicker` for the same reason `pick_monster_id`/`ring_offset`
already are — a pure, unit-testable function.** `MonsterSpawnPicker.
roll_is_elite(rng, chance) -> bool` is `rng.randf() < chance`, drawn in
`MonsterSpawner._spawn_at` right after the monster-id draw (updated draw order
documented at the top of `monster_spawn_picker.gd`: ring offset, monster id,
elite roll). `chance` is caller-supplied — the spawner reads it from
`shared/combat.json`'s new `elite` block — so the domain class stays pure
data-in/data-out with no file access (ADR 0003).

**A new test knob, `MonsterSpawner.forced_elite`, mirrors `forced_monster_id`
exactly**, including the "skip the draw, don't just override the result"
rule: -1 (default) lets the stream decide, 0/1 force every spawn non-elite/
elite while consuming nothing from the stream. This matters for the same
reason it did for `forced_monster_id`: a forced value must never shift the
stream position other spawns' ring offsets depend on. Every existing scene
test that pins a swept seed to an exact combat/loot/XP outcome
(`test_combat.gd`, `test_loot.gd`, `test_health_bars.gd`, `test_xp_progression.
gd`, `test_save_load.gd`, `test_ranged_skill.gd`, `test_free_aim_cast.gd`, and
`test_monster_spawner.gd`'s own non-elite tests) now also pins `forced_elite =
0` — without it, the new elite draw would still consume from the stream
(nothing skips it just because a test forces a monster id), and could
occasionally promote a swept-seed test's forced `fallen_imp` to a 3x-HP elite,
breaking assertions tuned for the normal monster. This is the same "pin the
new knob or get the full default experience" rule G1/G2 already established
for `target_population`/`forced_monster_id`/`starting_skill_id`.

**Elite modifiers live in `shared/combat.json`'s new `elite` block, not as
GDScript constants.** `combat.json` already holds global tunables of the
formulas rather than any one entity's data (its own schema description says
so) — elite multipliers apply uniformly to whichever monster the roll picks,
independent of monster id, which is exactly that shape. `schema_version` 1 ->
2 (a new required top-level key). Concretely:

```json
"elite": {
  "spawn_chance": 0.1,
  "visual_scale": 1.6,
  "move_speed_multiplier": 0.6,
  "max_health_multiplier": 3.0,
  "xp_multiplier": 3.0
}
```

`MonsterSpawner.setup()` loads this once and hands the whole Dictionary
through to every `Monster.setup()` call alongside the new `is_elite: bool`
flag; `Monster` is the adapter that actually applies the numbers (health *
multiplier, move_speed * multiplier, xp_reward * multiplier, `_body.scale =
Vector3.ONE * visual_scale`) — it never decides elite-or-not, matching the
existing "domain decides, scene applies" split every other Monster stat
already follows. This was chosen over "a GDScript constant block" (which ADR
0015 explicitly blessed for spawn *pacing*, e.g. population/radii) because
these are genuine per-monster balance numbers (health, speed, XP) — ADR 0005's
territory — not encounter-design pacing; a future tuning pass changing "how
much tougher" an elite is shouldn't need a code change. Health/XP round with
`round()` before truncating to `int` so a `1.5x`-style multiplier (not used
today, but the schema allows any exclusive-minimum-1 value) doesn't silently
floor-bias every elite's numbers downward.

**Health bar height and visual scale share one factor.** `Monster.setup()`
recomputes the floating bar's height as `HEALTH_BAR_HEIGHT *
elite_multiplier("visual_scale")` (1.0 for a normal spawn, a no-op) instead of
leaving `_ready`'s pre-elite-knowledge default in place — the same ~0.3 m
clearance G5 tuned for the silhouette now scales with it. Hit-flash
(`CombatFx.flash_all(_body_parts)`) and the facing snout/glow both live inside
the scaled `Body` node, so they keep working unchanged — scaling a parent
`Node3D` doesn't touch a `MeshInstance3D`'s material or a monster's -Z facing
convention, both already established by G5 (docs/0018).

**Nav agent radius and the collision capsule are left unchanged.** Same
precedent G5 already set: `cinder_wraith`'s ~1.49 m hood already differed from
the shared 1.2 m capsule with no pathing problems, because the ticket only
ever asks for a *visual* swap. An elite is a bigger silhouette over the exact
same collision/nav footprint as its base type — deliberately, to avoid a new
class of pathing bug (agents squeezing past each other, wider corridors
needed) discovered in an unattended loop with no screenshots to check against.
Documented as a note-if-broken, not re-measured, the same posture docs/0018
took for prop-driven pathing costs.

**Loot bias is a second weight column on each rarity, read by the *same*
weighted draw** — not an extra RNG draw, not a separate table.
`shared/loot_tables.json`'s `rarity` entries gain a required `elite_weight`
(schema_version 1 -> 2): `normal` 60/15, `magic` 30/45, `rare` 10/40 (normal
kill / elite kill, both columns summing to 100 for readable percentages).
`LootRoller._pick_rarity(is_elite)` picks `elite_weight` instead of `weight`
for the one `randi_range` draw the rarity pick already made — falling back to
`weight` if `elite_weight` is absent, so the non-elite fixtures the existing
domain test suite already uses keep passing untouched. `roll_drop(monster_id,
is_elite := false)` threads the flag through; `main.gd` passes `monster.
is_elite()` the same way it already passes `monster.monster_id()`. This
"reads a different weight column, same draw" design was chosen over a
separate elite-only rarity table or an upshift multiplier applied post-pick,
specifically so an elite kill's RNG stream consumption is *identical in shape*
to a normal kill's — the drop/base/rarity/affix draw sequence never grows or
shrinks based on `is_elite`, which is what keeps this change from being a
save/replay-breaking reordering under ADR 0004's contract.
`test_loot_roller.gd`'s new statistical test asserts the shift directly:
two rollers seeded identically, one always elite, aggregate rarity counts
over 500 kills — elite kills land near the 85%-magic-or-rare split the data
implies, normal kills near the 40% split, with generous bands so the
assertion isn't flaky.

**The Go server (M6 farming) is untouched.** `internal/farming.Rarity` only
ever claimed `id`/`weight`/`affix_count_max` via `encoding/json` struct tags;
the new `elite_weight` field (and `combat.json`'s new `elite` block, which
`internal/farming` never reads at all — `data.go` says so explicitly) are
simply unclaimed JSON to Go's unmarshaler, no code change needed. The coarse
farming resolver does not model elites at all yet — a future milestone that
wants the AI-farming simulation to see elites needs to add `EliteWeight int`
to the `Rarity` struct and thread an `is_elite` flag through `rollRarity`,
mirroring the client's `LootRoller` change exactly.

## Consequences

- `combat.json` and `loot_tables.json` both bump `schema_version` (1 -> 2 for
  each) for a new required top-level/nested key — the same "bump on breaking
  shape" convention `monsters.schema.json` used for G2's `poison` field.
- Every scene test with a swept-seed kill sequence gained one line
  (`spawner.set("forced_elite", 0)`) — noted above, mechanical but necessary;
  a future ticket adding another spawn-stream draw should expect the same.
- `Monster.setup()`'s signature grew two optional trailing parameters
  (`is_elite`, `elite_config`, both defaulting to "not elite") rather than a
  new overload — every pre-G7 call site (there was only ever
  `MonsterSpawner`'s) keeps compiling unchanged, and the defaults make "not
  elite" the exact pre-G7 numbers.
- `Monster` gained `is_elite()`, `max_health()`, `move_speed()` getters purely
  for scene-test assertions (mirroring `Player.max_health()` from G3) — no
  other caller needs them yet.
- G8 (support spells modifying the cast pipeline) doesn't interact with this
  ticket's surface at all: elites change what a *monster* looks like/how much
  HP and XP it has, not anything about `Player.cast_at`/`_cast`. The one thing
  worth knowing: if a support spell's effect should behave differently against
  an elite (e.g. a debuff scaling with target max health), `Monster.
  is_elite()`/`max_health()` are already there to read.
