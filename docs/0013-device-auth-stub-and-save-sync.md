# 13. Device-auth stub and cloud-save sync

- Status: accepted
- Date: 2026-07-08

## Context

M5 adds an optional online layer on top of the fully-offline game: a way to
carry a save between devices/reinstalls via the server. Two non-negotiables
from CLAUDE.md and the milestone brief shape every decision below:

1. **Offline-first.** The game must be completely playable, with no errors or
   blocking, when the server is unreachable - which is the *normal* state for
   most sessions, not an edge case.
2. **Server boundary.** The server must never trust the client for anything of
   economic value, and the auth/sync code must be structured so real identity
   (a future milestone) and payload validation can slot in without reshaping
   handlers.

There is no account system yet - no email, no password, nothing to check a
device against except "does this id already exist."

## Decision

### Auth: a device-id stub behind a real seam

`POST /v1/auth/device {"device_id": "<client-generated>"}` returns
`{"device_id", "token"}`. Registration is **idempotent**: re-registering an
id already on file returns the existing token rather than minting a new one,
so a retried registration (dropped response, app relaunch before the token
was persisted) never invalidates a token already in use. The token is 32
bytes of `crypto/rand`, hex-encoded - unguessable, but backed by no identity
claim beyond "you hold this string."

The seam that matters for later: everything downstream of registration talks
to **`auth.Service.Authenticate(ctx, token) -> deviceID`**
(`server/internal/auth/service.go`), invoked from exactly one place -
`requireDeviceAuth` middleware in `server/internal/httpapi/middleware.go`.
Handlers read the resolved device id from the request context
(`deviceIDFromContext`) and never see a token. Replacing the stub with real
auth (password, OAuth, whatever) means changing `auth.Service` and nothing
else - no handler, no route, no save-sync code changes.

### Save sync: last-write-wins over one opaque blob per device

`PUT /v1/save` and `GET /v1/save` carry the client's save envelope
(`game/domain/save_data.gd`, ADR 0012) as an **opaque payload**:

```
PUT  {"schema_version": int, "saved_at_unix": int, "payload": {...envelope...}}
GET  -> {"schema_version": int, "saved_at_unix": int, "payload": {...envelope...}}
```

The server (`server/internal/saves/service.go`) reads only `saved_at_unix`
and `schema_version` for bookkeeping and the LWW comparison; `payload` is
stored and returned as raw bytes, never parsed. This is the client-versioned
envelope's own migration boundary (ADR 0012) staying entirely client-side -
the server doesn't need to know or care what schema version a save is in to
store it.

**Last-write-wins, strictly newer only:** an upload is accepted if
`saved_at_unix` is strictly greater than what's stored (or nothing is stored
yet); otherwise it's rejected with `409` and the stored timestamp, so the
client can fetch the winning copy instead of assuming its local save
"won." Equal timestamps are rejected too (treated as "no new information"),
which means a byte-identical retry of an already-accepted upload also comes
back 409 - an acceptable rough edge for a stub with second-resolution
timestamps and no idempotency key; a real implementation would want one.

One slot (`saves.DefaultSlot = 0`) is used today; the schema's `slot` column
(present since the M4 scaffolding, ADR 0006) is carried forward unused so
multiple save slots is a additive change later, not a redesign - the same
"already-there for the next milestone" shape ADR 0012 used for `progress`.

**Client is not trusted, by design, but only partially enforced today.**
`saved_at_unix` is the client's wall clock - a stub device could lie about it
to force a bogus "newer" save to stick. That's an accepted gap for now (no
economic value exists yet to protect); the handler/service split
(`httpapi` parses the wire format -> `saves.Service` decides accept/reject ->
`store` persists) exists specifically so a later milestone can insert real
validation (e.g., a monotonic server-side counter instead of trusting the
client's clock, or bounds-checking the payload once the server needs to
read it) at exactly one seam, without touching the other two layers.

### Schema: SQLite portable migration, plus one naming lesson

Migration `0002_add_auth_and_save_sync.sql` adds `device_accounts.token`
(unique), renames `saves` to `save_records`, and adds
`save_records.saved_at_unix`. The rename is not cosmetic: `sqlc`'s
inflector treats a bare `saves` table as the irregular `-ves -> -fe` family
(`leaf/leaves`, `wolf/wolves`) and singularizes it to a Go model type named
`Safe`, not `Save`. Renaming the table sidesteps a confusing generated name
rather than fighting the inflector with per-table overrides.

A `//go:embed`-based runner (`server/internal/store/migrate.go`) applies
every `db/migrations/*.sql` file not yet recorded in a `schema_migrations`
table, in filename order - deliberately tiny (one table, no down-migrations,
no checksums) because the portable-SQL rule (`db/README.md`) already keeps
individual migrations simple enough that this is all a single SQLite/
Postgres-shaped backend needs. `sqlc` output (`internal/store/sqlcgen`) is
committed, per ADR 0006 and the milestone brief, since CI does not run
`sqlc generate`.

Non-ASCII characters (an em dash, specifically) in a `db/queries/*.sql`
comment silently corrupted `sqlc`'s generated query text mid-string in
testing - a real, reproducible byte/rune-offset bug in this sqlc version.
The fix was mechanical (ASCII-only in files sqlc reads); flagging it here so
a future contributor hitting garbled generated SQL checks this first instead
of assuming their query is wrong.

### Client: a thin, silent, fire-and-forget adapter

`SyncService` (`game/scenes/sync/sync_service.gd`) is a `Node` - not a
`RefCounted` domain class - because Godot's `HTTPRequest` must live in the
scene tree to run. It is still an adapter in the ADR 0003 sense: no game
rules, just shapes/sends/receives HTTP and defers every decision (what to
apply, what counts as newer) to `SaveData`/plain timestamp comparison.

At boot: get-or-create a persisted device id (`SyncStore`,
`user://sync/credentials.json`), register if no token is stored yet, then
check the server for a save newer than what's on local disk. If one exists,
it is migrated through `SaveData.migrate()` (never trusted blindly - the
same rejection rules apply to a save that arrived over the network as to one
read from disk), written to `user://saves/save.json`, and applied to the
*live* session via a `remote_save_applied` signal `main.gd` already
listens for - reusing the exact same `_apply_loaded_save` path boot-time
loading uses. **Silent last-write-wins, no confirmation dialog**: for a
single-device (today), single-player, stub-auth game, asking the player to
adjudicate a conflict is complexity with no payoff yet; a real multi-device
story would need this to be a prompt (or a merge), not a straight overwrite.

After every local save (`main.gd._save_game`), the envelope is uploaded via
`SyncService.upload_after_save` - called without `await`, so it runs as a
background coroutine and the save action itself never waits on the network.

**Offline tolerance is structural, not a try/catch bolted on**: every network
step funnels through one `_send()` helper that turns every `HTTPRequest`
failure mode (couldn't start, refused, timed out, non-2xx) into a plain
`{"ok": bool, "status": int, "body": Variant}` Dictionary and logs with
`print` - never `push_error`/`push_warning`, which would fail the project's
"boot headless, zero errors/warnings" acceptance bar for what is, offline,
the *expected* outcome. `SyncConfig.REQUEST_TIMEOUT_SEC` (3s) keeps a
misbehaving/unreachable server from hanging the background coroutine
indefinitely; nothing in `_ready`, `_process`, or input handling ever awaits
it directly.

`SyncConfig.enabled` (default `true`) is the kill switch: every existing
gdUnit scene test that boots `main.tscn` (`test_combat.gd`, `test_loot.gd`,
`test_player_movement.gd`, `test_save_load.gd`) sets it `false` in
`before_test()`/restores it in `after_test()` - the same idiom those suites
already use for pinning `rng_seed` to opt out of disk save-loading. This
keeps every existing test hermetic and independent of network timing without
weakening the real boot path, where sync stays on and must still boot clean
with no server running - that combination *is* the offline-first acceptance
test, not a contradiction to relax.

### What is honestly unit-testable without a server

Per the milestone brief, gdUnit never spins up the Go server. What client
code *is* pure and testable headless:

- `SyncStore` device-id generation/persistence and token round-trips
  (`game/tests/data/test_sync_store.gd`).
- `SyncService`'s request-building (`build_register_body`,
  `build_upload_body`) and response-parsing/LWW-comparison
  (`parse_save_response`, `should_apply_remote`) - all declared `static`,
  taking/returning plain Dictionaries/Strings, no `Node`, no network
  (`game/tests/data/test_sync_service.gd`).

The actual HTTP round trip and the LWW protocol's server-side behavior
(happy path, both directions of a stale/newer conflict, wrong/missing token)
are covered by the Go server's table-driven tests
(`server/internal/httpapi/{auth,save}_test.go`), which spin up a real,
migrated, temp-file SQLite database per test - not mocks - so they exercise
the actual last-write-wins SQL, not a stand-in for it.

## Consequences

- A device that never comes back online plays forever with no degradation;
  the only cost of never syncing is never getting a second device's progress.
- The auth stub has a known, accepted hole (a device id is not a proven
  identity, and `saved_at_unix` is a trusted client clock) - acceptable
  because nothing of economic value exists server-side yet. M6's
  AI-farming groundwork (deterministic server-side map-run resolution) is
  the milestone where "the server never trusts the client" starts to bind
  for real; it should reuse `auth.Service`/`requireDeviceAuth` as-is for
  identifying which player a run belongs to, and add its own validated
  service alongside `saves`, not fold logic into it.
- Multiple save slots, a real conflict-resolution UX (instead of silent
  newer-wins), and a non-client-supplied LWW clock are all explicitly
  deferred; the schema and service boundaries were chosen so each is an
  additive change, not a rewrite.
- `server/db/queries/*.sql` (and, this ADR suspects, `db/migrations/*.sql`)
  must stay ASCII-only or risk silently wrong generated code from the sqlc
  version pinned by this repo - worth re-checking on a future `sqlc` upgrade.
