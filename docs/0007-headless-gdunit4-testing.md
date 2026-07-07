# 7. Domain testing with gdUnit4, headless in CI

- Status: accepted
- Date: 2026-07-07

## Context

The domain layer (ADR 0003) must be unit-tested, and those tests must run in CI
without a display. We need a Godot-native test framework that supports a headless
CLI runner.

## Decision

Use **gdUnit4** for domain unit tests, under `game/tests/`, run via
`godot --headless`. In CI we use the official **gdUnit4 GitHub Action**
(`MikeSchulze/gdUnit4-action`), which downloads Godot and the framework and runs the
headless runner. The framework is **not vendored** into the repo (it is `.gitignore`d
under `game/addons/gdUnit4/`); locally, install it via the Godot AssetLib.

## Consequences

- Fast, display-less domain tests in CI on every push.
- `make test-game` mirrors the CI command for local runs but requires a local Godot +
  gdUnit4 install.
- This is the one M0 check not verifiable on a machine without Godot; the CI job is
  the source of truth for game-side green. If the action's inputs change across
  versions, the workflow's `with:` block is the thing to reconcile.
