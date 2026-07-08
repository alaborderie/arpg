# 15. Infinite monster spawning on the larger map

- Status: accepted
- Date: 2026-07-08

## Context

G1 grows the world from a 40x40 test box to 200x200 and replaces the two
fixed monster spawns with an endless supply: the map should feel populated
wherever the player walks, forever, without breaking ADR 0004 determinism,
the loot/kill-order contract (ADR 0011), or the scene tests that were
written against a fixed two-imp roster.

Three questions fall out: where monsters spawn (and how positions stay
valid on the runtime-baked navmesh), where their randomness comes from,
and what happens to the leftovers (corpses' drops) as the player moves on.

## Decision

**A ring around the player, uniform in angle and radius.**
`MonsterSpawner` (`game/scenes/world/monster_spawner.gd`) maintains a
target alive population (default 10) by spawning at
`player + MonsterSpawnPicker.ring_offset(14, 30)` — never closer than 14 m
(no spawns dropping onto the player's head; also outside the old fixed
spawns' "uncontested window" the movement tests rely on), never farther
than 30 m (spawns stay *around* the player rather than scattering across
the 200x200 map). The radius draw is uniform in `[min, max]` — a ring, not
uniform-in-area over the annulus — so spawn distances don't skew outward;
the domain unit test pins the mean. The domain class draws monster id,
angle, radius in a **fixed order** per attempt, the same
determinism-contract documentation `LootRoller` carries.

**Positions are snapped to the navmesh, and validated.** The raw ring
offset goes through `NavigationServer3D.map_get_closest_point`; if the
snapped point ends up inside the minimum radius (the candidate fell off
the map or inside carved geometry and got pulled back toward the player),
the spawner retries, up to 8 attempts per spawn per tick, then gives up
until the next 0.5 s tick. Spawns therefore always sit on walkable mesh —
the spawner scene test asserts both properties. Monsters are placed at
ground height (y 0), like the old fixed spawns; the mesh itself floats
~0.5 above the ground plane.

**Wait for the map, don't guess a delay.** ADR 0009's caveat — the mesh is
unavailable to queries for a beat after load even with a synchronous bake +
`map_force_update` (empirically: the first physics frame still sees an
empty map; the second doesn't) — means an `_ready`-time first spawn
order-dependently sees nothing. The spawner gates on a readiness probe
instead of a frame count: `map_get_closest_point` returns exactly
`Vector3.ZERO` from an unsynced map and never from this map's real mesh
(real answers carry the mesh's ~0.5 y), so one probe query per frame — zero
RNG draws — latches `_map_ready`, and the first refill happens on the first
frame the map answers. Gating *before* consuming randomness is what keeps
the spawn stream deterministic even if the sync ever takes a different
number of frames on some platform.

**A third RNG stream, deliberately not persisted.** `main.gd` seeds
`_spawn_rng = RngService.new(master_seed + 2)` next to combat
(`master_seed`) and loot (`master_seed + 1`). Same reasoning as ADR 0011:
if spawning shared the combat or loot stream, every spawn would shift every
subsequent damage roll or drop, and the loot suite's swept seeds would
break every time spawn timing changed. Unlike those two streams, the spawn
stream's state is **not** in the save envelope: ADR 0012 already decided
per-monster world state is ephemeral (a reload respawns the world fresh),
so persisting the stream position would suggest a reproducibility the
world doesn't have. If a later milestone persists world state, adding the
stream is an additive envelope field + schema bump, exactly the migration
path ADR 0012 built.

**Cleanup is drops-only, distance-gated.** Ground drops farther than 45 m
from the player (comfortably beyond the 30 m spawn ring, so a fresh kill's
drop is never swept immediately) are freed on the spawner tick. Live
monsters are never despawned, wherever they wander — the population cap
bounds their number anyway, and killing distant stragglers off-screen
would silently eat kills. XP/loot flow is untouched: the spawner emits
`monster_spawned`, `main.gd` connects the same `died` handler it always
had, and the death → loot-roll → `GroundDrop` path is unchanged.

**Test knobs instead of test forks.** `target_population` and
`forced_monster_id` are exports set *before* the scene enters the tree
(the `rng_seed` idiom): population 0 gives the movement suite a monster-free
map, population 1 + `"fallen_imp"` gives the combat/loot/save suites the
exact kill sequence their swept seeds (`DROP_SEED`, `SAVE_SEED`) encode. A
forced id skips the monster-id draw entirely — it must not consume from the
spawn stream, or pinning the roster would itself shift spawn positions.

## Consequences

- The 200x200 bake was measured before deciding on precision: ~225 ms
  synchronous at the default `cell_size` (0.25) with the sparse obstacle
  set, well under the ~1 s budget G1 set — so navmesh precision stays at
  the default and the bake stays synchronous (ADR 0009's determinism
  argument keeps applying). Re-measure when maps grow again or obstacle
  counts jump an order of magnitude.
- Population, radii and the monster-id pool are constants in
  `monster_spawner.gd`, not `shared/*.json`. This is deliberately narrow
  (ADR 0005 covers *balance* numbers; spawn pacing is level/encounter
  design the server never re-simulates today) — but if a future milestone
  wants per-zone spawn tables or the server needs to verify spawns, these
  move into a shared file with a schema, and `MONSTER_IDS` should then come
  from `monsters.json` itself rather than being listed twice.
- Scene tests that boot `main.tscn` unconfigured get the full default
  experience: 10 mixed monsters converging on the player within ~5-10 s.
  Any new scene test that needs quiet ground must pin the spawner knobs
  the way the movement suite does.
- The chase timeout in `test_combat.gd` grew (900 → 2400 scene-runner
  frames): spawn distance is now up to 30 m, and headless scene-runner
  frames map to physics ticks through the engine's wall-clock catch-up
  scheduler, not 1:1 — distance costs frames at a machine-dependent rate.
  Polling loops with generous timeouts absorb that; fixed frame counts
  don't.
