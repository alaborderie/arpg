# 10. Click-to-attack targeting and combat wiring

- Status: accepted
- Date: 2026-07-07

## Context

M2 needs one pointer gesture to mean two things: click a monster to attack it,
click ground to walk there. It also needs to decide where combat state lives —
who owns the RNG, who resolves a hit, and how a scene full of Nodes keeps every
balance number in `shared/*.json` (ADR 0005) and every rule in `game/domain/`
(ADR 0003).

## Decision

**Picking.** Monsters carry physics layer 2 (`collision_layer = 3`, so layer 1
still handles body collisions). A click is *queued* in `_unhandled_input` and
resolved on the next physics tick, because `PhysicsDirectSpaceState3D` may only
be queried safely during physics processing. The resolver raycasts with a mask
of layer 2 only — walls and ground can never swallow a monster click — and falls
back to the M1 mathematical ground plane (no colliders needed) for move orders.
One frame of added latency is imperceptible at 60 Hz physics.

**One RNG stream per scene.** `main.gd` (the composition root) creates the
scene's single `RngService` and `DamageCalculator` and injects them into the
player and every spawned monster. All hits, whoever swings, draw from one
reproducible sequence (ADR 0004) — the shape a future save/replay/server
verifier needs, and there is exactly one seed to persist.

**Hit resolution.** The attacker asks the *victim* for its `DefenseProfile`
against the hit's damage type (`defense_profile(incoming)`), runs the shared
calculator, and hands the finished `DamageResult` to `victim.take_hit()`.
Profiles are built per hit by the domain factory `CombatProfiles` from the plain
`shared/*.json` Dictionaries the adapters injected — so M3 equipment only has to
change the underlying data, and scenes never hold a balance number. Global
mitigation constants (armour `K`, caps) moved to `shared/combat.json` as ADR
0005 scheduled.

## Consequences

- Menus/HUD will never leak clicks into the world (`_unhandled_input`), and touch
  rides the same path via mouse emulation.
- Monster spawns sit in the far map corners: `melee_chaser` has no aggro radius
  yet (everything on the test map hunts from spawn), and the distance gives the
  M1 movement tests an uncontested window. An aggro radius is a data-schema
  addition when a milestone needs it.
- Swing timing (cooldown accumulation) lives in the adapters. If a server ever
  needs authoritative attack pacing, that timing moves behind a domain clock —
  contained change, both sides read `attack_speed` from the same JSON today.
