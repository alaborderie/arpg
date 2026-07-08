# 17. XP, levels, and per-level bonuses

- Status: accepted
- Date: 2026-07-08

## Context

G3 needs killing monsters to matter beyond loot: XP accumulates, XP levels the
player up, and each level grants a flat combat bonus (the ticket: "+10% attack
speed, +10% cast speed, +10% max life... multiplicative per level, i.e. x1.1
each"). Several sub-decisions fall out: where the curve lives and what shape
it takes, how the per-level bonus reaches `PlayerStats.compose` without
forking that pipeline (G2 built `attack_speed`/`cast_speed` there for exactly
this), what "multiplicative compounding" means once it goes through a
composition function whose existing rule is "percentages sum, then scale
once", what happens to current health on a level-up, and how the save
envelope grows to carry level/XP.

## Decision

**The curve lives in a new `shared/progression.json`, not an extension of
`player.json`.** Four fields: `max_level`, `xp_base`, `xp_growth`,
`level_bonus_pct` (schema in `shared/schemas/progression.schema.json`, wired
into `make validate-data` and the CI `data` job like every other shared file).
A new file rather than folding into `player.json` because this is a
*progression* concern orthogonal to the player's base combat stats — bumping
`player.schema.json`'s version for this would have coupled two independently-
tunable concerns (unarmed baseline vs. the level curve) into one file's
version history for no benefit. The Go server does not read this file today
(nothing in `internal/farming` needs a level curve yet) — noted here per
CLAUDE.md's ask, but explicitly out of scope; a future server-side farming
realism pass is the natural place to load it.

**Curve shape: exponential, precomputed into a threshold table.**
`ProgressionCurve` (`game/domain/progression_curve.gd`) computes the XP
required to go from level `L` to `L + 1` as `xp_base * xp_growth^(L - 1)`,
rounded to the nearest integer, and precomputes cumulative thresholds up to
`max_level` once at construction — `level_for_total_xp`/
`progress_for_total_xp` are then table lookups, not repeated `pow()` calls per
kill. `xp_growth` must exceed 1 (schema-enforced,
`exclusiveMinimum: 1`) so every step is strictly larger than the last
(monotonicity, unit-tested). Past `max_level`, XP still accrues but the level
itself is capped and `progress_for_total_xp` reports `xp_to_next_level: 0` —
the bar should read as full, not divide by zero or grow forever off one
person's play session length. Balance numbers themselves
(`shared/progression.json`: `max_level: 20`, `xp_base: 20`, `xp_growth: 1.2`,
`level_bonus_pct: 10.0`) are a first-pass placeholder, tunable later purely as
a data edit (ADR 0005) — not something this ADR claims to have play-tested.

**The per-level bonus is one more contribution Dictionary, appended
alongside equipment.** `ProgressionCurve.bonus_contribution(level)` returns
`{attack_speed_pct, cast_speed_pct, max_health_pct}`, all three carrying the
same value; `Player._recompose_stats()` appends this Dictionary to the same
`contributions` array it already builds from equipped items and passes the
whole array to `PlayerStats.compose` unchanged — no new stat path, no
special-cased "level" branch in the composition function. This was the
"designated hook": G2 added `cast_speed`/`attack_speed_pct` to `PlayerStats`
specifically so this slotted in as a second contribution source.

**Compounding: the contribution itself carries the compounded percentage,
because the composition rule sums-then-scales-once.** `PlayerStats.compose`'s
existing rule for `attack_speed`/`cast_speed` (and now `max_health`, this
ticket's third addition to that rule) is "every contribution's `_pct` value
sums across the whole array, then the base is scaled by `(1 + total_pct/100)`
exactly once" — additive-percent stacking, chosen back in ADR 0011 so two item
affixes on the same stat add rather than compound with each other.  The
ticket wants a level's own progression to compound multiplicatively
(`x1.1^level`), which is a different rule than "sum with everything else,
scale once." Squaring the two: `bonus_contribution` does the compounding
*before* handing the number to `compose`, contributing
`pct = (1 + level_bonus_pct/100)^(level-1) - 1` (as a percentage) as a single
value. Composed alone (the common case — no item affix touches these three
keys yet), `compose`'s one multiply reproduces `base * 1.1^(level-1)` exactly:
multiplicative compounding achieved through an additive-percent pipeline,
because there is exactly one contribution supplying that percentage.

The documented deviation: `shared/items.json` already has an
`attack_speed_pct` affix (no equivalent for `cast_speed_pct`/`max_health_pct`
yet, per G2's own note that no item populates those). If a player equips such
an item, its percentage and the level's compounded percentage **sum before
the single scale-once multiply** — same as any two item affixes on the same
stat always have (ADR 0011) — rather than the item's bonus compounding with
the level's `1.1^level` as two separate multiplications. Concretely: level 3
alone gives `base * 1.21` (`(1.1^2 - 1) * 100 = 21%` summed, one multiply). A
+15% attack-speed affix on top gives `base * (1 + (21 + 15)/100) = base *
1.36`, not `base * 1.21 * 1.15 = base * 1.3915`. The two numbers are close but
not identical — accepted rather than reworked, because forking `compose` to
treat the level bonus as a separate multiplicative pass would special-case
exactly one contribution source in a function ADR 0011 deliberately kept
uniform, for a difference that only shows up once gear starts rolling those
specific affixes (none does yet for `cast_speed_pct`/`max_health_pct`, and
`attack_speed_pct` gear is still rare loot). If this divergence ever matters
for real balance, the fix is to make `compose` multiply distinct *sources*
(equipment vs. level) rather than sum all percentages flat — a bigger,
separately-justified change to ADR 0011's rule, not something to sneak in
here.

**`max_health` joins `PlayerStats.compose`'s output for the first time.**
Composition previously never touched `max_health` at all — M3's comment on
`Player._ready()` said health "stays on the base maximum: no health affixes
exist." G3 is the first thing that changes it, via the same
"percentages sum, then scale once, round to the nearest integer" rule as
`attack_speed`/`cast_speed`.

**Level-up heals to full — the classic ARPG choice — but only a level-up
heals; a bare recompose never does.** `Player._recompose_stats()` always syncs
`_health.max_health` to whatever `_config.max_health` comes out to after
composing, and clamps `current` *down* if the new max is lower than the old
one (a hedge against a hypothetical future negative `max_health_pct`
contribution, not a real case today) — but it never raises `current`. Healing
to the new max is `gain_xp`'s job alone: when accumulated XP crosses a level
threshold, it recomposes (so the new level's bonus, including the higher
max health, is already live) and *then* explicitly sets
`current = max_health`. This split matters: equipment changes already call
`_recompose_stats()` on every equip/unequip, and no item affix touches
`max_health_pct` yet — but if one ever does, an equip/unequip recompose must
not silently full-heal the player as a side effect of gear swapping. Baking
the heal into `_recompose_stats()` itself (heal whenever max_health changes,
for any reason) would have created exactly that landmine; keeping the heal
explicit in `gain_xp`'s level-up branch avoids it by construction.

**Save: `schema_version` 3, a step-by-step migration, `progress.monsters_killed`
untouched.** `player.level` and `player.xp` join the envelope;
`SaveData._migrate_v2_to_v3` defaults a pre-G3 save (no `level`/`xp` at all)
to level 1, XP 0 — a returning player restarts the curve from the bottom,
same "never fail on missing data" discipline every prior migration step
followed. `Player.load_state` restores `_level`/`_xp` from the save *before*
its first recompose, then recomposes (so the restored level's max-health bonus
is already the ceiling the saved `health` value gets clamped against) rather
than clamping first against the level-1 default and only then discovering the
real ceiling — reversing that order would have silently capped a higher-level
save's health at the wrong number on load.

**UI: a bottom-of-screen bar, the same "dumb view + one signal" idiom as
`InventoryPanel`.** `XPBar` (`game/scenes/ui/xp_bar.gd`/`.tscn`) holds no
progression state; every redraw reads `Player.xp_progress()`/`Player.level()`
fresh, triggered by a new `Player.xp_changed` signal emitted from `gain_xp`
(every call, level-up or not, so the bar's fill always tracks the latest XP)
and from `load_state` (so a loaded save's level/XP show immediately, not just
after the first kill). No mouse/touch interaction, per the ticket — unlike
`InventoryPanel`/`SaveUI`, this panel has no buttons to consume clicks.

## Consequences

- `Monster.xp_reward()` is a one-line getter alongside the existing
  `monster_id()` (same `_data` Dictionary, no new plumbing); `main.gd`'s
  `_on_monster_died` calls `_player.gain_xp(monster.xp_reward())` right next
  to the existing loot-roll call — one more thing that hangs off the same
  `died` signal, not a new wiring path.
- Domain tests (`test_progression_curve.gd`) use a small, self-contained
  progression Dictionary rather than the real `shared/progression.json`
  (same idiom as `test_skill_catalog.gd`'s `SKILLS_DATA`), so retuning the
  real curve later can't break curve-shape unit tests. `test_player_stats.gd`
  covers `max_health_pct`'s sum-then-scale-once rule directly.
  `test_save_data.gd` covers the v2->v3 migration in isolation (mirroring the
  existing v1->v2 test) plus the full v0->v3 chain. A scene test
  (`test_xp_progression.gd`) drives one real kill through the whole path
  (`Monster.died` -> XP -> bar) and, separately, calls `Player.gain_xp`
  directly with the exact XP a fresh `ProgressionCurve` (loaded from the same
  `BalanceData` the game uses) says is required for level 2 — proving the
  level-up recomposes stats (`max_health` increases) and heals to the new
  max, on a player that had just taken damage so the heal is provably not a
  no-op.
- G4 (health bars above player/monsters) should read `Player.max_health()`
  (new getter, mirrors the existing `current_health()`) rather than assuming
  a fixed denominator — it now changes at runtime on every level-up, and a
  health bar built against a cached max will silently under-fill after the
  first level gained mid-run. `Monster` has no equivalent level system and
  its `max_health` never changes post-spawn, so a monster health bar can
  safely read `_data.max_health` once at setup.
