extends Node3D
## Root scene: composes the test map, player, monsters, loot and camera rig, and
## turns pointer input into orders — click a monster to attack it, click a ground
## drop to pick it up, click ground to move.
##
## Godot note: `_unhandled_input` receives events no UI control consumed, which is
## exactly what world-interaction input should listen to — once we grow menus and
## HUDs, clicks on them will never leak through to movement.
##
## Touch works through the same code path: the project enables (the default)
## `emulate_mouse_from_touch`, so taps arrive as left-mouse events and trigger the
## same actions. This is the boring, engine-blessed way to support both.
##
## Clicks are resolved on the next physics tick, not in the input callback:
## monster picking raycasts the physics space, and
## [PhysicsDirectSpaceState3D] may only be queried safely during physics
## processing (see docs/0010-click-targeting-and-combat-wiring.md).
##
## G2 (docs/0016): a fresh game (no save, and no `starting_skill_id` test pin)
## shows [SkillChoiceUI] and pauses the whole tree (`get_tree().paused = true`)
## until a skill is picked — the panel's own `process_mode` is ALWAYS, so it
## keeps taking input while everything with the default PAUSABLE mode (this
## node included) is frozen. A loaded save or a pinned `starting_skill_id`
## skips the screen entirely and applies the skill immediately.
##
## G6 (docs/0019): the `cast_primary` action (Q) casts the equipped skill at
## the mouse's ground-plane point via [method Player.cast_at] — free-aim, no
## target lock, resolved the instant the key is pressed (not deferred like a
## click) since it never needs a physics-space query.
##
## G8 (docs/0021): [signal Player.level_up] drives [method _level_up_reward],
## which draws a pick-1-of-3 support offer from the dedicated
## `master_seed + 4` stream and shows [SupportChoiceUI] (same
## `get_tree().paused` idiom as the G2 skill-choice screen) — except for
## levels 10/20, reserved for G9's own skill-unlock UI. A big XP grant
## crossing several eligible levels queues one offer per level rather than
## stacking screens (`_pending_rewards`).
##
## G9 (issue #16, docs/0022): [method _level_up_reward] now claims levels
## 10/20 for real — a pick-1-of-3 SKILL offer (reusing [SkillChoiceUI]/
## [SkillCatalog.offer], excluding skills already occupying another slot) that
## binds to W (slot 1) or E (slot 2), drawn from its own dedicated
## `master_seed + 5` stream (persisted, like the support-offer stream, since it
## keeps drawing after saves exist). `_pending_rewards` is now a queue of
## EITHER reward kind (`{"kind": "support"|"skill", ...}`), so a big XP grant
## mixing level types still resolves one screen at a time, in level-crossed
## order. A save whose level already passed 10/20 without a pick (an old save,
## or a skipped one) gets that pick queued immediately on load
## ([method _queue_retroactive_slot_offers]) rather than waiting for another
## level-up that, at max level, would never come.

## The infinite plane clicks are projected onto — the ground sits at y = 0. Picking
## against a mathematical plane needs no colliders and works even when the click is
## off the map; the NavigationAgent clamps the target to the walkable mesh.
const GROUND_PLANE: Plane = Plane(Vector3.UP, 0.0)
## Physics layer 2 is "monsters" (monster.tscn sets collision_layer = 3 = 1 | 2);
## the pick ray masks to it so ground and walls never swallow a monster click.
const MONSTER_PICK_MASK: int = 2
## Physics layer 3 is "ground drops" (ground_drop.tscn sets collision_layer = 4),
## following the same picking pattern as monsters (ADR 0010).
const DROP_PICK_MASK: int = 4
## One ray finds whichever clickable — monster or drop — is nearest the camera.
const PICK_MASK: int = MONSTER_PICK_MASK | DROP_PICK_MASK
## How far a pick ray reaches into the scene, in metres. Generous on purpose: the
## orthographic camera sits 24 units out, and rays are cheap.
const PICK_RAY_LENGTH: float = 200.0

const GROUND_DROP_SCENE: PackedScene = preload("res://scenes/loot/ground_drop.tscn")
## Fallback if a skill id (a save's, or a test's `starting_skill_id`) doesn't
## resolve to anything in shared/skills.json — same "degrade instead of crash"
## convention BalanceData uses. Matches SaveData.DEFAULT_SKILL_ID.
const FALLBACK_SKILL_ID: String = "quick_strike"

## Master seed for the scene's RNG streams. 0 (the default) means "randomize, or
## load the existing save if one is on disk" (see _ready); integration tests set
## a fixed value before the scene enters the tree to make a whole run
## reproducible and, in doing so, opt out of the load-at-boot check — a test that
## wants a specific seed should never have a stray save silently override it.
@export var rng_seed: int = 0

## G2 test knob (docs/0016), same idiom as MonsterSpawner's `forced_monster_id`:
## non-empty skips the skill-choice screen entirely and applies this skill
## immediately, so scene tests get a deterministic attack without driving a UI
## pick. Ignored when a save is loaded (the save's own skill_id wins).
@export var starting_skill_id: String = ""

## G8 test knob (docs/0021), same idiom as `starting_skill_id`: true makes
## every level-up a no-op for the reward flow — no RNG draw, no UI, no pause —
## so a scene test that levels a player up for an unrelated reason (e.g. G3's
## XP/health-bar suites) never gets stuck behind a picker it isn't testing.
## G9 (docs/0022) widened its scope to also gate the level-10/20 skill-slot
## offer and the retroactive-unlock catch-up on load, without renaming it — it
## reads as "skip level-up reward offers" now, support or skill alike. Every
## existing scene test that can cross a level threshold pins this true; the
## dedicated G8/G9 suites are the ones that deliberately leave it false to
## exercise the real pickers.
@export var skip_support_offers: bool = false

## One combat RNG stream and one calculator for the whole scene (ADR 0004): every
## hit, whoever swings, draws from the same reproducible sequence.
var _rng: RngService
var _calculator: DamageCalculator
## Loot rolls draw from their own stream, derived from the same master seed
## (ADR 0011): drops then depend only on the kill sequence, never on how many
## damage/crit rolls the fight happened to consume.
var _loot_rng: RngService
var _loot_roller: LootRoller
## The spawner's monster-choice/position stream (G1, docs/0015): a third
## dedicated stream so infinite spawning never perturbs combat or loot rolls.
## Deliberately not part of the save envelope — spawn positions are ephemeral
## world state, same call ADR 0012 already made for which specific monsters
## are alive.
var _spawn_rng: RngService
## The skill-offer stream (G2, docs/0016): a fourth dedicated stream, drawn from
## exactly once per fresh game (before any pick is possible, nothing can be
## saved yet) — deliberately not part of the save envelope, the same call ADR
## 0015 made for the spawn stream.
var _skill_offer_rng: RngService
var _skill_catalog: SkillCatalog
## The support-offer stream (G8, docs/0021): a fifth dedicated stream,
## `master_seed + 4`, drawn from on every eligible level-up throughout the
## whole run (unlike the skill-offer stream above, drawn once ever) — so,
## unlike `_spawn_rng`/`_skill_offer_rng`, its state IS part of the save
## envelope (`supports_offer_rng_state`): a reload must resume this stream
## exactly where it left off, or replaying past a level a save already
## resolved would draw a *different* 3-card offer than the one shown the first
## time. docs/0021 documents this as the deliberate opposite call from ADR
## 0015/0016's un-persisted streams, for exactly the reason those ADRs
## themselves give: those streams are either ephemeral forever or exhausted
## before a save is ever possible; this one is neither.
var _support_offer_rng: RngService
var _support_catalog: SupportCatalog
## The slot-skill-offer stream (G9, docs/0022): a sixth dedicated stream,
## `master_seed + 5`, drawn from whenever level 10/20 is reached (or, via the
## retroactive-unlock policy, on load for a save whose level already passed
## one of those without a pick). Persisted the same way `_support_offer_rng`
## is (`slot_skill_offer_rng_state`) and for the identical reason: it keeps
## drawing after saves exist, so a reload must resume it exactly, not replay
## it from the derived seed.
var _slot_skill_offer_rng: RngService
## Rewards queued by level-ups (or the retroactive-unlock catch-up) that
## happened while a pick was already showing — collapses what would otherwise
## be several stacked/overlapping choice screens into one shown at a time
## (docs/0021, extended by G9/docs/0022 to cover BOTH reward kinds). Each
## element is either `{"kind": "support", "offer": Array[Dictionary]}`
## ([SupportCatalog.offer]'s shape) or `{"kind": "skill", "slot": int,
## "offer": Array[Dictionary]}` ([SkillCatalog.offer]'s shape plus which slot
## the pick binds to) — order is level-crossed order, ascending, since each
## level-up signal (already emitted in order by [method Player.gain_xp])
## appends its own single entry the instant it fires.
var _pending_rewards: Array[Dictionary] = []
## Which slot a currently-shown "skill" reward binds to, or -1 when no
## skill-slot pick is in flight — disambiguates [method _on_skill_chosen]
## between the fresh-game starting-skill screen (never touches this, stays -1)
## and a level-10/20 W/E pick reusing the exact same [SkillChoiceUI]/signal
## (docs/0022).
var _pending_skill_slot: int = -1
var _pending_click: Vector2 = Vector2.ZERO
var _has_pending_click: bool = false
## The seed this run's RNG streams derive from; kept around so _save_game can
## write it back out (M4).
var _master_seed: int = 0
## Minimal progress marker (M4): monsters killed this run. Not per-monster state —
## a reload respawns the scene's usual monsters fresh; see docs/0012.
var _monsters_killed: int = 0

@onready var _player: Player = $Player
@onready var _camera_rig: CameraRig = $CameraRig
@onready var _sun: DirectionalLight3D = $Sun
@onready var _monsters: Node3D = $Monsters
@onready var _drops: Node3D = $Drops
@onready var _spawner: MonsterSpawner = $MonsterSpawner
@onready var _inventory_panel: InventoryPanel = $InventoryPanel
@onready var _skill_choice_ui: SkillChoiceUI = $SkillChoiceUI
## The support-pick screen (G8, docs/0021): shown after most level-ups, same
## dumb-view idiom as _skill_choice_ui.
@onready var _support_choice_ui: SupportChoiceUI = $SupportChoiceUI
## The XP bar (G3, docs/0017): a dumb view over the player's level/XP, the same
## idiom as _inventory_panel — redrawn on the player's `xp_changed` signal.
@onready var _xp_bar: XPBar = $XPBar
## The Q/W/E slot HUD (G9, issue #16, docs/0022): 3 small boxes near the XP
## bar — display-only, polls every frame (see [SkillSlotsHUD] for why that's
## the one dumb-view exception in this project).
@onready var _skill_slots_hud: SkillSlotsHUD = $SkillSlotsHUD
@onready var _save_button: Button = $SaveUI/SaveButton
## Cloud-save sync adapter (M5, ADR 0013). `SyncConfig.enabled = false` in a
## test's setup opts a scene instance out entirely, the same idiom pinning
## `rng_seed` already uses to opt out of disk save-loading.
@onready var _sync_service: SyncService = $SyncService


func _ready() -> void:
	_orient_sun()
	# rng_seed == 0 is both "randomize" (no save) and "not pinned by a test" — an
	# explicit non-zero seed always wins over a save on disk (see the export doc).
	var loaded: Dictionary = {}
	if rng_seed == 0 and SaveStore.has_save():
		loaded = SaveStore.load()
	if not loaded.is_empty():
		_master_seed = int(loaded.get("master_seed", 0))
	else:
		_master_seed = rng_seed if rng_seed != 0 else randi()
	_rng = RngService.new(_master_seed)
	_loot_rng = RngService.new(_master_seed + 1)
	_spawn_rng = RngService.new(_master_seed + 2)
	_skill_offer_rng = RngService.new(_master_seed + 3)
	_support_offer_rng = RngService.new(_master_seed + 4)
	_slot_skill_offer_rng = RngService.new(_master_seed + 5)
	if not loaded.is_empty():
		_rng.set_state(int(loaded.get("combat_rng_state", _rng.get_state())))
		_loot_rng.set_state(int(loaded.get("loot_rng_state", _loot_rng.get_state())))
		_support_offer_rng.set_state(
			int(loaded.get("supports_offer_rng_state", _support_offer_rng.get_state()))
		)
		_slot_skill_offer_rng.set_state(
			int(loaded.get("slot_skill_offer_rng_state", _slot_skill_offer_rng.get_state()))
		)
	_calculator = DamageCalculator.new(_rng)
	_loot_roller = LootRoller.new(
		BalanceData.load_loot_tables(), BalanceData.load_items(), _loot_rng
	)
	_skill_catalog = SkillCatalog.new(BalanceData.load_skills())
	_support_catalog = SupportCatalog.new(BalanceData.load_supports())
	_player.setup_combat(_calculator)
	_inventory_panel.setup(_player)
	_xp_bar.setup(_player)
	_skill_slots_hud.setup(_player)
	_spawner.monster_spawned.connect(_on_monster_spawned)
	_spawner.setup(_player, _monsters, _drops, _calculator, _spawn_rng)
	_skill_choice_ui.skill_chosen.connect(_on_skill_chosen)
	_support_choice_ui.support_chosen.connect(_on_support_chosen)
	_player.level_up.connect(_level_up_reward)
	if not loaded.is_empty():
		_apply_loaded_save(loaded)
	elif starting_skill_id != "":
		_apply_skill(starting_skill_id)
	else:
		_offer_skill_choice()
	_save_button.pressed.connect(_save_game)
	_sync_service.remote_save_applied.connect(_on_remote_save_applied)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("move_to") and event is InputEventMouseButton:
		_pending_click = (event as InputEventMouseButton).position
		_has_pending_click = true
	elif event.is_action_pressed("save_game"):
		_save_game()
	elif event.is_action_pressed("cast_primary"):
		_cast_at_mouse(0)
	elif event.is_action_pressed("cast_secondary"):
		_cast_at_mouse(1)
	elif event.is_action_pressed("cast_tertiary"):
		_cast_at_mouse(2)


func _physics_process(_delta: float) -> void:
	if not _has_pending_click:
		return
	_has_pending_click = false
	_resolve_click(_pending_click)


## Turns a click into an order: a monster under the cursor means "attack it", a
## ground drop means "pick it up", anything else projects onto the ground plane
## and means "walk there".
func _resolve_click(screen_pos: Vector2) -> void:
	var camera: Camera3D = _camera_rig.camera()
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_direction: Vector3 = camera.project_ray_normal(screen_pos)

	var picked: Object = _pick_clickable(ray_origin, ray_direction)
	var monster: Monster = picked as Monster
	if monster != null and not monster.is_dead():
		_player.order_attack(monster)
		return
	var drop: GroundDrop = picked as GroundDrop
	if drop != null:
		_player.order_pickup(drop)
		return

	var hit: Variant = _project_to_ground(screen_pos)
	if hit != null:
		_player.move_to(hit)


## Q/W/E-cast (G6, issue #13, docs/0019; G9, issue #16, docs/0022): casts
## [param slot]'s skill from wherever the player currently stands, aimed at
## the mouse's ground-plane point — no target lock and no walk-into-range,
## unlike a click order. Resolved synchronously (unlike a click) because it
## only needs the same mathematical ground-plane projection move-orders
## already use, never a physics-space query, so there is no reason to defer it
## a physics tick.
func _cast_at_mouse(slot: int) -> void:
	var hit: Variant = _project_to_ground(get_viewport().get_mouse_position())
	if hit != null:
		_player.cast_at(hit, slot)


## Projects a screen point onto the mathematical [constant GROUND_PLANE] — the
## same click-to-move projection, shared with Q-cast aiming so both read the
## mouse the same way (ADR 0010's ground-plane fallback, reused rather than
## duplicated per docs/0019).
func _project_to_ground(screen_pos: Vector2) -> Variant:
	var camera: Camera3D = _camera_rig.camera()
	var ray_origin: Vector3 = camera.project_ray_origin(screen_pos)
	var ray_direction: Vector3 = camera.project_ray_normal(screen_pos)
	return GROUND_PLANE.intersects_ray(ray_origin, ray_direction)


## Raycasts the physics space for the nearest clickable body (monster or drop)
## under the cursor, or null. One ray, masked to the pickable layers only, so
## ground and walls never swallow the click (ADR 0010).
func _pick_clickable(ray_origin: Vector3, ray_direction: Vector3) -> Object:
	var query: PhysicsRayQueryParameters3D = PhysicsRayQueryParameters3D.create(
		ray_origin, ray_origin + ray_direction * PICK_RAY_LENGTH, PICK_MASK
	)
	var result: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
	var collider: Object = result.get("collider", null)
	return collider


## Wires a freshly spawned monster's death into loot rolling — the spawner owns
## *when and where* monsters appear, main.gd still owns what happens on death
## (unchanged from before G1).
func _on_monster_spawned(monster: Monster) -> void:
	monster.died.connect(_on_monster_died)


## Rolls the dead monster's loot table and drops the result where it fell, and
## grants its XP reward to the player (G3, docs/0017) — same hook as loot, one
## more thing main.gd does in response to `died`. The corpse is still valid
## during the `died` emission (freed right after). `monster.xp_reward()` and
## the `is_elite()` passed into the loot roll already carry the elite
## multipliers (G7, docs/0020) — main.gd itself stays unaware of the numbers.
## G8 (docs/0021): every kill also applies the player's composed
## `life_on_kill` flat heal (a no-op at 0, the default with no support owned).
func _on_monster_died(monster: Monster) -> void:
	_monsters_killed += 1
	_player.gain_xp(monster.xp_reward())
	_player.heal(_player.life_on_kill())
	var item: Dictionary = _loot_roller.roll_drop(monster.monster_id(), monster.is_elite())
	if item.is_empty():
		return
	var drop: GroundDrop = GROUND_DROP_SCENE.instantiate() as GroundDrop
	drop.position = monster.global_position
	_drops.add_child(drop)
	drop.setup(item)


## Serializes the run's full state and writes it via [SaveStore] (M4). Bound to
## both the `save_game` action (F5) and an on-screen button — the same
## "one action, two input paths" idiom toggle_inventory already uses for touch
## and desktop. See docs/0012 for the save-format and UX decisions.
##
## Uploads to the server right after (M5, ADR 0013): fire-and-forget, since
## SyncService.upload_after_save is a coroutine main.gd never awaits - saving
## locally never waits on the network.
func _save_game() -> void:
	var envelope: Dictionary = SaveData.build(
		_master_seed,
		_rng.get_state(),
		_loot_rng.get_state(),
		_support_offer_rng.get_state(),
		_slot_skill_offer_rng.get_state(),
		_player.current_health(),
		_player.global_position,
		_player.inventory().bag(),
		_player.inventory().equipped_by_slot(),
		_player.skill_id(),
		_player.slot_skill_id(1),
		_player.slot_skill_id(2),
		_player.level(),
		_player.total_xp(),
		_player.owned_supports(),
		_monsters_killed,
		int(Time.get_unix_time_from_system())
	)
	SaveStore.save(envelope)
	_sync_service.upload_after_save(envelope)


## Applies a migrated save envelope to the live scene: player health/position/
## inventory/equipment/skill slots and the progress counter. Shared by the
## load-at-boot path in _ready and by _on_remote_save_applied (M5), so a newer
## save that arrives from the server after boot is applied the same way a local
## save would have been. A loaded save always carries a skill_id (migration
## guarantees it, docs/0016), so this never shows the starting choice screen —
## it CAN, however, queue a retroactive W/E pick (docs/0022) if the save's
## level already passed 10/20 without one.
func _apply_loaded_save(loaded: Dictionary) -> void:
	_player.load_state(loaded)
	_apply_skill(SaveData.skill_id_from_player(loaded))
	_player.set_slot_skill(1, _skill_catalog.skill(SaveData.secondary_skill_id_from_player(loaded)))
	_player.set_slot_skill(2, _skill_catalog.skill(SaveData.tertiary_skill_id_from_player(loaded)))
	var progress: Dictionary = loaded.get("progress", {})
	_monsters_killed = int(progress.get("monsters_killed", 0))
	_queue_retroactive_slot_offers()


## Draws a deterministic 3-skill offer (G2, docs/0016) from the dedicated
## skill-offer RNG stream and shows the choice screen, freezing the world
## (player, monsters, spawner all stop physics-processing under a paused tree)
## until [method _on_skill_chosen] fires.
func _offer_skill_choice() -> void:
	var offer: Array[Dictionary] = _skill_catalog.offer(_skill_offer_rng, 3)
	_skill_choice_ui.setup(offer)
	get_tree().paused = true


## [SkillChoiceUI.skill_chosen] fires from TWO different flows that both reuse
## the same panel (docs/0022): the one-shot fresh-game starting pick
## ([method _offer_skill_choice], `_pending_skill_slot` stays -1 the whole
## time) and a level-10/20 W/E pick ([method _level_up_reward] /
## [method _queue_retroactive_slot_offers] set `_pending_skill_slot` before
## showing the panel). `_pending_skill_slot` is what tells the two apart.
func _on_skill_chosen(skill_id: String) -> void:
	if _pending_skill_slot == -1:
		get_tree().paused = false
		_apply_skill(skill_id)
		return
	var slot: int = _pending_skill_slot
	_pending_skill_slot = -1
	_player.set_slot_skill(slot, _skill_catalog.skill(skill_id))
	_advance_reward_queue()


## The reserved-levels seam (G8, docs/0021 — G9's hook), connected directly to
## [signal Player.level_up]: dispatches what a level-up reward IS for
## [param level]. G9 (docs/0022) claims levels 10/20 for real — a skill-slot
## offer bound to W (1) or E (2) — instead of the no-op G8 left here;
## `skip_support_offers` (the scene-test bypass knob, its name unchanged from
## G8 despite now gating both reward kinds — see docs/0022) still
## short-circuits before either branch, so a test pinning it never touches
## either RNG stream or either picker.
func _level_up_reward(level: int) -> void:
	if skip_support_offers:
		return
	if level == 10 or level == 20:
		_queue_skill_slot_offer(1 if level == 10 else 2)
	else:
		_pending_rewards.append({"kind": "support", "offer": _support_catalog.offer(_support_offer_rng, 3)})
	if not get_tree().paused:
		_show_next_reward()


## Draws a skill offer excluding whatever's already in another slot
## ([Player.owned_skill_ids]) from the dedicated slot-skill-offer stream and
## queues it as a "skill" reward bound to [param slot] — shared by a live
## level-10/20 crossing and the retroactive-unlock catch-up on load
## (docs/0022), so both draw from the exact same stream/exclusion rule.
func _queue_skill_slot_offer(slot: int) -> void:
	var offer: Array[Dictionary] = _skill_catalog.offer(
		_slot_skill_offer_rng, 3, _player.owned_skill_ids()
	)
	_pending_rewards.append({"kind": "skill", "slot": slot, "offer": offer})


## Pops the front of the queued rewards and shows whichever picker its "kind"
## calls for — safe to call while already paused (a second/third queued
## reward after a pick, docs/0021's "collapse, don't stack" rule for a
## multi-level XP grant, extended by docs/0022 to a mix of reward kinds).
func _show_next_reward() -> void:
	if _pending_rewards.is_empty():
		return
	var reward: Dictionary = _pending_rewards.pop_front()
	if String(reward.get("kind", "")) == "skill":
		_pending_skill_slot = int(reward.get("slot", -1))
		_skill_choice_ui.setup(reward.get("offer", []))
	else:
		_support_choice_ui.setup(reward.get("offer", []))
	get_tree().paused = true


## A support card was picked: grant it, then advance the reward queue.
func _on_support_chosen(support_id: String) -> void:
	_player.add_support(support_id)
	_advance_reward_queue()


## Shows the next queued reward (still paused, no flicker) or unpauses once
## the queue is empty — shared tail of both `_on_*_chosen` handlers.
func _advance_reward_queue() -> void:
	if _pending_rewards.is_empty():
		get_tree().paused = false
	else:
		_show_next_reward()


## G9's retroactive-unlock policy (docs/0022): a save whose level already
## passed 10/20 before this slot system existed (or whose W/E pick was somehow
## skipped) never got the chance to pick — rather than waiting for another
## level-up (which may never come again for a save already at `max_level`),
## any already-unlocked-but-still-empty slot gets its offer queued right after
## load, through the exact same reward-queue/UI path a live level-up uses.
## `skip_support_offers` gates this too, so a test loading a pre-built
## high-level save never gets stuck behind a picker it isn't testing.
func _queue_retroactive_slot_offers() -> void:
	if skip_support_offers:
		return
	for slot: int in range(1, SkillSlots.SLOT_COUNT):
		if _player.is_slot_unlocked(slot) and _player.slot_skill_id(slot).is_empty():
			_queue_skill_slot_offer(slot)
	if not _pending_rewards.is_empty() and not get_tree().paused:
		_show_next_reward()


## Resolves [param skill_id] against the catalog and applies it to the player,
## falling back to FALLBACK_SKILL_ID for an id that doesn't resolve (a stale
## save from a renamed skill, or a typo'd test knob) — degrade, don't crash,
## the same convention BalanceData's loaders use.
func _apply_skill(skill_id: String) -> void:
	var skill: Dictionary = _skill_catalog.skill(skill_id)
	if skill.is_empty():
		skill = _skill_catalog.skill(FALLBACK_SKILL_ID)
	_player.set_skill(skill)


## SyncService found a save on the server newer than what boot loaded (or than
## what existed locally at all) and already wrote it to disk; apply it to the
## running session too. Silent last-write-wins, no confirmation prompt - an
## acceptable stub UX for a single-device game (docs/0013).
func _on_remote_save_applied(envelope: Dictionary) -> void:
	_apply_loaded_save(envelope)


## Angles the key light so the flat-shaded geometry reads with clear light/shade.
func _orient_sun() -> void:
	_sun.rotation_degrees = Vector3(-55.0, -35.0, 0.0)
