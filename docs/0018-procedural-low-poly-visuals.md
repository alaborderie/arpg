# 18. Procedural low-poly visuals over downloaded CC0 assets

- Status: accepted
- Date: 2026-07-08

## Context

G5 (issue #12) replaces the placeholder capsule/box meshes for the player, the
two monster types, and the terrain with actual low-poly, flat-shaded visuals,
while keeping every non-visual contract intact: collision shapes, nav
footprints, `HEALTH_BAR_HEIGHT`-style constants, the "Nose"/facing-indicator
role (facing must stay readable along -Z), and `CombatFx`'s material-flash hit
feedback. `fallen_imp` and `cinder_wraith` additionally need to read as
visually distinct creatures — today they share one `monster.tscn` with no
per-id visual difference at all.

The ticket named two viable routes: (a) download CC0 asset packs (Kenney) and
import the GLB/GLTF files headless, or (b) build meshes procedurally from
Godot primitives. It asked for a quick feasibility probe on (a) before
committing, with an explicit instruction to fall back to (b) — "done well fully
satisfies the ticket" — if downloads or headless import proved unworkable
within a short time box.

## Decision

**Go procedural (route b).** Network access to kenney.nl and GitHub was
verified working (a plain `curl -I` reached both over HTTPS), so route (a) was
not blocked outright. It was still rejected in favor of (b), for reasons that
outweigh "it might have worked":

- **License verification is per-file, not per-site.** Kenney's packs are
  broadly CC0, but confirming *which specific zip* and *which specific meshes*
  inside it carry that license, then recording an accurate CREDITS.md entry,
  is exactly the kind of judgment call this ticket said not to burn the time
  box on if it "fights" — and reading license text correctly matters more here
  than almost anywhere else in the repo.
- **Headless GLTF import is a new failure surface with no local precedent.**
  Every asset this project has imported so far is authored directly in
  `.tscn`/GDScript. A downloaded mesh needs `--import`, a correct `.import`
  sidecar, and material settings compatible with Forward Mobile (ADR 0002) —
  any mismatch (wrong up-axis, baked-in PBR textures fighting the "no heavy
  textures" constraint, a missing `.import` file breaking CI's fresh checkout)
  is a class of bug this repo has never had to debug before, discovered in an
  unattended loop with no screenshots to sanity-check against.
- **The exact constraints this ticket cares about are easiest to guarantee in
  code.** A procedural mesh can be built with an unambiguous -Z front, sized to
  an exact `HEALTH_BAR_HEIGHT` margin, and reduced to a single flash target
  (see `CombatFx.flash_all`) by construction — a downloaded rigged character
  would need the same guarantees reverse-engineered from an unfamiliar mesh
  hierarchy.
- **Zero size/dependency cost.** No binary assets to keep under the ~10 MB
  budget, no new `.import` files to keep in sync with `.gitignore`, nothing
  that can go stale if Kenney reorganizes a download URL later.

Concretely: the player is a chunky humanoid built from five stacked
`BoxMesh`es (legs/torso/arms/head) under a `Body` `Node3D`, authored directly
in `player.tscn` since only one look is ever needed. Monsters build their
silhouette at runtime instead (`Monster._build_visual`, called from `setup()`):
`fallen_imp` is a squat, horned, solid-red imp (~1.22 m tall); `cinder_wraith`
is a tall, hooded, ember-glow-eyed wraith (~1.49 m tall, a narrower ~0.3 m
cloak vs. the imp's ~0.44 m torso) — distinct in both silhouette and palette,
satisfying the ticket's requirement, and impossible to express as one static
`.tscn` since the id isn't known until after instancing. Every `BoxMesh` is
flat-shaded by construction (hard per-face normals, no smoothing group), so no
new material work was needed to match the project's existing look.

Terrain gets the same treatment: 16 large tinted `PlaneMesh` quads sit a hair
above the ground plane for color variation, and a 10x10 grid of candidate
cells scatters rocks/trees/ruins (`StaticBody3D` + a single box collider each —
"a box approximates a tree fine", per the ticket) or decorative pebbles (no
collider) between them, all via `test_map.gd`'s `_hash01` — a fixed sine-hash
of an integer index, not `randi()`/`randf()`, so the scattered layout is
reproducible without spending an RNG stream (ADR 0004 governs *domain*
gameplay randomness; this is scene-layer set dressing, but there's no reason
for it to vary run to run either).

## Consequences

- **No CREDITS.md.** Nothing was downloaded; there is no external source or
  license to record. If a future visual pass does bring in CC0 assets, that is
  the point to add one.
- **Re-measured bake time.** G1 measured ~225 ms for the 200x200 bake with the
  original hand-placed obstacle set. Adding ~32 more collidable props (rocks/
  trees/ruins; pebbles carry no collider) measured ~165 ms end to end
  (scatter + bake) — still comfortably under the ~1 s budget, and the
  difference from G1's number is machine variance, not a regression.
- **A monster's visual silhouette and its collision capsule are now allowed to
  differ** (`cinder_wraith`'s ~1.49 m hood vs. the shared 1.2 m capsule both
  monster ids still use) — deliberate: the ticket only requires a *visual*
  swap, and both ids sharing one collision shape was already true before this
  ticket. `Monster.HEALTH_BAR_HEIGHT` moved 1.6 -> 1.8 to clear the taller of
  the two silhouettes with the same ~0.3 m margin the old single capsule had.
- **Scattered collidable props lengthen worst-case pathing.** A monster forced
  to spawn behind a freshly-added rock/tree/ruin takes a longer navmesh route
  to reach the player than an obstacle-free map would. `test_loot.gd`'s
  `TIMEOUT_FRAMES` grew 900 -> 2400 (the same bump `test_combat.gd`'s chase
  timeout already got in G1 for an analogous reason — docs/0015). Any future
  scene test that fights a forced monster from a cold start should use a
  similarly generous polling timeout rather than a tight fixed frame count.
- **Extending a monster's look is one `match` arm.** A future third monster id
  just needs a new `_build_<id>()` method and a case in
  `Monster._build_visual`'s `match` — `_add_box_part` is already the shared
  primitive both existing shapes use. An id `_build_visual` doesn't recognize
  falls back to the `fallen_imp` shape rather than rendering invisible.
- **CombatFx.flash_all is additive.** The original single-mesh `flash()` is
  unchanged and still used by `Projectile`/`GroundDrop` if they ever want a
  hit flash; multi-part bodies (`Player`, `Monster`) call the new
  `flash_all(parts)` instead, which is exactly `flash()` looped over an array.
