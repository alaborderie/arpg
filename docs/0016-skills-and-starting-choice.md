# 16. Skill/spell system and the starting choice of three

- Status: accepted
- Date: 2026-07-08

## Context

G2 needs the player's attack to come from data instead of being hard-coded:
33 named skills (melee and ranged, five elements' worth of flavor), a
deterministic 3-skill offer on a fresh game, a minimal pause-and-pick UI, gear
that still matters once a skill is active, a simple ranged attack (a
projectile), and a save-compatible persistence story. Several sub-decisions
fall out: how a skill's element maps onto the existing physical/fire/cold/
lightning mitigation model (the seed list calls for "ice" and "poison", neither
of which exist in that model today), how a skill composes with
`PlayerStats`/`CombatProfiles` without forking that pipeline (ADR 0010/0011),
where the offer's randomness comes from (ADR 0004's per-stream discipline),
how "ranged" becomes a real gameplay effect without a physics/animation system,
and how the choice screen freezes the world without a bespoke pause mechanism.

## Decision

**Element mapping: rename "ice" to "cold" in the data, add "poison" as a new
resistance channel.** `shared/skills.json`'s `element` enum is
`physical | fire | cold | lightning | poison` — the seed list's "ice" skills
(`frost_blades`, `icebolt`, `frost_spear`, ...) simply carry `"element": "cold"`
in the data; only their *names* keep the frosty flavor text. This was the
"rename in skills" option the ticket posed, chosen over "map in code" because
it needs zero translation code and keeps `CombatProfiles.damage_type_from_name`
a flat lookup table with no special case. Poison, which had no equivalent
channel at all, gets a new resistance key: `monsters.schema.json`'s
`resistances` object gains a required `poison` field (schema_version 1 -> 2)
and both `monsters.json` entries get one (`fallen_imp: -10`, weak to poison;
`cinder_wraith: 50`, a wraith mostly shrugs it off) — the ticket's preferred
"real schema field" over hacking poison onto an existing channel. `AttackProfile.DamageType`
gained a `POISON` member and `CombatProfiles` a matching name/resistance-key
entry; `DamageCalculator`'s mitigation math needed no changes at all — it
already treats every non-physical type generically via `resistance_pct`. There
is no "none" element: every skill is typed, physical included, so armor always
has something to mitigate.

**A skill replaces the same fields a weapon already knew how to override.**
`SkillCatalog.attack_config(skill)` (`game/domain/skill_catalog.gd`) is a pure
function: it turns a `shared/skills.json` entry into a partial player-config
Dictionary — `damage` (type/base_min/base_max), `attack_range`, `crit_chance`,
`crit_multiplier`, and one speed key (`attack_speed` for a melee skill,
`cast_speed` for a ranged one). `Player._recompose_stats()` merges this over
`_base_config` (the unarmed `shared/player.json` baseline) *before* folding in
equipment contributions exactly as before — so a weapon's implicit damage
still overrides a skill's own damage number if one happens to be equipped,
matching the "gear beats unarmed" precedent this pipeline already had (ADR
0011). This was a deliberate simplification over stripping weapon-damage
contributions when a skill is active: that alternative would have required
`ItemStats` to expose raw `added_damage`/`increased_damage_pct` totals instead
of a computed weapon damage range, which existing M3 tests assert against
directly. Keeping the merge-then-compose shape meant every M1-M4 scene test
kept its exact expected numbers unchanged (see the test-knob note below) at
the cost of: equipping a weapon can still numerically override a skill's
flavor once one is equipped. A follow-up could make certain skills immune to
weapon overrides (e.g. "this is a spell, it ignores your sword"); out of scope
here.

**`PlayerStats.compose` gained a `cast_speed` stat, mirrored from
`attack_speed`.** No item affix produces `cast_speed_pct` yet — this exists so
G3's per-level bonus ("+10% attack speed, +10% cast speed... per level") has
exactly one place to plug in: another contribution Dictionary (e.g.
`{"attack_speed_pct": 10 * level, "cast_speed_pct": 10 * level, ...}`) added to
the same `contributions` array `Player._recompose_stats()` already builds from
equipped items, right alongside them. `attack_speed`/`cast_speed` are the two
stats G3 needs to scale, and this is where they both already live.

**The 3-skill offer is a fourth dedicated RNG stream, drawn from exactly
once.** `main.gd` seeds `_skill_offer_rng = RngService.new(master_seed + 3)`
next to combat (`+0`), loot (`+1`) and spawn (`+2`) — the same "don't perturb
an existing stream" reasoning as ADR 0011/0015.  `SkillCatalog.offer(rng, 3)`
draws three distinct skills without replacement (pop a random index from the
remaining pool, same fixed-order contract `LootRoller._roll_affixes`
documents). Unlike combat/loot, this stream is **not** persisted in the save
envelope: it is drawn from exactly once, before any save could possibly exist
(the world is paused and nothing can trigger a save until a pick resolves), so
by the time a save is ever written the stream's position no longer matters —
the same reasoning ADR 0015 used for not persisting the spawn stream, for a
different reason (there, the state is ephemeral forever; here, it is
exhausted immediately and never touched again).

**The choice screen freezes the world with `SceneTree.paused`, not a custom
gate.** `SkillChoiceUI` (`game/scenes/ui/skill_choice_ui.gd`/`.tscn`) is a
`CanvasLayer` with `process_mode = ALWAYS`; `main.gd` sets
`get_tree().paused = true` while it's showing. Every other node in the scene
keeps its default `PROCESS_MODE_INHERIT` (effectively pausable at the root),
so `Player`/`Monster`/`MonsterSpawner` physics processing — and `main.gd`'s own
click routing — all stop for free; the panel's buttons keep receiving input
because their ancestor chain is `ALWAYS`. Picking a card unpauses and applies
the skill in one step (`_on_skill_chosen`). A fresh game (no save, and no test
pin) is the only path that shows it; a loaded save or the `starting_skill_id`
test knob (see below) applies a skill immediately and never touches
`get_tree().paused` at all — the boot-check's headless run with no save still
completes cleanly paused-and-waiting, which is fine (no error, just no
picker to click).

**Test knob: `starting_skill_id`, same idiom as `MonsterSpawner.forced_monster_id`.**
Every existing scene test that boots `main.tscn` fresh (movement, combat,
loot, spawner, save) now pins `starting_skill_id = "quick_strike"` before the
instance enters the tree — otherwise the choice screen would pause the tree
before any of those suites' movement/combat/timing assumptions ever got to
run. `quick_strike`'s numbers were chosen to exactly match the pre-G2 unarmed
baseline (`shared/player.json`: 4-7 physical, 1.5 attacks/sec, 1.8 m range,
5%/1.5x crit) specifically so every existing test's expected numbers and
timeouts needed zero adjustment. `SaveData.DEFAULT_SKILL_ID` (the pre-G2 save
migration default) is the same id for the same reason: a returning save loads
into something numerically indistinguishable from what the player already had.

**Ranged skills fire a target-locked homing projectile — deliberately the
boring option.** `Projectile` (`game/scenes/combat/projectile.gd`/`.tscn`) is a
plain `Node3D`, no physics body, no collision detection: every physics frame
it steps `SPEED` m/s toward wherever its assigned `Monster` currently is, and
once within `HIT_RADIUS` it resolves the hit through the same
`DamageCalculator`/`DefenseProfile` pipeline melee skills use, then frees
itself. It cannot miss, cannot be dodged, and keeps re-aiming if the target
moves — a real "travels in a straight line and can whiff" projectile is future
work. `Player._fire_projectile()` is the only new branch in `_try_attack()`;
everything else (walk into range first, cooldown gating, defense/mitigation)
is unchanged and shared with melee, because a ranged skill's `attack_range` is
just a bigger number in the same `_attack_range` field the movement code
already handles generically.

**Save: `schema_version` 2, a step-by-step migration.** `player.skill_id`
joins the envelope; `SaveData._migrate_v1_to_v2` defaults a missing/empty
`skill_id` to `DEFAULT_SKILL_ID` (`"quick_strike"`), following the same
"never fail on missing data" discipline `_migrate_v0_to_v1` established.

## Consequences

- `shared/skills.json` (33 entries) and `shared/schemas/skills.schema.json`
  are wired into `make validate-data` and the CI `data` job alongside the
  other four shared files.
- The Go server does not read `shared/skills.json` at all (nothing in
  `internal/farming` needs skill data yet), and `internal/farming.Monster`
  only ever parsed `id`/`name`/`xp_reward`/`max_health` — the new `poison` key
  in `monsters.json`'s `resistances` object is simply an unclaimed field to
  `encoding/json`, so no Go changes were needed for monsters.schema.json's
  bump either.
- Every scene test that boots `main.tscn` unconfigured must now pin
  `starting_skill_id` (this ticket updated every existing one) or expect the
  choice screen to pause the tree before anything else runs — the same
  "pin the new knob or get the full default experience" rule G1 established
  for the spawner.
- G3 (XP/levels: +10% attack speed, +10% cast speed, +10% life per level)
  has one obvious hook: add a per-level contribution Dictionary
  (`attack_speed_pct`/`cast_speed_pct`, plus whatever key it picks for a health
  bonus) into `Player._recompose_stats()`'s existing `contributions` array,
  right alongside equipment. `attack_speed` and `cast_speed` already live in
  `PlayerStats.compose`'s output for exactly this reason.
