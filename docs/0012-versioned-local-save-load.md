# 12. Versioned local save/load

- Status: accepted
- Date: 2026-07-08

## Context

M4 needs offline-first persistence: a player's health, position, inventory,
equipment and a minimal progress marker must survive quitting and relaunching,
and the RNG streams (ADR 0004/0011) must resume so a reloaded session keeps
rolling loot/combat deterministically instead of restarting them. M5 will ship
these same blobs to a server as-is for cloud sync, so the shape has to be
self-contained JSON, not something that depends on engine session state — and
because the shape will inevitably change over a game's life, it needs a
migration story from day one rather than bolting one on when the first
breaking change actually happens.

## Decision

**One versioned JSON envelope, migrated forward at load.** `SaveData`
(`game/domain/save_data.gd`) is a pure domain class (ADR 0003 — Dictionary
in/out, no `FileAccess`) that shapes and reads the envelope:

```
{ "schema_version": 1,
  "saved_at_unix": 1700000000,
  "master_seed": 43,
  "combat_rng_state": "7952383842509584290",
  "loot_rng_state": "-6871234509876543210",
  "player": {
    "health": 85,
    "position": {"x": 1.0, "y": 0.0, "z": -2.5},
    "bag": [ /* Inventory.bag(), pickup order */ ],
    "equipped": { "weapon": {...}, "armor": {...} }
  },
  "progress": { "monsters_killed": 1 } }
```

`master_seed` plus the two RNG stream states are exactly what `main.gd` already
owns per-scene (ADR 0011); `bag`/`equipped` are the rolled-item Dictionaries
`Inventory` already stores end to end, so nothing needs a translation layer to
become "the save" — it round-trips as-is, the same property ADR 0011 called out
for the item shape.

**RNG state is a decimal string, not a JSON number.**
`RandomNumberGenerator.state` is a full 64-bit value; Godot's JSON only has a
double-precision number type (53 bits of exact integer mantissa). Storing a
large state as a bare JSON number silently truncates it on the round trip
through `JSON.stringify`/`JSON.parse_string` — the save "works" (no error) but
the restored stream desyncs from the one that was actually saved, so drops and
combat rolls after a reload quietly diverge from what the same seed would have
produced uninterrupted. This was caught by the scene integration test (below)
failing on a second, post-reload kill that should have rolled a specific item
and instead rolled nothing — formatting the state as `"%d" % state` and parsing
it back with `int(String)` sidesteps JSON's number type entirely and is exact
for the full 64-bit range, positive or negative.

**Migration is a step-by-step chain, not a version switch.** `SaveData.migrate()`
walks a save's `schema_version` forward one `_migrate_v<N>_to_v<N+1>` step at a
time to `CURRENT_SCHEMA_VERSION`, so a save two versions behind still loads
without every step needing to know about every other version. A save whose
`schema_version` is *newer* than `CURRENT_SCHEMA_VERSION` is rejected outright
(empty Dictionary, logged) — this build must never guess at a shape it doesn't
recognize; that failure mode is worse than refusing to load. `_migrate_v0_to_v1`
is a **scaffold**: M4 shipped with `schema_version` 1 from day one, so there is
no real v0 save anywhere, but the step exists and is unit-tested so the
mechanism — and the discipline of "fill in defaults for what the old shape
lacked, never fail on missing data, never edit an old migration once it has
shipped" — is proven before it is ever needed for real.

**Domain vs adapter split.** `SaveData` never touches disk. `SaveStore`
(`game/data/save_store.gd`) is the thin adapter, following the same shape as
`BalanceData` (ADR 0008): one file, `user://saves/save.json`, read/written via
`FileAccess`/`DirAccess`, returning an empty Dictionary and logging with
`push_error` on any failure (missing file, bad JSON, or `SaveData` rejecting
the contents) instead of raising. `SaveStore.load()` calls `SaveData.migrate()`
internally, so callers always get an envelope already at the current schema
version, or nothing.

**UX: one save slot, F5 + a corner button, load-at-boot.** Saving is
one action bound two ways — the `save_game` input action (F5) and an
always-visible "Save (F5)" button in a new `SaveUI` CanvasLayer, the same
one-action/two-input-paths idiom `toggle_inventory` already established for
touch and desktop. Loading happens automatically at boot when a save exists:
`main.gd`'s `_ready()` checks `rng_seed == 0 and SaveStore.has_save()` before
falling back to "randomize a fresh seed" — an explicit non-zero `rng_seed`
(integration tests, and any future "new game" / seed-pinning UI) always wins
over a save on disk, so a test asking for a specific seed is never silently
overridden by whatever happens to be in `user://`. There is no separate "load"
action and no save-slot picker; a single overwritten slot is the boring
default and multiple slots are a straightforward extension of the same
envelope shape later.

**Progress is deliberately just a kill counter.** `main.gd` tracks
`monsters_killed` as the whole "progress" block. Reloading respawns the scene's
usual monster spawns fresh rather than remembering which specific monsters
were alive/dead — per-monster persistence was explicitly out of scope for M4
("keep minimal"), and the counter is enough to prove progress survives a
reload without taking on map/spawn-state serialization now.

## Consequences

- The save blob is entirely self-contained: `master_seed` plus both RNG
  states are enough to keep the *loot and combat sequence* deterministic
  from the save point forward, independent of anything else in the file.
  M5 can upload this Dictionary to the server byte-for-byte; the natural
  last-write-wins key is `saved_at_unix`, which the client already stamps
  with `Time.get_unix_time_from_system()` — the server should trust it only
  as a hint (a client clock can be wrong or adversarial) and fall back to
  server receipt time or a monotonic per-account counter if two saves
  conflict, but for a single-player, single-device use case comparing
  `saved_at_unix` is enough to reject a stale upload.
- Domain unit tests (`game/tests/domain/test_save_data.gd`) cover envelope
  shape, round-trip fidelity, the v0→v1 scaffold's defaulting, rejection of a
  newer `schema_version`, rejection of missing/malformed version fields, and
  the large-RNG-state JSON round trip that caught the string-encoding bug
  above. `game/tests/domain/test_inventory.gd` covers the new
  `equipped_by_slot`/`load_state` wholesale-restore methods. A scene
  integration test (`game/tests/scenes/test_save_load.gd`) drives a full kill
  → loot → equip → hit → save cycle in one seeded `main.tscn` instance, then
  boots a *second*, independent instance that loads the same save and asserts
  health/equipment/bag/progress survived — and, as the strongest proof the RNG
  streams truly resumed rather than restarted, kills a monster in the second
  session and asserts its drop matches the specific item that seed's loot
  stream rolls *second*, which only comes out right if the stream picked up
  exactly where session one left it.
- Per-monster world state (which specific monsters are alive, where drops are
  lying) is not persisted. If a later milestone wants that, it is an additive
  envelope field and a new schema version, not a redesign — the migration
  chain exists for exactly this.
- `game/data/save_store.gd` never runs in CI/tests without cleanup: tests
  delete `user://saves/save.json` in `after_test()` so a failed assertion
  can't leak a stray save into a later, unrelated test run (a real risk, since
  `main.gd`'s load-at-boot means *any* test that boots `main.tscn` without
  pinning `rng_seed` would otherwise pick up whatever the previous test left
  behind).
