# 14. AI-farming groundwork: tool-call schema, deterministic resolver, stubbed LLM

- Status: accepted
- Date: 2026-07-08

## Context

M6 is explicitly *groundwork*, not the real feature: define the tool-call
schema an LLM agent would use to play the game server-side (an "AI farms
your gear while you're offline" style loop), and build a deterministic
resolver that can execute those tool calls against `shared/*.json` balance
data - without ever making a real model call. No API keys, no network
access, anywhere in this package or its tests.

Two prior ADRs shape the decisions below. ADR 0005 makes `shared/*.json` the
single source of balance truth both the Godot client and the Go server must
load identically - the resolver has to reuse those files, not duplicate
numbers. ADR 0013 (M5's device-auth stub) explicitly calls out that M6
"should reuse `auth.Service`/`requireDeviceAuth` as-is for identifying which
player a run belongs to, and add its own validated service alongside
`saves`, not fold logic into it" - so the farming package sits next to
`internal/saves`, not inside it, and the HTTP handler is one more route
behind the existing middleware.

## Decision

### Tool-call schema: real SDK types, data-shaped

`server/internal/farming/tools.go` defines five tools - `start_map`,
`set_farm_target`, `engage_boss`, `vendor_items`, `end_session` - as
`anthropic.ToolParam` values from the official Go SDK,
**`github.com/anthropics/anthropic-sdk-go` v1.56.0** (added to
`server/go.mod`; the module path was confirmed against
[pkg.go.dev/github.com/anthropics/anthropic-sdk-go](https://pkg.go.dev/github.com/anthropics/anthropic-sdk-go)
and its own `examples/tools/main.go`). Each definition sets `Name`,
`Description` (`anthropic.String(...)`) and `InputSchema`
(`anthropic.ToolInputSchemaParam{Properties: map[string]any{...}, Required:
[]string{...}}`) - exactly the shape `MessageNewParams.Tools` takes in a
real `client.Messages.New` call. `Definitions() []anthropic.ToolParam` and
`ToolUnionParams() []anthropic.ToolUnionParam` are the two entry points: the
day a real integration exists, it passes `ToolUnionParams()` straight into
`MessageNewParams.Tools` with no schema rewrite.

Every tool also gets a typed Go input/result pair (`StartMapInput`/
`StartMapResult`, ..., `EndSessionInput`/`EndSessionResult`) purely for this
package's own use - decoding a `ToolCall.Input` and encoding a
`ToolResult.Output` without hand-rolled `map[string]any` juggling. These are
plain structs with `json` tags, independent of the anthropic SDK.

`tools_test.go` marshals every definition to JSON and asserts: non-empty
name, non-empty description, `input_schema.type == "object"`, the expected
`properties` keys present, and the expected `required` list - i.e. "inputs
marshal to valid JSON Schema" is a compile-time-adjacent test, not a manual
read-through.

### The AgentBrain seam and its one stub

`server/internal/farming/brain.go` defines:

```go
type AgentBrain interface {
    NextCall(ctx context.Context, state SessionState, transcript []TranscriptStep) (call ToolCall, ok bool, err error)
}
```

`ScriptedBrain` is the **one** implementation the milestone calls for: a
deterministic, hard-coded policy - `start_map` -> `set_farm_target` -> N
`engage_boss` batches (`KillBatches`) -> `vendor_items` -> `end_session` -
chosen purely by `len(transcript)`, never by RNG or resolver state. That is
deliberate: determinism has two independent sources in this design (the
brain's call sequence, and the resolver's seeded RNG), and keeping them
independent means either one can be tested in isolation.

`NewAnthropicBrain(client anthropic.Client, model anthropic.Model)
(AgentBrain, error)` is the constructor stub for the real thing. It always
returns `ErrAnthropicBrainNotImplemented`. Taking the real SDK types as
parameters now, instead of leaving the signature to be invented later,
means the future implementation is additive - fill in the body, wire an API
key, done - rather than a breaking signature change.

### Resolver: seeded RNG, coarse simulation, explicit approximations

`server/internal/farming/resolver.go`'s `Resolver` executes `ToolCall`s
against an in-memory session: `math/rand/v2`'s `PCG` source, seeded
explicitly from the run's `seed` (`rand.NewPCG(0, uint64(seed))`), so two
`Resolver`s built from the same `Data` and seed, fed the identical call
sequence, produce byte-identical `ToolResult.Output` at every step and an
identical final `RunSummary` (`resolver_test.go`'s `TestResolver_
Determinism`, and `service_test.go`'s `TestService_Run_Deterministic` over
the *real* `shared/` files).

`server/internal/farming/data.go`'s `LoadData(dir string)` reads
`monsters.json`, `items.json` and `loot_tables.json` from `dir` - the same
files, unmodified - and indexes them by id. `dir` is path-configurable
deliberately: production resolves it via `config.SharedDataDir`
(`ARPG_SHARED_DATA_DIR`, defaulting to `../shared` - the repo-root
`shared/` from the server's `make run-server` working directory); tests
pass a relative path (`../../../shared`) straight to the real repo
directory, so a shared-data change that this loader can't handle fails
here, not only in the Godot client.

**Coarse approximations, spelled out** (the milestone explicitly asked for
this rather than a full combat simulation):

- **No `shared/maps.json` exists.** `start_map` doesn't restrict monsters by
  map; every map's `available_monster_ids` is the full
  `shared/monsters.json` roster. `map_id` is carried through opaquely. A
  future zone-restricted pool is an additive `Data`/loader change, not a
  resolver redesign.
- **XP is `kill_count * monster.xp_reward`.** No individual combat rounds,
  no player stats, no chance of the player losing a fight - `engage_boss`
  always resolves every requested kill. This is the biggest simplification;
  it is acceptable because M6's job is proving the tool-call/resolver seam
  end to end, not shipping a combat AI.
- **Loot rolls mirror the client's fixed draw order** (drop-chance roll,
  then base-item pick, then rarity - ADR 0011's "outcomes depend only on
  kill order" contract) but stop at rarity: no affix rolls, since M6 only
  needs a *price*, not a fully rolled item.
- **Vendor pricing is `1 + rarity.affix_count_max`** from
  `shared/loot_tables.json` - reusing the same file the rarity roll already
  reads, rather than inventing a separate currency table (a normal item
  sells for 1, a rare for up to 5). It deliberately ignores which specific
  affixes actually rolled.
- **No death/failure state.** A farming session cannot fail a fight or run
  out of resources; `engage_boss` is a pure batch-resolution function of
  `(monster, kill_count, rng_state)`.

Sentinel errors (`ErrSessionNotStarted`, `ErrSessionAlreadyStarted`,
`ErrSessionEnded`, `ErrUnknownMonster`, `ErrUnknownTool`,
`ErrInvalidKillCount`) make the tool-call state machine (must `start_map`
first; nothing after `end_session`; monster ids must exist in `Data`) a
tested contract, not an implicit assumption.

### HTTP surface: one endpoint, no persistence

`POST /v1/farm/run` (`server/internal/httpapi/farm.go`), behind the
existing `requireDeviceAuth` middleware (ADR 0013) - reused exactly as that
ADR recommended, with no changes to the auth package. Request:
`{"seed": int64, "map_id"?: string, "max_steps"?: int}`; response:
`{"summary": {...}, "transcript": [{"tool", "input", "result"}, ...]}`.
`internal/farming.Service.Run` builds a `ScriptedBrain` + `Resolver` and
drives them via a shared `runLoop` (also the reuse point for a future real
brain) for up to `max_steps` tool calls or until `end_session`, whichever
comes first - so a runaway/non-terminating brain can never hang the
request. **No run is persisted** - every call recomputes from scratch. That
is explicitly deferred (see Consequences).

## Determinism guarantees (what is tested)

- `resolver_test.go`: two independently constructed `Resolver`s, same
  fixture `Data` and seed, fed the identical hand-built call sequence,
  produce identical JSON output at every step and an identical `Summary()`.
  A separate test confirms two *different* seeds are free to diverge (RNG
  is actually being consumed, not a no-op).
- `service_test.go`: the same check end to end over the real `shared/`
  files, through `Service.Run` and `ScriptedBrain`, including a `max_steps`
  cutoff before `end_session` is reached.
- `httpapi/farm_test.go`: two HTTP requests with the same seed return
  byte-identical JSON bodies; a missing bearer token is rejected before the
  resolver ever runs.
- No test in `internal/farming` or `internal/httpapi` makes a network call
  or reads an API key - `NewAnthropicBrain` is exercised only for its
  not-implemented error, never invoked against a real client.

## Consequences

- The tool-call schema, the `AgentBrain` seam and the resolver are real,
  tested, and reusable; the actual "LLM plays the game" feature is not
  built. That was the point of this milestone.
- A real Anthropic-backed `AgentBrain` will additionally need: an API key
  (`ANTHROPIC_API_KEY` via env, never committed - `server/internal/config`
  is the natural place, following the `ARPG_*` convention already used for
  `Addr`/`DBPath`/`SharedDataDir`); a model choice; a loop-guard
  independent of `Service`'s `max_steps`, since an LLM agent - unlike
  `ScriptedBrain` - is not guaranteed to call `end_session` on its own and
  needs its own bounded tool-call budget and a defined behavior for what
  happens when it's exhausted without ending cleanly; and a decision on
  whether/how a run's transcript is persisted (today `POST /v1/farm/run`
  recomputes everything per request and stores nothing - a follow-up
  wanting run history is an additive `sqlc` migration plus a
  `farming.Service` change, not a redesign, the same shape M5's schema
  additions took).
- The coarse approximations above (no map-based monster pools, no combat
  failure state, affix-blind vendor pricing) are all additive to fix later:
  each is a `Data`/resolver extension, not a breaking change to the tool
  schema or the HTTP contract.
- `shared/*.json` gained no new files and no schema changes - M6 reads
  `monsters.json`/`items.json`/`loot_tables.json` exactly as M0-M3 already
  validate them, so `make validate-data`/the CI `data` job needed no
  changes.
