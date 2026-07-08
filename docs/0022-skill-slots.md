# 22. Multi-skill slots: W at level 10, E at level 20

- Status: accepted
- Date: 2026-07-08

## Context

G9 (issue #16) grows the player from one active skill to three independent
slots — Q (from the start), W (unlocked at level 10) and E (level 20) — each
free-aim-casting its own skill on its own cooldown, per the ticket. G8
(docs/0021) deliberately left this as the one open seam: `main.gd`'s
`_level_up_reward(level)` returned early, a no-op, for levels 10 and 20,
specifically so G9 could claim them without forking the level-up path. Several
sub-decisions fall out: how a level-10/20 reward reuses G2's skill-offer
mechanics without a second UI, whether that reward's exclusion rule needs
owned-skill awareness the original one-shot offer never had, where the new
offer's randomness comes from and whether its stream state must survive a
save, how a big XP grant crossing several eligible levels resolves a MIX of
reward kinds (support pick, skill-slot pick) without stacking or forking
G8's queue, how an old save that reached level 10/20 before this system
existed (or a save at `max_level` that never will again) gets its missed
pick, and how the cast pipeline generalizes from one skill to three without
losing the "same cast_at/_cast core, shared damage-resolution" shape docs/0019
built.

## Decision

**Slot model: `Player` grows parallel arrays, not three copies of its old
single-skill fields.** `_slot_skills`/`_slot_kinds`/`_slot_attack_ranges`/
`_slot_seconds_between_attacks`/`_slot_attacks`/`_slot_cooldowns`, each sized
3 (index 0 = Q, 1 = W, 2 = E). `_recompose_stats()` now composes THREE
Dictionaries instead of one — the same shared `contributions` array
(equipment + level bonus + owned supports) is composed once per slot against
that slot's own skill overlay (`SkillCatalog.attack_config(skill)`, empty
until a slot has a pick), so gear, the level bonus, and every support
(`increased_damage`, `added_projectiles`, etc.) reach whichever slot casts —
not just slot 0. `_config` (the one Dictionary feeding `move_speed`/
`max_health`/`projectile_speed`/`added_projectiles`/`life_on_kill`) stays
slot 0's composed output: no skill overlay ever touches those five fields
(`SkillCatalog.attack_config` only sets damage/range/crit/speed), so reading
them off any one slot's composition is exactly as correct as another's, and
composing a fourth, skill-less Dictionary just for these fields would be
pure waste. `set_skill`/`skill_id()` (G2's original names, still called by
every existing test and `main.gd`'s starting-pick/save-restore paths) become
thin aliases over new `set_slot_skill(0, ...)`/`slot_skill_id(0)`.

**Slot-unlock rule lives in its own domain class, `SkillSlots`
(`game/domain/skill_slots.gd`), not inline in `Player`.** ADR 0003 draws the
line at "is this a game rule or an adapter concern" — which level unlocks
which slot is a rule, not rendering/input plumbing, so `Player` (a scene
adapter) and `main.gd` both consult `SkillSlots.is_unlocked(slot, level)`/
`SkillSlots.unlock_level(slot)` rather than either hard-coding `10`/`20`
itself. This is also what makes "domain: unlock levels" a real unit-tested
concern (`test_skill_slots.gd`) independent of booting a scene.

**`cast_at` grew an optional `slot` parameter (default 0) instead of a
parallel `cast_secondary_at`/`cast_tertiary_at` method pair.** docs/0019
already scaffolded this exact seam ("G9 would give `cast_at`'s callers a
different skill to look up first, then call into the same `_cast` core with
that skill's own precomposed fields") — a default argument means every
pre-G9 call site (main.gd's Q handler, every existing scene test calling
`player.cast_at(point)`) keeps compiling and behaving identically, while
`main.gd`'s new W/E input handlers pass 1/2. `_cast`/`_fire_projectile_directional`/
`_melee_cast`/`_resolve_hit_on` all grew the same `slot` parameter, reading
`_slot_attack_ranges[slot]`/`_slot_attacks[slot]` instead of the old singular
fields — the cooldown/facing contract itself (dead check, calculator check,
facing turn, "cooldown or lock gates a press to a total no-op, not even a
turn") is untouched, just parameterized. A locked slot (below its unlock
level) is checked in the exact same branch as an on-cooldown one and behaves
identically — silently ignored, no error, no distinct code path a player
could observe.

**Per-slot cooldowns tick down independently in `_physics_process`** — a
`for slot in SkillSlots.SLOT_COUNT` loop decrementing all three
`_slot_cooldowns` every physics tick, rather than one shared timer. This is
the ticket's explicit "W on cooldown doesn't block Q" requirement; the
click-order auto-attack path (`order_attack`/`_try_attack`) is untouched and
always swings slot 0, exactly as before G9 — clicking a monster never
targeted a slot, so there's nothing to generalize there.

**The level-10/20 reward reuses `SkillChoiceUI`/`SkillCatalog.offer` verbatim
— no second picker scene.** The ticket calls for "the same offer rules as the
start screen"; `main.gd`'s `_level_up_reward(level)` (G8's reserved seam)
now, for level 10 or 20, draws a 3-skill offer and shows the exact same
`SkillChoiceUI` the fresh-game starting pick already uses. Since one signal
(`SkillChoiceUI.skill_chosen`) now serves two different flows — the one-shot
starting pick and a level-10/20 slot pick — `main.gd` tracks
`_pending_skill_slot: int = -1` to tell them apart: -1 means "this is the
starting pick," any other value means "bind to this slot instead." This was
chosen over a second `SkillSlotChoiceUI` scene because the two flows render
identically (three skill cards, a Choose button) and only differ in what
happens with the picked id — forking the UI would mean two copies of the same
~90 lines of card-building code for zero behavioral difference.

**The level-10/20 offer excludes skills already occupying another slot —
a real, mechanical difference from G2's original offer, which excluded
nothing.** `SkillCatalog.offer` grew an optional `excluding: Array[String] = []`
parameter, filtered out of the pool *before* the random draw (so which ids
remain, not just how many, stays a fixed reproducible rule — the same
"pop a random index from the remaining pool" contract `offer` already
documented). Default empty array means G2's original one-shot call site
(`_skill_catalog.offer(_skill_offer_rng, 3)`) is unaffected. `Player.owned_skill_ids()`
collects every slot's current id (empty slots omitted) for `main.gd` to pass
in. Unlike G8's supports (docs/0021's deliberate "never exclude owned,
duplicates stack" call), a skill genuinely can't occupy two slots at once —
letting slot 1's offer repeat slot 0's skill would mean picking a strictly
redundant card, so exclusion here is the right call for a different reason
than why G8 rejected it for supports.

**Offers draw from a sixth dedicated RNG stream, `master_seed + 5` — and,
like the support-offer stream (not the one-shot skill-offer stream), its
state PERSISTS in the save.** The same reasoning ADR 0021 used to persist
`supports_offer_rng_state` applies unchanged: this stream is drawn from
after saves already exist (at least once per real playthrough, at level 10;
again at 20), so a reload that replayed it from the derived seed instead of
resuming would show a *different* 3-card W/E offer than the one a player
already saw and picked from — the same "I save-scummed my way to a better
offer" failure mode ADR 0012's RNG-persistence discipline exists to
prevent. `slot_skill_offer_rng_state` joins the envelope the same
`.get(key, current_state)` no-op-if-absent way every other stream does.

**Reward queue generalizes from "a list of support offers" to "a list of
EITHER reward kind," ordered by level crossed, ascending.** G8's
`_pending_support_offers: Array` (each element a 3-support offer) becomes
`_pending_rewards: Array[Dictionary]`, each element either
`{"kind": "support", "offer": [...]}` or
`{"kind": "skill", "slot": int, "offer": [...]}`. Order is simply the order
`Player.gain_xp`'s `for crossed_level in range(...)` loop already emits
`level_up` signals in (ascending, one per level, already proven by G8) —
`_level_up_reward` appends its single new entry the instant its signal
fires, so a 9→11 jump queues [level 10's skill offer, level 11's support
offer] in that exact order, and `_show_next_reward()` always pops the front.
This was the natural generalization of G8's own "queue, don't stack" answer
to the ticket's identical question about mixed reward types — a second,
parallel queue (one for supports, one for skills) would have needed its own
interleaving rule to decide which queue's front goes next; one queue holding
tagged entries needs no such rule; the tag alone decides which picker
(`_skill_choice_ui` or `_support_choice_ui`) to show and, only for the
"skill" tag, which slot the pick binds to. `_show_next_reward`/
`_advance_reward_queue` are the shared pop/pause and pop-or-unpause tail
both `_on_skill_chosen` (skill-slot branch) and `_on_support_chosen` now
call, replacing G8's `_show_next_support_offer`.

**`skip_support_offers` keeps its name but its scope widened to cover BOTH
reward kinds, rather than growing a second `skip_skill_slot_offers` knob.**
Renaming it would have touched every existing G3/G4/G8 scene test that pins
it (`test_xp_progression.gd`, `test_health_bars.gd`, `test_support_choice.gd`)
for a purely cosmetic reason; the ticket's own phrasing ("skip_support_offers
where appropriate") reads as license to reuse it, and its actual job — "no
level-up-driven picker of any kind gets in this test's way" — is exactly
what every one of those call sites already wants. Documented as a deliberate
naming carry-over rather than a drift.

**Retroactive-unlock policy: queue the missed pick immediately on load, not
on the next level-up.** The ticket poses this as an open "your call, document
it": an old (pre-G9) save, or one whose W/E pick was somehow skipped, can sit
at a level that's already past 10 and/or 20 with an empty slot. Two policies
were on the table — offer it retroactively the next time the player levels
up, or offer it immediately when the save loads. **Immediate-on-load wins**
for a concrete reason the "next level-up" option cannot handle at all: a save
already sitting at `max_level` (20, `shared/progression.json`'s current
ceiling) will *never* level up again, so "wait for the next level-up" would
mean that save's W and/or E slot stays permanently empty — a real, permanent
loss for exactly the players who've played longest. `main.gd._queue_retroactive_slot_offers()`
runs at the tail of `_apply_loaded_save` (both the boot-load path and the M5
remote-save-applied path): for each slot beyond 0, if the player's restored
level already meets that slot's unlock level AND its id is still empty, it's
queued through `_queue_skill_slot_offer` — the exact same function a live
level-10/20 crossing calls, so both draw from the identical stream/exclusion
rule and there is only one code path that ever produces a "skill" reward.
`skip_support_offers` gates this too, so a test that loads a save already
past level 10 never gets stuck behind a picker outside what it's testing.

**Save: `schema_version` 5, `_migrate_v4_to_v5`.** `player.secondary_skill_id`/
`player.tertiary_skill_id` (slots 1/2's ids, `""` meaning "not yet picked" —
a genuinely valid, non-fallback state, unlike slot 0's `skill_id` which
always resolves to something real) join the envelope; a pre-G9 save
(`schema_version` ≤ 4) gets both defaulted to `""` — the existing `skill_id`
already means slot 0 with zero migration needed there. `slot_skill_offer_rng_state`
is deliberately left unset by this step, mirroring `_migrate_v3_to_v4`'s
identical treatment of `supports_offer_rng_state`: a pre-G9 save never drew
from a stream that didn't exist yet, so there's no real position to
reconstruct — `main.gd`'s `.get(key, freshly-constructed-state)` load path
already handles the absence correctly. `SaveData.build`'s positional
parameter list grew by four (`slot_skill_offer_rng_state`,
`secondary_skill_id`, `tertiary_skill_id` alongside the existing
`skill_id`) rather than switching to a keyword/options-Dictionary shape —
every prior schema bump (G3, G8) extended this same long positional
signature, and a mid-flight shape change for this one ticket would be a
bigger, separately-justified refactor than G9's actual scope.

**HUD: 3 small slot boxes, polling every frame — the one dumb-view exception
in this project.** `SkillSlotsHUD` (`game/scenes/ui/skill_slots_hud.gd`/
`.tscn`) sits just above `XPBar`, same bottom-center anchor idiom. Every
other dumb view here (`InventoryPanel`, `XPBar`) redraws once, from a
signal, because there's a discrete "something changed" event to hook
(`inventory_changed`, `xp_changed`). A slot's cooldown has no such event —
nothing fires "cooldown ticked down a little" every frame it's ticking —
so `SkillSlotsHUD._process(_delta)` just re-reads `Player.slot_cooldown_fraction`/
`Player.is_slot_unlocked`/`Player.slot_skill` and rewrites three labels'
text and modulate alpha every frame. This is cheap enough (three Dictionary
reads, three string formats, no allocation beyond the label text) that
inventing a "cooldown changed" signal purely to preserve the redraw-on-signal
idiom would be solving a problem that doesn't exist. A locked slot shows
"Lv N"; an unlocked-but-unpicked slot (reachable for a frame or two right
after crossing 10/20, before the reward queue's pick screen resolves) shows
"?"; a bound slot shows its skill's name/element, dimmed while cooling.
Display-only — no mouse/touch handling, per the ticket.

## Consequences

- `game/domain/skill_slots.gd` + `test_skill_slots.gd` are new; no shared-data
  file changes — the unlock levels are code constants, not tunable balance
  data (they're structural to which input key exists, not a number a
  designer would want to retune independent of a code change).
- `SkillCatalog.offer` gained an optional `excluding` parameter; G2's own
  call site is unaffected (default `[]`). `test_skill_catalog.gd` gained
  coverage for the exclusion behavior, including the edge case of excluding
  all but one candidate.
- `Player`'s single `_skill`/`_skill_kind`/`_attack`/`_attack_range`/
  `_seconds_between_attacks`/`_attack_cooldown` fields are gone, replaced by
  the `_slot_*` arrays described above; every method that read them
  (`_try_attack`, `cast_at`, `_cast`, `_fire_projectile*`, `_melee_cast`,
  `_resolve_hit_on`, `attack_profile()`) was updated to read slot 0 (or
  whichever slot is passed in) instead — a mechanical but wide refactor
  covered by the full existing scene-test suite passing unmodified (every
  pre-G9 caller of `cast_at`/`attack_profile`/`skill_id`/`set_skill` still
  compiles and behaves identically, by construction of the default-argument/
  alias choices above).
- `project.godot` gained `cast_secondary` (W, physical keycode 87) and
  `cast_tertiary` (E, physical keycode 69) input actions, following
  `cast_primary`'s exact serialized block shape; `main.gd`'s
  `_unhandled_input` routes both to `_cast_at_mouse(slot)`, the same
  ground-plane-projection helper Q already used, parameterized.
- `SaveData.build`'s signature grew (see above); every call site
  (`main.gd._save_game`, `test_save_data.gd`) was updated. `schema_version`
  bumped 4 → 5; `test_save_data.gd` gained an isolated v4→v5 test (mirroring
  the existing v1/v2/v3-isolated tests) and the full v0-chain test now
  asserts the new fields land on their documented defaults too.
- `main.tscn` gained one new node, `SkillSlotsHUD`, instanced next to `XPBar`;
  `main.gd` wires it up in `_ready` the same one-line `setup(_player)` call
  every other dumb-view panel gets.
- Every existing scene test that pins `skip_support_offers = true`
  (`test_xp_progression.gd`, `test_health_bars.gd`) needed NO changes — the
  knob's widened scope (see above) covers the new reward kind for free.
  `test_support_choice.gd` and `test_skill_choice.gd` are similarly
  untouched: G8's support-offer flow and G2's starting-pick flow are both
  exactly as they were: `_level_up_reward`'s branch structure changed, but
  neither existing suite exercises levels 10/20.
- New suite `test_skill_slots.gd`: reaching level 10 shows the (reused)
  skill picker excluding the owned Q skill and binds the pick to slot 1;
  a granted W skill casts and kills a monster through the full pipeline;
  Q and W cooldowns are proven independent (W's own first cast is never
  blocked by a Q cast moments earlier); a support granted while any skill is
  equipped still fans extra projectiles when E (slot 2) is the one casting;
  a locked slot's cast is a silent no-op. `Player.set_slot_skill` is the
  documented seam for granting a slot's skill directly in a test, mirroring
  `Player.add_support`'s identical precedent from G8.
- Loose end for future polish: `Player.attack_profile()` (the public getter
  UI/tests use) still only exposes slot 0's profile — nothing outside this
  class has needed slot 1/2's profile directly yet, so no `slot_attack_profile(slot)`
  getter was added; a future ticket that wants to display, say, W's damage
  range in a tooltip would need one.
