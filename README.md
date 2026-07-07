# ARPG (working title)

A top-down action RPG — Diablo 2 / Path of Exile style — with deliberately light,
low-poly flat-shaded visuals. **Offline-first**: fully playable with no connection and
local saves; optional cloud sync and (later) server-side AI farming layer on top.

- **Client:** Godot 4.5+ (typed GDScript), Forward Mobile renderer.
- **Backend:** Go + chi + SQLite/sqlc (optional — the game never requires it).
- **Targets:** desktop (Windows/Linux/macOS) and mobile (iOS/Android).

> `arpg` is a placeholder name. Rename freely: it appears in this repo's directory,
> the Godot project name (`game/project.godot`), and the Go module path
> (`server/go.mod`, its imports).

## Layout

```
game/     Godot project (client)
server/   Go backend (optional)
shared/   JSON balance data + JSON Schemas (single source of truth for game rules)
docs/     Architecture Decision Records
```

## Quick start

```sh
# Server
make run-server && curl localhost:8080/health

# Game (needs Godot 4.5+)
godot --path game

# Everything CI runs
make check
```

See **[CLAUDE.md](CLAUDE.md)** for the architecture rules (domain/scene separation,
determinism, data-driven balance), how to run tests headless, and conventions.
Design rationale lives in **[docs/](docs/)**.

## Status

**M0 (scaffold) complete.** Godot project boots to an isometric 3D scene; the server
answers `/health`; `DamageCalculator` has a real formula with passing gdUnit4 tests;
`shared/monsters.json` is schema-validated; CI runs it all. Roadmap M1–M6 in
[CLAUDE.md](CLAUDE.md).
