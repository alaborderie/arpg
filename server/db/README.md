# Database layer (activates in M4/M5)

This directory holds the SQL that `sqlc` compiles into type-safe Go. It is **not
yet wired into the server binary** — M0 only serves `/health`. It lives here now so
the persistence/cloud-sync milestones drop in without restructuring.

- `migrations/` — schema, one numbered file per change, applied in order.
- `queries/` — named SQL queries; `sqlc generate` turns these into Go functions.
- `../sqlc.yaml` — sqlc config (engine, paths, codegen options).

## Portability rule

We use SQLite now but keep the SQL portable so a later move to Postgres is a config
change plus a migration review, not a rewrite:

- Stick to standard types: `TEXT`, `INTEGER`, `BLOB`, `TIMESTAMP`.
- No SQLite-only pragmas or `AUTOINCREMENT`; generate ids application-side.
- Keep `ON CONFLICT ... DO UPDATE` (supported by both engines) for upserts.

## Regenerating

```sh
cd server && sqlc generate
```
