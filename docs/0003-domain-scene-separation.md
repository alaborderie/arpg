# 3. Hexagonal domain/scene separation inside Godot

- Status: accepted
- Date: 2026-07-07

## Context

Game logic tangled into Godot nodes is hard to unit-test, impossible to run outside
the engine, and can't be reused by a server. We want headless tests now and the
option of server authority later (cloud AI farming in M6, possible multiplayer).

## Decision

Split the Godot project into two layers:

- **`game/domain/`** — pure game logic: combat, loot rolling, stat math, map
  generation. Plain GDScript classes extending `RefCounted` (never `Node`). No scene
  tree, input, rendering, or file access. Inputs and outputs are plain data objects.
- **`game/scenes/`** — Nodes/scenes that are *thin adapters*: they read input, drive
  rendering and animation, and call into the domain. They hold no game rules.

Balance numbers the domain needs come from `shared/*.json` (see ADR 0005), not from
constants in either layer.

## Consequences

- The domain runs under `godot --headless` with no scene tree, so it is fast to test
  (see ADR 0007) and, later, portable into a server-side simulation.
- There is some boilerplate: adapters translate between Nodes and domain data
  objects. We accept this as the cost of testability and future server authority.
- Review rule: a `class_name` under `domain/` that `extends Node`, or any
  `get_node`/`randi`/rendering call in `domain/`, is a bug.
