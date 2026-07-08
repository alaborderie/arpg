# CLAUDE.md

Guidance for working in this repository. Read this before making changes.

## What this is

A top-down action RPG (Diablo 2 / Path of Exile style), deliberately light low-poly
flat-shaded visuals, targeting desktop (Windows/Linux/macOS) and mobile (iOS/Android).
**Offline-first**: fully playable with no connection and local saves. Optional online
features (cloud save sync; later server-side "AI farming") layer on top and must never
be required to play. Not multiplayer today, but choices should not block server
authority later.

## Monorepo layout

| Path       | What                                                                    |
|------------|-------------------------------------------------------------------------|
| `game/`    | The Godot 4.5 project (GDScript). Client.                               |
| `server/`  | The Go backend (own `go.mod`). Optional; the game never requires it.    |
| `shared/`  | JSON balance data + JSON Schemas — the single source of truth for rules.|
| `docs/`    | Architecture Decision Records, one file per decision.                   |

## The three rules (non-negotiable)

These have ADRs; skim them before touching combat, RNG, or balance.

1. **Domain/scene separation** (`docs/0003`). `game/domain/` is pure logic — plain
   GDScript `RefCounted` classes, **no** `Node`, scene tree, input, rendering, or file
   access. `game/scenes/` holds thin Node adapters that call into the domain and hold
   no game rules. A `domain/` class that extends `Node` or calls `get_node()` is a bug.

2. **Determinism** (`docs/0004`). All domain randomness goes through the injected
   `RngService` (`game/domain/rng_service.gd`). Same seed + same inputs = same outcome.
   A bare `randi()`/`randf()` in `domain/` is a bug.

3. **Data-driven balance** (`docs/0005`). Monster stats, loot tables, affixes, XP
   curves, and combat constants live in `shared/*.json`, validated by
   `shared/schemas/*`. Both client and server load the same files. Don't hard-code
   balance numbers in GDScript or Go — inject them from data.

## How to run things

Prerequisites: **Go 1.26+**; **Godot 4.5+** for the game; `golangci-lint` and
`check-jsonschema` for the full check suite. All `make` targets run from the repo root
(`make help` lists them).

### The game

Open `game/` in the Godot editor and press Play, or headless:

```sh
godot --path game                 # run the boot scene
godot --headless --path game      # import/boot with no window (used by CI)
```

The main scene (`game/scenes/main/main.tscn`) is a flat test map with box obstacles
under an isometric-angle orthographic camera. **Click (or tap) the ground to walk
there** — pathing goes through the NavigationServer around the obstacles, and the
camera follows. Touch input rides the engine's mouse-from-touch emulation, so the
same input path serves desktop and mobile.

Two Godot-side details worth knowing before editing scenes:

- `game/shared` is a **symlink** to the repo-root `shared/` (ADR 0008); scripts read
  balance data as `res://shared/*.json` through `game/data/balance_data.gd`.
- Navigation meshes bake **at runtime** from static colliders, synchronously plus a
  `map_force_update` (ADR 0009) — never commit baked polygons into a `.tscn`, and
  block movement by adding a `StaticBody3D` + collision shape under the map's
  `NavigationRegion3D`.

### Tests (headless)

```sh
make test-server   # Go: go test -race ./...
make test-game     # Godot domain tests via gdUnit4, headless
make test          # both
make check         # everything CI runs: data validation, lint, both test suites
```

`make test-game` needs Godot + the **gdUnit4** addon installed locally (Godot AssetLib;
the addon is git-ignored, not vendored — see `docs/0007`). It runs:

```sh
godot --headless --path game -s res://addons/gdUnit4/bin/GdUnitCmdTool.gd -a res://tests --ignoreHeadlessMode
```

`game/tests/` splits by kind: `domain/` (pure logic), `data/` (shared-data loading),
and `scenes/` (gdUnit scene-runner integration tests that drive the real engine loop —
navigation and physics work headless).

CI runs the game tests via the gdUnit4 GitHub Action instead (it fetches Godot + the
framework). CI is the source of truth for game-side green.

### The server

```sh
make run-server                    # listens on :8080 (ARPG_ADDR to override)
curl localhost:8080/health         # {"status":"ok","service":"arpg-server"}
make lint-server                   # gofmt check + go vet + golangci-lint
make sqlc-generate                 # regenerate internal/store/sqlcgen after editing db/migrations or db/queries
```

`run-server` opens (and migrates) a SQLite file at `ARPG_DB_PATH` (default
`server/arpg.db`, gitignored). Running the game (`godot --path game`) against
it exercises the M5 online layer end to end: device registration, and
save upload/download on every `save_game` (F5)/boot. With no server running,
the game plays exactly the same - see M5 below.

### Online layer (M5): device auth + cloud save sync

```sh
curl -X POST localhost:8080/v1/auth/device -d '{"device_id":"..."}'
# -> {"device_id": "...", "token": "..."}

curl -X PUT localhost:8080/v1/save -H "Authorization: Bearer <token>" \
  -d '{"schema_version":1,"saved_at_unix":1700000000,"payload":{...}}'
# -> 200 {"schema_version":1,"saved_at_unix":1700000000} or 409 (stale, returns the stored timestamp)

curl localhost:8080/v1/save -H "Authorization: Bearer <token>"
# -> 200 {"schema_version":1,"saved_at_unix":...,"payload":{...}} or 404 (nothing stored yet)
```

`payload` is the client's save envelope (ADR 0012), carried opaquely: the
server compares `saved_at_unix` for last-write-wins and never parses the
blob. See `docs/0013` for the auth-stub shape, the LWW protocol, and why the
client's sync adapter (`game/scenes/sync/sync_service.gd`,
`game/data/sync_store.gd`/`sync_config.gd`) is safe to leave enabled with no
server running.

### AI-farming groundwork (M6): tool schema + deterministic resolver

```sh
curl -X POST localhost:8080/v1/farm/run -H "Authorization: Bearer <token>" \
  -d '{"seed":42,"map_id":"default","max_steps":20}'
# -> 200 {"summary": {"kills":15,"xp_gained":75,"currency_gained":3,"items_kept":[...]},
#         "transcript": [{"tool":"start_map","input":{...},"result":{...}}, ...]}
```

No LLM is called here - there is no API key to configure and this endpoint
makes no network calls. `internal/farming.Service` drives a hard-coded
`ScriptedBrain` (start_map -> set_farm_target -> a few `engage_boss`
batches -> vendor_items -> end_session) through a seeded `Resolver` that
simulates outcomes coarsely from `shared/monsters.json`/`items.json`/
`loot_tables.json` - same seed and tool-call sequence always produce the
same transcript and summary. `internal/farming/tools.go` defines the five
tools' JSON Schemas using the real `anthropic-sdk-go` types
(`anthropic.ToolParam`/`ToolInputSchemaParam`), so a future real
LLM-backed `AgentBrain` (today just a `NewAnthropicBrain(...)` stub
returning "not implemented") passes `farming.ToolUnionParams()` straight
into a `Messages.New` call with no schema rewrite - it would additionally
need an API key, a model choice, its own loop-guard (an LLM agent isn't
guaranteed to call `end_session`), and a decision on persisting runs (M6
persists nothing). Full design and the coarse-simulation approximations in
`docs/0014`.

### Shared data

```sh
make validate-data   # validates shared/*.json against shared/schemas/*
```

## Conventions

- **GDScript**: typed everywhere — typed vars (`var x: int`), typed function
  signatures and returns. Tabs for indentation (Godot standard). Prefer boring,
  idiomatic Godot over clever tricks.
- **Go**: `gofmt`-clean, `go vet`- and `golangci-lint`-clean, table-driven tests.
  Structured logging with `slog`. `internal/` for non-exported packages.
- **Data**: every `shared/*.json` has a `schema_version` and a schema in
  `shared/schemas/`. Bump `schema_version` on breaking shape changes.
- **Saves** (from M4): versioned, self-contained JSON with an explicit
  `schema_version` and a migration path; cloud sync ships these blobs as-is.
- **Server boundaries**: the server never trusts the client for anything of economic
  value once online features exist. Structure routes/services so real auth (M5) and
  the AI-agent runner (M6) slot in without rework.
- **Commits**: small, one concern each, clear messages.
- **ADRs**: when you make a non-obvious technical choice, add `docs/NNNN-title.md`.

## Milestones

- **M0 — Scaffold — DONE.** Repo structure, Godot project booting to an isometric 3D
  scene, `/health` server, `DamageCalculator` domain class + gdUnit4 tests,
  `shared/monsters.json` + schema, CI.
- **M1 — Movement — DONE.** Click/tap-to-move on a flat map with obstacles
  (NavigationServer), camera follow, one input path for mouse and touch,
  `shared/player.json` feeding move speed, scene-runner integration tests.
- **M2 — Combat — DONE.** Click a monster to attack it (walking into range first),
  ground to move. One melee monster (`fallen_imp`, chase/attack AI), health, death
  and hit feedback (Label3D damage numbers + material flash) on both sides. Domain:
  `Health`, `CombatProfiles` (profiles from data Dictionaries). Data: player attack
  stats in `shared/player.json`, mitigation constants in `shared/combat.json`.
  Targeting/wiring choices in `docs/0010`: monster picking raycasts physics layer 2
  on the next physics tick; `main.gd` owns the scene's single RngService/
  DamageCalculator and injects them everywhere.
- **M3 — Loot & inventory — DONE.** Killing a monster rolls its `shared/loot_tables.json`
  entry (`LootRoller`: drop chance, base pick, weighted rarity, affix count/picks —
  fixed draw order, own RNG stream seeded `master_seed + 1` so drops depend only on
  kill order, not on combat-roll consumption) and spawns a `GroundDrop` (physics layer
  3, picked by the same one-ray/additive-mask pattern as monsters). Click (or the
  player's ordered pickup) walks into range and bags the item via `Inventory` (bag +
  equipped-slot Dictionary, swap-equip semantics). Equipping recomposes the player's
  effective stats through `PlayerStats.compose` + `ItemStats.contribution` into the
  same Dictionary shape `CombatProfiles` already consumed (ADR 0010) — gear changes
  numbers, never the pipeline. `InventoryPanel` (toggle key `I`, or a touch button) is
  a dumb view over `Player.inventory()`, redrawn on `inventory_changed`. Data:
  `shared/items.json` (bases + affix pool), `shared/loot_tables.json` (rarities +
  per-monster tables). Design choices — rolled-item shape, two RNG streams, the stat
  composition rules — in `docs/0011`.
- **M4 — Persistence — DONE.** One versioned JSON save envelope (`schema_version`,
  `saved_at_unix`, `master_seed`, both RNG stream states, player health/position,
  `Inventory` bag/equipped, a `monsters_killed` progress counter). Domain:
  `SaveData` (`game/domain/save_data.gd`) shapes/migrates the envelope — pure
  Dictionary in/out, no file access — with a step-by-step `_migrate_v<N>_to_v<N+1>`
  chain (a scaffolded v0→v1 step proves the mechanism), rejecting a save from a
  newer `schema_version` outright. RNG state is stored as a decimal string, not a
  JSON number, because `RandomNumberGenerator.state` is a full 64-bit value and
  Godot's JSON number type is a 53-bit-precision double — a bare-number round trip
  silently truncates it. Adapter: `SaveStore` (`game/data/save_store.gd`) reads/
  writes `user://saves/save.json` via `FileAccess`, following the same
  empty-Dictionary-plus-`push_error` convention as `BalanceData`. To reset a save,
  delete that file (or call `SaveStore.delete()`); the game boots a fresh run if
  it's absent. UX: the `save_game` action (F5) and an on-screen "Save (F5)" button
  (same one-action/two-input-paths idiom as `toggle_inventory`) both save; loading
  happens automatically at boot when a save exists and `rng_seed` wasn't pinned
  (so seeded tests are never overridden by a stray save). Design rationale,
  envelope shape and the RNG-string bug in `docs/0012`.
- **M5 — Online layer — DONE.** Device auth stub (`POST /v1/auth/device`:
  client-generated device id in, opaque bearer token out; idempotent
  re-registration) and cloud save sync (`PUT`/`GET /v1/save`: last-write-wins
  by the save envelope's `saved_at_unix`, payload stored and returned opaquely
  - ADR 0012's blob, never parsed server-side). Server: SQLite via sqlc
  (`server/internal/store`, migration `0002` adds the token + LWW column and
  renames `saves` to `save_records` - see docs/0013 for why), a tiny embedded
  migration runner, `internal/auth`/`internal/saves` services behind a
  `requireDeviceAuth` middleware seam handlers never bypass, table-driven
  tests spinning a real temp SQLite DB (happy path, both LWW-conflict
  directions, wrong/missing token). Client: `SyncService`
  (`game/scenes/sync/`, a `Node` adapter - `HTTPRequest` needs the scene tree)
  registers once, checks for a newer save at boot and applies it live
  (silent last-write-wins), uploads after every local save without blocking
  it; every network failure is logged with `print` (never push_error/
  push_warning) and swallowed, short request timeout, `SyncConfig.enabled`
  kill switch every existing gdUnit scene test flips off so none of them
  depend on network timing. Design rationale, protocol shape and the sqlc
  table-naming pitfall in `docs/0013`.
- **M6 — AI-farming groundwork — DONE.** Deliberately partial: defines the
  tool-call schema an LLM agent would use server-side and a deterministic
  resolver that executes it, without ever calling a real model. Schema:
  five tools (`start_map`, `set_farm_target`, `engage_boss`, `vendor_items`,
  `end_session`) as `anthropic.ToolParam`/`ToolInputSchemaParam` values from
  the official `github.com/anthropics/anthropic-sdk-go` SDK
  (`server/internal/farming/tools.go` - `Definitions()`/`ToolUnionParams()`
  are what a real `Messages.New` call would take unchanged), each with a
  typed Go input/result pair. Seam: `AgentBrain` interface
  (`server/internal/farming/brain.go`), `NextCall(ctx, state, transcript)`;
  `ScriptedBrain` is the one stub implementation (a hard-coded
  start_map -> set_farm_target -> N engage_boss batches -> vendor_items ->
  end_session sequence, chosen purely by call count); `NewAnthropicBrain`
  is a constructor stub that always returns "not implemented" - no network
  calls or API keys anywhere in this package or its tests. Resolver
  (`server/internal/farming/resolver.go`, alongside - not inside -
  `internal/saves`, per ADR 0013): seeded `math/rand/v2` RNG, same seed +
  same tool-call sequence always produces an identical transcript and
  summary; coarse simulation over `shared/monsters.json`/`items.json`/
  `loot_tables.json` (xp = kills × `xp_reward`, loot rolls mirror the
  client's fixed draw order through rarity but skip affixes, vendor pricing
  reuses `loot_tables.json`'s `affix_count_max`) - approximations spelled
  out in `docs/0014`. `LoadData(dir)` loads the real `shared/` files,
  path-configurable (`ARPG_SHARED_DATA_DIR`) so tests load the repo's own
  data. HTTP: `POST /v1/farm/run {seed, map_id?, max_steps?}` behind the
  existing `requireDeviceAuth` (no new auth work, per ADR 0013's guidance),
  returns the run summary and full tool-call transcript; nothing is
  persisted (future work). Design, approximations and what a real
  LLM-backed runner needs next (API key config, model choice, its own
  loop-guard, run persistence) in `docs/0014`.

## Gameplay phase (G-tickets)

- **G1 — Larger map, centered camera, infinite spawning — DONE.** Map is
  200x200 (synchronous bake measured ~0.2 s at the default navmesh cell size —
  under budget, precision unchanged; re-measure if maps grow again). Camera is
  hard-locked to the player (no smoothing lag; ortho size 24). `MonsterSpawner`
  (`game/scenes/world/monster_spawner.gd`) keeps ~10 monsters alive in a
  14–30 m navmesh-snapped ring around the player, picks ids from a **third**
  RNG stream (`master_seed + 2`, deliberately not in the save envelope), and
  despawns ground drops beyond 45 m; monster death → loot flow in `main.gd` is
  unchanged. Scene tests pin the spawner via its exports (`target_population`,
  `forced_monster_id`) set before the scene enters the tree — population 0 for
  a quiet map, 1 + `"fallen_imp"` to preserve swept-seed kill sequences. Any
  new scene test booting `main.tscn` must do the same or expect 10 chasers.
  Design in `docs/0015`.
- **G2 — Skill/spell system, starting choice of 3 — DONE.** 33 skills in
  `shared/skills.json` (physical/fire/cold/lightning/poison, melee or ranged),
  validated by `shared/schemas/skills.schema.json`. On a fresh game (no save),
  `SkillChoiceUI` offers 3 distinct random skills — drawn deterministically by
  `SkillCatalog.offer` from a fourth RNG stream (`master_seed + 3`, not
  persisted — drawn from exactly once, before any save is possible) — and
  pauses the whole tree (`get_tree().paused`) until one is picked; the panel's
  own `process_mode` is `ALWAYS` so it alone keeps taking input. Domain:
  `SkillCatalog.attack_config(skill)` turns a skill into the same
  damage/range/crit/speed fields a weapon already knew how to override in
  `Player._recompose_stats()` — equipment still composes on top unchanged.
  Melee skills swing exactly like the old basic attack; ranged skills fire a
  simple target-locked homing `Projectile` (`game/scenes/combat/`) that
  resolves its hit through the same `DamageCalculator` on impact. Two new
  stats live in `PlayerStats.compose`: `attack_speed` (melee) and `cast_speed`
  (ranged) — G3's per-level bonus hooks in by adding another contribution
  Dictionary to the same array equipment already feeds. Element mapping: the
  seed list's "ice" skills carry `element: "cold"` (renamed in the data, no
  translation layer); `poison` is a new resistance channel on
  `monsters.json`/`monsters.schema.json` (schema_version 2), routed through
  the existing generic mitigation model unchanged. Save: `schema_version` 2,
  `player.skill_id` persists, `_migrate_v1_to_v2` defaults a pre-G2 save to
  `quick_strike` (tuned to match the old hard-coded basic attack exactly, so a
  returning save feels unchanged). Test knob: `starting_skill_id` on
  `main.gd`, same idiom as the spawner's `forced_monster_id` — every scene
  test booting `main.tscn` fresh must pin it or expect the choice screen to
  pause the tree before anything else runs. Design in `docs/0016`.
- **G3 — XP bar, levels, level-up bonuses — DONE.** Killing a monster grants
  its `monsters.json` `xp_reward` (`Monster.xp_reward()` -> `main.gd`'s
  `_on_monster_died` -> `Player.gain_xp`, right alongside the existing loot
  roll). The curve lives in `shared/progression.json`
  (`max_level`/`xp_base`/`xp_growth`/`level_bonus_pct`), validated by
  `shared/schemas/progression.schema.json`; `ProgressionCurve`
  (`game/domain/progression_curve.gd`) precomputes XP thresholds and exposes
  `level_for_total_xp`/`progress_for_total_xp` (for the bar) and
  `bonus_contribution(level)` — one Dictionary
  (`attack_speed_pct`/`cast_speed_pct`/`max_health_pct`, all equal) that
  `Player._recompose_stats()` appends to the same `contributions` array
  equipment already feeds into `PlayerStats.compose` (G2's designated hook).
  The contribution's percentage is pre-compounded
  (`(1 + level_bonus_pct/100)^(level-1) - 1`) so `compose`'s existing
  "sum-then-scale-once" rule reproduces the ticket's `x1.1^level` exactly when
  it's the only contribution touching that stat — `max_health` is new to
  `compose` entirely (G3 is its first contributor). A level-up recomposes
  stats for the new level, then explicitly heals to the new max — the only
  place that heals; a bare equip/unequip recompose only ever clamps `current`
  *down* if `max_health` shrank, never up, so gear swapping can never
  full-heal as a side effect. `XPBar` (`game/scenes/ui/xp_bar.gd`/`.tscn`) is
  a bottom-of-screen, display-only panel — the same "dumb view redrawn on a
  signal" idiom as `InventoryPanel`, wired to a new `Player.xp_changed`
  signal. Save: `schema_version` 3, `player.level`/`player.xp` persist,
  `_migrate_v2_to_v3` defaults a pre-G3 save to level 1 / 0 XP (keeping its
  `monsters_killed`). `Player.max_health()` is a new getter (mirrors
  `current_health()`) — G4's health bars should read it live rather than
  caching a denominator, since it now changes at runtime on every level-up.
  Design, the compounding-vs-additive-percent deviation, and the heal
  decision in `docs/0017`.
- **G4 — Health bars above player and monsters — DONE.** `HealthBar3D`
  (`game/scenes/fx/health_bar.gd`) is a small world-space bar — two stacked
  billboard `QuadMesh` quads (dark background + colored fill scaled by health
  fraction), built procedurally in `_ready` the same way `CombatFx` builds its
  floating damage-number `Label3D`s — cheap with ~10+ live monsters (setup-time
  cost only; `set_fraction()` is the sole per-hit/heal work, no `_process`, no
  polling). Both quads use `BILLBOARD_ENABLED`, not `FIXED_Y`: the isometric
  rig's fixed 50-degree pitch (`CameraRig.PITCH_DEGREES`) would present a
  `FIXED_Y` (yaw-only) quad as a foreshortened sliver, while full billboarding
  squares it onto the camera like the existing damage numbers. `Player` and
  `Monster` each own one bar (green vs. red fill), positioned above the head
  (`HEALTH_BAR_HEIGHT` on each scene script) and refreshed through a new
  `health_changed` signal on both (same "signal + dumb redraw" idiom as
  `xp_changed`/`inventory_changed`) hooked into `take_hit`, `_recompose_stats`,
  and `gain_xp`'s level-up heal — never polled in `_process`. The player's bar
  reads `Player.max_health()` live every update (G3's handoff: it changes at
  runtime on level-up); a monster's `max_health` is read the same way for
  consistency, though it never actually changes post-spawn so caching it would
  be equally correct. Death: a monster's bar empties one frame before
  `queue_free()` frees it along with the corpse (no dangling bar, no despawn
  errors); the player's bar simply empties and stays empty (the player node
  itself is never freed). No ADR — a straightforward billboard-quad bar was
  judged not to need one; the design notes above live as doc-comments on
  `HealthBar3D` itself.
- **G5 — Low-poly visual pass: character, monsters, terrain — DONE.**
  Replaces the placeholder capsule/box meshes, procedurally (docs/0018 covers
  why, over downloading CC0 assets — no CREDITS.md, nothing was downloaded).
  `Player` (`game/scenes/player/player.tscn`) is five stacked `BoxMesh`es
  (legs/torso/arms/head) under a `Body` `Node3D`, authored directly in the
  `.tscn` since only one look is ever needed; "Nose" is unchanged as the
  facing indicator. `Monster` (`game/scenes/monster/monster.gd`) builds its
  silhouette at runtime instead — `_build_visual(id)`, called from `setup()`
  once `monster_id` is known — because `fallen_imp` (squat, horned, solid
  red, ~1.22 m) and `cinder_wraith` (tall, hooded, ember-glow, ~1.49 m,
  narrower) need to read as visually distinct creatures, which one static
  `.tscn` shared by both ids never could. **Adding a new monster's look**:
  add a `_build_<id>()` method (using the shared `_add_box_part(size, offset,
  color, rotation_degrees)` primitive) and one more case in `_build_visual`'s
  `match id:` — an unrecognized id falls back to the `fallen_imp` shape
  rather than rendering invisible. Both entities keep every non-visual
  contract: collision capsules and nav footprints are untouched (visual
  swap only), the -Z facing convention holds, and `CombatFx.flash_all` (an
  array-looped `flash()`, additive — the original single-mesh `flash()` is
  unchanged) flashes every body part on a hit so a multi-mesh silhouette
  reads as one hit, not one lit-up limb. `Monster.HEALTH_BAR_HEIGHT` moved
  1.6 -> 1.8 to clear `cinder_wraith`'s taller hood with the same ~0.3 m
  margin the old shared capsule had. Terrain: `test_map.gd` scatters 16
  large tinted `PlaneMesh` ground patches (dry grass/moss/sand/dark-rock
  variants) and, via a 10x10 grid of candidate cells, rocks/trees/ruins
  (`game/scenes/world/props/*.tscn` — `StaticBody3D` + one box collider
  each, the same pattern the hand-placed walls/pillars use, so the runtime
  navmesh bake picks them up per ADR 0009) or decorative pebbles (no
  collider), all placed by a fixed sine-hash of an index (`_hash01`, not
  `randf()`/`randi()` — reproducible cosmetics, no RNG stream spent). A 12 m
  safe zone around the origin (the player's spawn point) stays clear.
  Re-measured bake time with the added colliders: ~165 ms for 62 scattered
  props + 16 patches, still well under G1's ~1 s budget.
  Scattered obstacles do lengthen a forced monster's worst-case path to the
  player, so `test_loot.gd`'s chase timeout grew 900 -> 2400 frames, the
  same bump `test_combat.gd` got in G1 for the same reason (docs/0015) — any
  new scene test fighting a forced monster from a cold start should use a
  similarly generous polling timeout.
- **G6 — Free-aim casting: Q casts at the mouse cursor — DONE.** `cast_primary`
  (Q, physical keycode 81) casts the equipped skill instantly from wherever
  the player stands, aimed at the mouse's ground-plane point — no target
  lock, no walk-into-range, click behavior unchanged. `Player.cast_at(aim_point:
  Vector3)` is the whole seam: main.gd's Q handler and every scene test call
  it directly (gdUnit warns injected `InputEvent`s don't transport headless).
  It gates on the same cooldown as the auto-attack (a press while on cooldown
  does nothing, not even the facing turn), then a private `_cast(aim_direction)`
  core fans out to ranged or melee — the hook G8 (support modifiers, which
  change what feeds `_attack`/`_attack_range` upstream) and G9 (W/E slots,
  which would call the same `_cast` with a different skill's fields) both
  build on without touching cooldown/facing. Ranged fires `Projectile` in a
  new `Mode.DIRECTIONAL` (constant velocity along a fixed direction, up to
  the skill's range, then despawns) alongside G2's original `Mode.HOMING`;
  every tick it sweeps a new `"monsters"` Godot group for the nearest live
  one within `HIT_RADIUS` (0.5 m) and resolves the hit if found — a monster
  near the aim point is caught "for free" by this sweep, no separate homing
  needed. Melee resolves instantly against every live monster in the
  `"monsters"` group within skill range and a 90° forward arc centered on the
  aim direction. Both modes share `Player._resolve_hit_on` (build defense,
  run the same `DamageCalculator`, call `Monster.take_hit`) with the
  click-order path, so death still routes through the unchanged
  `Monster.take_hit -> died` chain. Touch has no Q equivalent yet (desktop-
  first aiming, per the ticket); movement/pickup/click stay fully
  touch-playable. Design in `docs/0019`. Design rationale (why procedural over
  downloaded assets, the per-monster silhouette numbers, the bake
  re-measurement) in docs/0018.
- **G7 — Spawner: half population + elite monsters — DONE.**
  `MonsterSpawner.DEFAULT_TARGET_POPULATION` 10 -> 5. Each spawn gets a 1-in-10
  `MonsterSpawnPicker.roll_is_elite` draw riding the existing spawn stream
  (`master_seed + 2`); `MonsterSpawner.forced_elite` (-1/0/1) mirrors
  `forced_monster_id`'s "skip the draw, don't override the result" test-knob
  idiom - every scene test pinning a swept-seed kill sequence now also pins
  `forced_elite = 0`. An elite is ~1.6x visual scale (health bar height scales
  with it), 0.6x move speed, 3x max health, 3x XP - multipliers live in
  `shared/combat.json`'s new `elite` block (schema_version 2), applied by
  `Monster.setup()`'s new `is_elite`/`elite_config` params, never decided by
  it. Nav agent radius/collision capsule stay unchanged (visual-only, same
  precedent as G5's `cinder_wraith`). Loot bias: `shared/loot_tables.json`
  rarities gained `elite_weight` (schema_version 2) - `LootRoller.roll_drop`'s
  existing weighted rarity draw reads that column instead of `weight` for an
  elite kill, so an elite kill's RNG draw sequence is identical in shape to a
  normal one (no save/replay-breaking reorder). Design in `docs/0020`.
- **G8 — Support spells: level-up picks that modify your skills — DONE.**
  On most level-ups the player picks 1 of 3 **support spells** — global
  passives from `shared/supports.json` (12 entries, validated by
  `shared/schemas/supports.schema.json`) that apply to whichever skill is
  equipped. Two mechanical families, both routed through
  `SupportCatalog.contribution_for_owned` (`game/domain/support_catalog.gd`,
  mirrors `SkillCatalog`) into the same `contributions` array equipment/level
  already feed: **stat** supports (`increased_damage`,
  `increased_attack_cast_speed`, four `added_flat_<element>_damage`,
  `increased_crit_chance`, `increased_crit_multiplier`, `increased_range`,
  `faster_projectiles`, `life_on_kill`) extend `PlayerStats.compose` with six
  new contribution keys (turns out `attack_range`/`projectile_speed` *are*
  reachable through composition after all — see docs/0021); **pipeline**
  (`added_projectiles`) is read directly off the composed config by
  `Player._fire_projectile`/`_fire_projectile_directional`, fanning out N
  projectiles in both homing and directional cast modes (melee is a
  documented no-op). `added_flat_<element>_damage` only applies when the
  equipped skill's own element matches — the pipeline resolves one damage
  type per hit, a documented simplification. Chain/multistrike are
  deliberately skipped (not cheap enough given the current projectile
  design) — docs/0021 explains why. Offers draw from a fifth RNG stream
  (`master_seed + 4`), and — unlike G2's one-shot skill-offer stream — this
  one's state **is** persisted (`supports_offer_rng_state`) since it's drawn
  from throughout the whole run, not exhausted before a save is possible.
  Duplicates are allowed and stack additively (a deliberate "your call"
  choice, documented). Level-up flow: `Player.gain_xp` emits `level_up(level)`
  once per level crossed; `main.gd._level_up_reward(level)` is the **entire**
  reserved-levels seam G9 claims — it returns early for level 10/20 (and for
  the `skip_support_offers` test knob) today, and is the one function G9
  edits to dispatch its own skill-unlock UI there instead, with nothing else
  in the level-up path needing to change. A big XP grant crossing several
  levels queues one offer at a time (`_pending_support_offers`) rather than
  stacking pick screens. `SupportChoiceUI` (`game/scenes/ui/`) is
  `SkillChoiceUI` copied almost verbatim (same pause idiom, card shape).
  Test knob: `main.gd`'s `skip_support_offers` (same idiom as
  `starting_skill_id`/`forced_elite`) — every existing scene test that can
  cross a level threshold for a reason unrelated to G8 pins it true;
  `Player.add_support(id)` is the direct seam for a scene test to grant a
  specific support deterministically without driving the RNG offer/UI. Save:
  `schema_version` 4, `player.supports` (`Array[String]`, duplicates
  preserved), `_migrate_v3_to_v4` defaults a pre-G8 save to no supports
  owned. Design in `docs/0021`.
- **G9 — Multi-skill slots: W at level 10, E at level 20 — DONE.** Three
  independent skill slots — Q (slot 0, from the start), W (slot 1, unlocked
  at level 10), E (slot 2, level 20) — each free-aim-casting its own skill
  on its OWN cooldown; supports and gear still apply to every slot (G8 made
  them global). `SkillSlots` (`game/domain/skill_slots.gd`) is the pure
  unlock rule both `Player` and `main.gd` consult. `Player._recompose_stats`
  now composes the same shared `contributions` (equipment + level + supports)
  once per slot against that slot's own skill overlay; `Player.cast_at(point,
  slot: int = 0)` (default 0 keeps every pre-G9 call site — Q's own handler,
  every existing scene test — unchanged) fans into the same `_cast`/
  `_resolve_hit_on` core, now slotted. Reaching level 10/20 offers a pick-1-
  of-3 SKILL (reusing `SkillChoiceUI`/`SkillCatalog.offer`, which grew an
  `excluding` param so the offer never repeats a skill already in another
  slot) instead of a support — G8's reserved seam,
  `main.gd._level_up_reward`'s `level == 10 or level == 20` branch, is the
  only place edited to claim them. Reward queue (G8's `_pending_support_offers`)
  generalized to `_pending_rewards`, a queue of EITHER `{"kind": "support"}`
  or `{"kind": "skill", "slot": int}` entries in level-crossed order, so a
  big XP grant mixing reward types still resolves one screen at a time.
  Offers draw from a sixth RNG stream (`master_seed + 5`), persisted like
  the support-offer stream (docs/0021's identical reasoning: drawn from after
  saves exist). Retroactive-unlock policy: a save whose level already passed
  10/20 without a pick (old save, or a save at `max_level` that will never
  level up again) gets that pick queued immediately on load, not deferred to
  a next level-up that might never come. HUD: `SkillSlotsHUD` — 3 small boxes
  by the XP bar showing name/element or "Lv N" (locked), dimmed while
  cooling — the one dumb-view in this project that polls every frame instead
  of redrawing on a signal (no discrete "cooldown changed" event exists).
  Save: `schema_version` 5, `player.secondary_skill_id`/`tertiary_skill_id`
  (`""` = not yet picked), `_migrate_v4_to_v5` defaults a pre-G9 save to both
  empty. `project.godot` gained `cast_secondary` (W, keycode 87)/`cast_tertiary`
  (E, keycode 69). Design in `docs/0022`.
- **G10 — Fix: free-aim projectiles whiff moving monsters; ranged feels
  weak — DONE.** First human playtest bug (issue #17). `Player` gained
  **aim assist**: at cast time (not per-tick in `Projectile`),
  `_find_aim_assist_target` looks for the live monster whose perpendicular
  distance to the aim ray (caster position along the aim direction, clamped
  to the casting slot's range) is smallest and within
  `AIM_ASSIST_RADIUS` (1.5 m); if found, `_fire_projectile_directional`
  fires `Projectile.setup_homing` on it instead of `setup_directional` — a
  homing shot re-tracks its target every tick and cannot be outrun by the
  target's own movement, unlike a fixed-direction one. A fanned cast (G8's
  `added_projectiles`) only homes its center-most projectile; the rest of
  the fan stays directional. `Projectile.HIT_RADIUS` (the directional
  per-tick sweep's forgiveness, and the homing "arrived" distance) went
  0.5 -> 1.0 m, and `Projectile.SPEED`/`shared/player.json`'s
  `projectile_speed` went 18 -> 28 m/s (one tick at the new speed and this
  project's 60 Hz physics still advances less than half `HIT_RADIUS`, so no
  tunneling). Ten of 33 `shared/skills.json` ranged entries were retuned so
  every ranged skill clears a 7.0 raw-dps floor
  (`(base_min+base_max)/2 * actions_per_second`) — `toxic_volley` (the skill
  the playtest named) got the biggest bump, 5.4 -> 9.0 — while melee's
  average dps keeps a premium over ranged's; a new data test
  (`test_ranged_balance.gd`) guards both. The ticket's reported "sideways
  chase" pathing bug did **not** reproduce under investigation — a
  scene-runner probe of the exact scenario (stationary target, monster 5 m
  out, open ground) showed `Monster`'s chase code (already symmetric with
  `Player`'s own) closing in a dead-straight line at full `move_speed`; a
  regression test (`test_monster_chase_pathing.gd`) locks that verified
  behavior in rather than fixing a defect that wasn't there. Design,
  the aim-assist rule, the full balance table, and the pathing
  investigation's write-up (including the red herring the probe's own setup
  produced first) are in `docs/0023`.
