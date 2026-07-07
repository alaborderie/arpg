# 6. Persistence: SQLite via sqlc with portable SQL

- Status: accepted
- Date: 2026-07-07

## Context

The backend needs storage for cloud saves (M5) and later AI-farming session state
(M6). We want type safety, plain reviewable SQL, a trivial local/dev story, and no
lock-in that would block moving to Postgres if the service grows.

## Decision

Use **SQLite** as the engine, with **`sqlc`** generating type-safe Go from plain SQL:
migrations in `server/db/migrations/` and named queries in `server/db/queries/`.
Keep the SQL **portable** (see `server/db/README.md`): standard column types, no
SQLite-only pragmas, application-generated ids, and upserts via
`ON CONFLICT ... DO UPDATE` (supported by both SQLite and Postgres).

## Consequences

- Zero-dependency local dev and CI; the DB is a file.
- Queries are ordinary SQL, diffable and reviewable; `sqlc` gives compile-time safety
  without an ORM.
- Switching to Postgres later is a `sqlc.yaml` engine change plus a migration review,
  not a rewrite — as long as the portability rules hold. A migration would get its
  own ADR.
- The DB is not compiled into the M0 binary; the scaffolding in `server/db/` and
  `server/sqlc.yaml` activates in M4/M5.
