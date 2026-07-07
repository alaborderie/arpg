# 5. Data-driven balance in `shared/`

- Status: accepted
- Date: 2026-07-07

## Context

The client (Godot) and the server (Go, from M5/M6) must agree exactly on game rules
— monster stats, loot tables, affix pools, XP curves, combat constants. Duplicating
these numbers in GDScript and Go would guarantee drift and subtle desyncs.

## Decision

Balance data lives once, as JSON in `shared/`, validated by JSON Schemas in
`shared/schemas/`. Both the Godot client and the Go server load the same files at
startup. Game logic contains formulas and structure; the *numbers* they operate on
are injected from data (e.g. `AttackProfile`/`DefenseProfile` fields, populated from
JSON). No balance constants are hard-coded in either codebase.

Each data file carries a `schema_version` and is validated in CI against its schema.

## Consequences

- Tuning is a data edit, reviewable on its own, with no code change.
- CI fails fast on malformed or out-of-range data.
- Client and server can't silently disagree on rules that live in `shared/`.
- Cost: some indirection (a formula reads its constants from an injected profile
  rather than a literal). Accepted for the single-source-of-truth guarantee.
- M0 ships `shared/monsters.json`. Combat constants (armour `K`, caps) currently
  travel as profile defaults and move into `shared/combat.json` in M2.
