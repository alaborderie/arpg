# 23. Aim assist and ranged combat tuning (G10)

- Status: accepted
- Date: 2026-07-08

## Context

G10 (issue #17) is the first *human* playtest bug report, filed after the advisor's
own probes: "I couldn't kill a single monster, I can't see the health bars moving
when hitting them, I think toxic volley deals not enough damage." Three findings
fed the fix list:

1. **Directional projectiles whiff moving monsters.** `Mode.DIRECTIONAL` (docs/0019)
   flies a fixed direction at `Projectile.SPEED` (18 m/s) and only connects if a
   monster is ever within `HIT_RADIUS` (0.5 m) of the flight path. Over a ~0.3-0.5 s
   flight, a chasing monster easily drifts more than 0.5 m laterally out of that
   corridor — the shot visually overlaps the monster and still misses, reading as
   "my hits do nothing."
2. **A reported "sideways chase" pathing complaint** — a monster observed moving
   mostly laterally toward a stationary target on open ground for dozens of ticks
   instead of closing directly.
3. **Ranged skills under-deal.** `toxic_volley` (3-6 dmg @ 1.2/s ≈ 5.4 dps) needs
   ~4.4 s of *connecting* fire to kill a 24 HP `fallen_imp` — sluggish even before
   accounting for (1)'s misses, and ranged baselines generally ran low across the
   33-skill roster.

## Decision

### Aim assist: a cast-time snap, not a per-tick sweep

`Player._find_aim_assist_target(direction, max_distance)` (called once from
`_fire_projectile_directional`, at cast time) looks for the live monster whose
**perpendicular distance to the aim ray** — from the caster's position along the
(already-normalized) aim direction, projected only between 0 and the casting slot's
own range — is smallest, and returns it if that distance is within
`Player.AIM_ASSIST_RADIUS` (1.5 m). A monster behind the caster or beyond the
skill's range never qualifies, even if it happens to sit close to the infinite
line — this is deliberately "on the way to where you're shooting", not "anywhere
near the aim line forever."

If a snap target is found, the cast fires `Projectile.setup_homing` on it instead
of `setup_directional` — the existing G2 homing mode, which re-tracks its target
every tick and therefore *cannot* be outrun by the target's own continued
movement. No target found (true free-fire at empty ground, or every candidate
outside the radius/range) still fires a pure directional shot, so the "flies past
and despawns untouched" behavior docs/0019 established is unchanged.

This is a **cast-time** decision, explicitly not a per-tick re-evaluation inside
`Projectile` itself: the aim-assist rule is about *what the player was aiming at*,
which is a property of the cast, not of the projectile's ongoing flight. `Projectile`
already has its own per-tick nearest-monster sweep for `Mode.DIRECTIONAL` (docs/0019,
unchanged) — that stays as the forgiveness net for a shot that wasn't snapped, wider
now thanks to the `HIT_RADIUS` bump below.

**The fan (G8's `added_projectiles`, docs/0021) keeps working alongside aim assist**:
only the fan's center-most projectile (index `(count - 1) / 2`, integer division —
exact center for an odd count, one step left of center for an even count) is
switched to homing when a target was found; every other projectile in the fan keeps
flying its own fanned direction as plain `Mode.DIRECTIONAL`. Homing every projectile
in the fan onto the same single target was considered and rejected — it would turn
"a small fan" into "N guaranteed hits on one monster," a bigger balance swing than
this ticket asks for. Homing each fan projectile onto a *different* nearby target
(the "or all home if multiple targets available" option the ticket leaves open) was
also rejected for now: it needs a "second-best," "third-best" target ranking this
ticket doesn't otherwise need, for a benefit (spreading a fan across multiple
monsters) that's a bigger scope change than "fix aim assist." One snap target per
cast, applied to the fan's center, is the simplest rule that satisfies "a fan +
aim assist coexist."

A single un-fanned cast (`count == 1`, the common case) is just a fan of one with
a zero offset — it homes exactly when a target was found and flies directional
otherwise, which is the whole free-aim/aim-assist behavior this ticket asks for.

### Forgiving hit sweep: HIT_RADIUS 0.5 → 1.0 m

`Projectile.HIT_RADIUS` (shared by the homing "arrived" check and the directional
per-tick sweep) went from 0.5 to 1.0 m — within the ticket's suggested 1.0-1.2 m
range, and a round number. A per-monster radius (body radius + projectile radius)
was considered and rejected for this pass: every monster capsule in
`monster.tscn` already shares one radius (0.35 m), so a flat constant captures the
same thing today with far less code; revisit if a monster with a meaningfully
different footprint ever ships.

**Tunneling check**: at the new `Projectile.SPEED` (28 m/s, see below) and this
project's unmodified 60 Hz physics tick, one tick advances `28/60 ≈ 0.467 m` —
under half of `HIT_RADIUS` — so the per-tick point-sample sweep still cannot skip
over a monster between two consecutive samples. A segment-distance sweep (checking
the whole tick's travel segment, not just its endpoint) was considered and judged
unnecessary at this margin; revisit if `SPEED` ever approaches roughly `2 *
HIT_RADIUS * 60 ≈ 120 m/s`.

### Faster projectiles: 18 → 28 m/s

`Projectile.SPEED`'s fallback constant and `shared/player.json`'s `projectile_speed`
(the actual source `Player` composes from, per docs/0016/0021) both moved from 18 to
28 m/s — shortening flight time (and therefore how far a moving monster can drift
before impact) on top of the wider hit radius and aim assist above. All three
changes attack the same "moving monster is hard to hit" problem from different
angles; keeping all three is deliberate — any one alone still leaves a rare-but-
visible miss on a fast-strafing monster, and their combination is exactly what
turns "reliable" into "cannot miss when aim assist engages."

### Ranged balance pass

Every one of the 33 `shared/skills.json` entries can be a player's *first* skill —
`SkillCatalog.offer` draws from the whole list (G2, docs/0016), there is no separate
"starter tier" in the data. So the floor applies to every `kind: "ranged"` skill,
not a curated subset: **`(base_min + base_max) / 2 * actions_per_second >= 7.0`**
(un-mitigated, ignoring crit and target resistance/armor — the same simple metric
the tuning below was aimed at, not a simulation of a specific matchup). 7.0 sits
inside the ticket's suggested 7-10 dps starter band; a 24 HP `fallen_imp` at 7.0
"raw" dps dies in ~3.4 s of connecting fire even before crit is counted, landing
inside the ticket's 2.5-3.5 s window.

Ten of the 21 ranged skills sat below 7.0 and were raised (element, `base_min ->
base_min`, `base_max -> base_max`, dps before → after — `actions_per_second`
unchanged for all of these, only the damage roll moved):

| Skill | Element | Before (min-max, dps) | After (min-max, dps) |
|---|---|---|---|
| `icebolt` | cold | 4-6, 6.00 | 5-8, 7.80 |
| `ice_shard` | cold | 5-8, 6.50 | 6-9, 7.50 |
| `chain_lightning` | lightning | 4-7, 6.60 | 5-7, 7.20 |
| `spark` | lightning | 2-4, 6.00 | 3-5, 8.00 |
| `poison_arrow` | poison | 4-7, 6.05 | 5-9, 7.70 |
| `plague_dart` | poison | 3-5, 5.20 | 5-7, 7.80 |
| `toxic_volley` | poison | 3-6, 5.40 | 6-9, 9.00 |
| `blight_bomb` | poison | 7-12, 6.65 | 8-13, 7.35 |
| `needle_spray` | poison | 2-4, 5.40 | 3-6, 8.10 |
| `stone_throw` | physical | 4-6, 6.50 | 5-7, 7.80 |

`toxic_volley` — the skill the playtest report named explicitly — got the biggest
bump (5.4 -> 9.0 dps, comfortably the highest of the raised skills) since it's the
one skill this bug report can directly verify against: at 9.0 raw dps a 24 HP imp
dies in ~2.7 s, squarely inside the ticket's window, and even after `fallen_imp`'s
`-10` poison resistance (clamped to 0% mitigation by `DamageCalculator._mitigation`'s
lower bound — a *negative* resistance can't turn into bonus vulnerability today, so
poison already lands at full value against this monster) the felt improvement should
be unmistakable. The 11 ranged skills already at or above 7.0 (`fireball`,
`flame_burst`, `ember_shot`, `magma_orb`, `frost_spear`, `blizzard_bolt`,
`lightning_arrow`, `shock_pulse`, `thunder_javelin`, `split_arrow`, `power_shot`)
were left untouched.

**Melee keeps its dps premium.** Melee's 12-skill average dps (~8.28) sits above
ranged's 21-skill average after this pass (~7.60) — about a 9% edge — and melee's
best-in-class (`heavy_slash`, 9.9) still beats ranged's best-in-class
(`toxic_volley`, 9.0). This is an average-over-average comparison, not a strict
per-pair one (a few individual ranged skills now sit above a few individual melee
ones, e.g. `venom_slash` at 7.0) — melee takes on-hit risk a free-aim ranged cast
never does, so the *portfolio* should skew toward it, not every single pairing.

**Regression guard**: `game/tests/data/test_ranged_balance.gd` asserts every ranged
skill's raw dps clears the 7.0 floor, and that melee's average dps stays above
ranged's average — both read straight from `shared/skills.json` via `BalanceData`,
so a future data-only tuning pass that drifts back below the floor fails CI
immediately, no scene runner needed.

### Pathing investigation: no defect found

The ticket also asked to investigate a reported "sideways chase" — a monster
observed moving mostly laterally toward a stationary target instead of closing
directly, taking far longer than its `move_speed` implies. `Monster._physics_process`
was compared line-for-line against `Player`'s own (known-good) chase pattern: both
use identical `NavigationAgent3D` bake parameters (`path_desired_distance` /
`target_desired_distance` = 1.0, comfortably above the ~0.5 m navmesh-height gap
that would otherwise stall waypoint advancement, per `player.gd`'s own tuning-
constraint doc comment), and both re-assign `target_position` every physics tick
while out of range — there is no code-level asymmetry between the two.

A scene-runner probe reproduced the report's exact setup — one `fallen_imp` placed
5 m from a stationary `Player` standing at the scene origin, open ground, no
obstacles (inside `test_map.gd`'s 12 m prop-free safe zone, docs/0018) — logging the
monster's position every physics tick. **The monster closed the gap in a dead-
straight line** (zero lateral deviation) at its full `move_speed`, with
`NavigationAgent3D` reporting a valid multi-waypoint path from the very first tick.
No lateral drift, no stall, no defect reproduced.

(The probe's first few runs *did* show the monster frozen solid — but that traced
to the probe's own setup, not the game: it hadn't pinned `starting_skill_id`, so
`main.tscn` booted straight into G2's skill-choice screen and paused the whole
scene tree, `Monster` included, before any chase logic ever ran a single tick. Every
existing scene test already pins this knob for exactly this reason (G2, docs/0016);
the probe just hadn't, and the resulting "frozen monster" was a red herring worth
recording so it doesn't get rediscovered as a false lead later.)

No code change was made to `Monster`'s or `Player`'s movement logic as a result.
`game/tests/scenes/test_monster_chase_pathing.gd` locks the verified straight-line
behavior in as a permanent regression guard (asserting bounded lateral drift and a
close time within a generous multiple of `distance / move_speed`), satisfying the
ticket's "the pathing fix gets a test" ask even though no fix was needed. The
likely explanation for the original report is either a similar probe-setup
artifact on the advisor's side, or a monster genuinely detouring around one of
`test_map.gd`'s scattered props/walls elsewhere on the map — correct navmesh
behavior around a real obstacle, not a bug, and outside a 12 m radius of the
player's spawn where G5's safe zone doesn't apply.

## Consequences

- `Projectile.SPEED` (28) and `HIT_RADIUS` (1.0) changed; `shared/player.json`'s
  `projectile_speed` changed to match (28.0), keeping the fallback constant and the
  data source in sync per docs/0016/0021's existing convention.
- `Player` gained `AIM_ASSIST_RADIUS`, `_find_aim_assist_target`, and a small change
  to `_fire_projectile_directional`'s fan loop to home its center projectile when a
  snap target exists. `_melee_cast`/`_fire_projectile` (the click-order homing path,
  already target-locked and unable to miss) are untouched.
- Ten `shared/skills.json` ranged entries were retuned (table above);
  `schema_version` unchanged (no shape change, values only).
- New tests: `game/tests/data/test_ranged_balance.gd` (dps floor + melee-premium
  guard), two new cases in `game/tests/scenes/test_free_aim_cast.gd` (moving-monster
  aim-assist hit; fan + aim-assist coexistence), and
  `game/tests/scenes/test_monster_chase_pathing.gd` (straight-line chase regression
  guard, no behavior change).
- `docs/0019`'s "Neither mode has ... a `HIT_RADIUS`" description and its stated
  0.5 m value are superseded by this doc for the current numbers; docs/0019's
  design rationale (why two modes, one scene; the per-tick directional sweep)
  still holds unchanged.
