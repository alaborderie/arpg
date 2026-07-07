# 8. Expose shared/ balance data to the client via a symlink into res://

- Status: accepted
- Date: 2026-07-07

## Context

ADR 0005 puts balance data in `shared/*.json` at the repo root, loaded by both the
Godot client and the Go server. But Godot can only see (and only exports) files under
the project root (`res://` = `game/`), and `game/` cannot reach `../shared` in an
exported build. The data must physically appear inside the project.

Options considered: a build-time copy step (breaks "clone, open editor, press play" —
stale copies until you remember to run it), duplicating the files (guaranteed drift),
or a symlink.

## Decision

Commit a **symlink `game/shared` → `../shared`**. Inside Godot the data is read as
`res://shared/*.json` through the small static loader `game/data/balance_data.gd`;
there is exactly one copy of the data on disk and no sync step.

## Consequences

- The editor and headless runs see live data with zero tooling.
- **Windows caveat**: checking out symlinks requires `git config core.symlinks true`
  plus Developer Mode (or an elevated git). Document this in the README if a Windows
  contributor ever shows up; CI and the current dev machines are Linux/macOS.
- Mobile/desktop exports include the JSON because the export step follows the link and
  packs `res://shared/**`. If export presets ever filter non-resource files, add
  `*.json` to the include filters — revisit when M-export arrives.
- `game/data/` (adapters that touch the filesystem) is deliberately *outside*
  `game/domain/` — domain classes stay pure (ADR 0003) and receive data as plain
  Dictionaries/values.
