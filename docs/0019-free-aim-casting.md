# 19. Free-aim casting: Q casts the equipped skill at the mouse

- Status: accepted
- Date: 2026-07-08

## Context

G6 (issue #13) adds a second way to use the equipped skill: **Q** casts it at
the mouse's ground-plane point, instantly, from wherever the player stands —
even with no monster under the cursor. That is a real departure from every
attack path so far (M2's click-order, G2's ranged skill): both of those walk
into range against a *locked target* first. Free-aim needs an aim point
instead of a target, must work with zero monsters on screen ("free-fire"),
and has to decide how a directional projectile finds something to hit without
a target to track, how a melee swing decides who's "in front of" the player,
and how the seam is shaped so G8 (support modifiers) and G9 (W/E slots) can
build on it without a rewrite.

## Decision

**One new public method is the whole test/input seam: `Player.cast_at(aim_point:
Vector3)`.** `main.gd`'s `cast_primary` (Q) handler projects the mouse onto the
same mathematical ground plane click-to-move already uses (`_project_to_ground`,
factored out of `_resolve_click` so both paths read the mouse identically —
ADR 0010's ground-plane fallback, reused rather than duplicated) and calls
`cast_at` with the result. Unlike a click, this resolves synchronously in
`_unhandled_input` rather than being queued for the next physics tick: the
ground-plane projection is pure math, not a physics-space query, so there is
no reason to defer it. Scene tests call `player.cast_at(point)` directly —
gdUnit's own headless-mode warning says injected `InputEvent`s aren't
reliable there, and `cast_at` *is* the code main.gd's handler calls, so
driving it directly exercises the real path.

`cast_at` does the cooldown check, the dead check, and the facing turn (a
Y-zeroed `look_at`, identical convention to movement facing) before handing
off to a private `_cast(aim_direction)` core that fans out to a ranged or
melee resolution depending on the equipped skill's `kind`. Splitting the
public entry from the core is deliberate scaffolding for later tickets: G9's
W/E slots will call the same `_cast` with a different skill's precomposed
attack/range fields; G8's support modifiers change what feeds
`_recompose_stats` (and therefore `_attack`/`_attack_range`) upstream of this
function entirely, so neither ticket needs to touch `cast_at`'s cooldown/
facing contract. Per the ticket's advisor note, the "one skill" assumption is
never hardcoded deeper than the existing `_skill`/`_skill_kind` fields
`_recompose_stats` already populates — G9 adding more skill slots is an
additive change to *which* Dictionary feeds those fields, not a rewrite of the
cast pipeline.

**Q while on cooldown does nothing at all — not even turning to face the
aim.** The cooldown check runs before the facing turn, matching the ticket's
"no queueing" requirement literally: a cooldown-gated press has zero
observable effect, the same "silently ignored" contract the melee/ranged
auto-attack path already has.

**Ranged: one `Projectile` scene, two modes, instead of forking a second
scene.** G2's projectile was target-locked homing only — no target means no
projectile at all under the old code. Rather than add a whole parallel
`DirectionalProjectile` scene, `Projectile` gained a `Mode` enum:

- `Mode.HOMING` (renamed from G2's only behavior, `setup_homing`): unchanged,
  used by the click-order path (`Player._fire_projectile`).
- `Mode.DIRECTIONAL` (new, `setup_directional`): no target. Travels at the
  same constant `SPEED` along a fixed unit direction, for at most the
  casting skill's range (`_attack_range`), then despawns untouched — this is
  what makes free-fire at empty ground work with zero errors. Every physics
  tick, before advancing, it sweeps the "monsters" group (see below) for the
  *nearest* live monster within `HIT_RADIUS` (0.5 m, the same constant and
  meaning G2's homing arrival check already used — "close enough to land the
  hit") and resolves against it if found. A monster sitting near the aim
  point is naturally caught by this sweep without any separate homing
  logic — the ticket's "homing onto a monster near the aim point is
  acceptable sugar" falls out for free, because the sweep runs along the
  whole flight path, not just at the final aim point. At ~5-10 live monsters
  (ADR 0015's population target) this is a trivial O(n) check per tick, well
  short of needing a physics body or broadphase.

Both modes share `_resolve_hit_on(monster)`: build the victim's defense
profile, run the injected `DamageCalculator`, hand the result to
`Monster.take_hit`, free the projectile. This is "the damage-resolution
core" the ticket asks both modes to share — the *only* code difference
between click-order ranged and Q-cast ranged is how a victim is found, never
how a hit is computed or how death propagates (`Monster.take_hit -> died` is
untouched).

**Melee: an instant arc check against the "monsters" group, no walk-in.**
`_melee_cast(aim_direction)` iterates every node in the new `"monsters"` group
(see below), and for each live one within `_attack_range` *and* within
`CAST_ARC_DEGREES` (90°, so 45° either side of dead-on aim) of the aim
direction, calls the same `_resolve_hit_on` the ranged path and the existing
click-order melee path (`_try_attack`'s non-ranged branch, also refactored
onto `_resolve_hit_on`) both use. A monster within range but at (near) zero
distance is hit regardless of angle — a direction to a point on top of you is
meaningless, and "adjacent monster" should never fail an arc check on a
degenerate vector. 90° was chosen as a reasonably generous "front swing" per
the ticket's own suggested value — wide enough to read as a swing rather than
a laser line, nowhere near the 360° a real cleave AoE might eventually want.
Unlike the ranged path, a melee cast can hit *every* monster in the arc in one
swing (not just the first) — nothing in the ticket restricts it to one
target, and treating it as an instant AoE-in-an-arc is the simplest
"melee swing" model that still shares the same hit-resolution core.

**A new `"monsters"` Godot group, not a container reference.** Both
`Player._melee_cast` and `Projectile._nearest_monster_in_hit_radius` need to
enumerate every live monster, but neither has (or should need) a reference to
`main.tscn`'s `Monsters` container — they're siblings under the same parent,
and reaching across the tree that way would be exactly the kind of coupling
`_unhandled_input`'s "menus never leak clicks" discipline exists to avoid
elsewhere. `Monster._ready()` now calls `add_to_group("monsters")`; both call
sites use `get_tree().get_nodes_in_group("monsters")`. This is scene-layer
wiring only (ADR 0003) — no domain rule reads or writes the group.

**Click behavior is completely unchanged.** `_resolve_click`'s monster-pick,
drop-pick, and move-to-ground branches are untouched; only the ground-plane
projection at the tail was factored into the shared `_project_to_ground`
helper Q-cast also calls. A click still walks into range before an order
resolves; Q never does.

**Touch/mobile caveat.** `cast_primary` is a keyboard action (Q, physical
keycode 81) with no touch equivalent — free-aim casting is desktop-first, as
the ticket calls out explicitly. Touch-only play still boots and remains
fully playable for movement, pickup, and click-to-attack (nothing about that
path changed); it simply has no way to trigger Q-cast until a future ticket
adds a touch aiming affordance (e.g., a virtual joystick + button), which is
out of scope here.

## Consequences

- `Player._try_attack` (the click-order path) now calls `_resolve_hit_on`
  instead of inlining the same three lines — a pure refactor, no behavior
  change, verified by the untouched M2/G2 combat and ranged-skill test
  suites still passing unmodified.
- `Projectile.setup` was renamed to `Projectile.setup_homing` to make the two
  modes symmetric; the only caller was `Player._fire_projectile`, updated in
  the same commit.
- `docs/0016`'s "target-locked homing, no ability to miss" description of
  `Projectile` now only describes `Mode.HOMING`; `Mode.DIRECTIONAL` can miss
  by construction (nothing is ever guaranteed to be near the aim line) —
  that's the intended free-fire behavior, not a regression.
- New scene test suite `game/tests/scenes/test_free_aim_cast.gd`: a ranged
  Q-cast kill along the aim line, a melee Q-cast kill of an adjacent monster,
  free-fire at empty ground (no error, cooldown gates a same-frame second
  cast), and a monster placed off the aim line taking zero damage from a
  directional projectile that flies past and despawns. The last two tests
  pin `target_population = 0` (this game's established "quiet map" test
  knob, ADR 0015) and, for the off-line case, instantiate one `Monster`
  scene by hand at a controlled position — the spawner's ring placement
  can't guarantee "off to the side of a specific aim line," so this is the
  same manual-instantiate escape hatch `test_health_bars.gd`/
  `test_monster_spawner.gd` already use for controlled setups.
- G7 (spawner: half population + 1-in-10 elites) doesn't touch anything this
  ticket added — the "monsters" group membership and Q-cast's group query are
  independent of population size or which ids get spawned, and elites are
  still plain `Monster` instances from the spawner's existing `_spawn_at`.
- G8 (support modifiers) and G9 (W/E slots) both hook in above `_cast`: G8
  changes what `_recompose_stats` feeds into `_attack`/`_attack_range` before
  a cast ever happens; G9 would give `cast_at`'s callers (main.gd's W/E
  handlers) a different skill to look up first, then call into the same
  `_cast` core with that skill's own precomposed fields. Neither needs the
  cooldown/facing/hit-resolution machinery touched.
