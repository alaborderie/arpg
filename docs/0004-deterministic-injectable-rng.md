# 4. Deterministic, injectable RNG

- Status: accepted
- Date: 2026-07-07

## Context

An ARPG is saturated with randomness (damage rolls, crits, loot, map layout). If
that randomness is non-reproducible we can't write reliable tests, can't reproduce
bug reports, and can't have a server re-simulate or verify a run — which the M6 AI
farming feature and any future server authority both require.

## Decision

All randomness in the domain flows through a single injectable, seedable service,
`RngService` (`game/domain/rng_service.gd`), which wraps `RandomNumberGenerator`.
Domain classes receive an `RngService` via their constructor and never call the
global `randi()`/`randf()`. Given the same seed and inputs, a domain operation
produces the same result. The RNG's stream position (`get_state`/`set_state`) is
part of the save state so a resumed session continues the same sequence.

## Consequences

- Domain tests seed the RNG and assert exact outcomes or reproducibility.
- Combat, loot, and map generation can later be re-run server-side for verification.
- Discipline required: any new domain randomness must take the injected RNG. A bare
  `randi()`/`randf()` in `domain/` is a review failure.
