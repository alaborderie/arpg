class_name LootRoller
extends RefCounted
## Deterministically rolls dropped items from the shared loot data.
##
## Domain class (ADR 0003): pure logic, no Nodes and no file access — adapters load
## `shared/loot_tables.json` and `shared/items.json` (via `BalanceData`) and hand the
## parsed Dictionaries in. All randomness comes from the injected [RngService]
## (ADR 0004), so `same seed + same kill order => same items`.
##
## Roll pipeline for one kill, in fixed draw order (reordering these draws is a
## determinism break — treat the sequence as part of the save/replay contract):
##   1. drop roll   — randf() against the table's `drop_chance`
##   2. base pick   — uniform randi_range over the table's `base_pool`
##   3. rarity pick — weighted randi_range over `rarities` (file order matters)
##   4. affix count — randi_range over the rarity's inclusive count range,
##                    clamped to the affixes eligible for the base's slot
##   5. per affix   — uniform pick without replacement, then value randi_range
##
## A rolled item is a plain Dictionary (save-friendly for M4):
##   { "base_id": String, "name": String, "slot": String, "rarity": String,
##     "affixes": [ { "id": String, "stat": String, "value": int }, ... ] }
##
## G7 (docs/0020): [method roll_drop]'s optional `is_elite` flag biases step 3
## toward higher rarities — it swaps which weight column of `rarities` the same
## single weighted draw reads (`elite_weight` instead of `weight`), so an elite
## kill spends exactly the same number/shape of RNG draws as a normal one. This
## is deliberate: the rarity pick was always going to draw one `randi_range`
## either way, so biasing *which weights it reads* costs nothing extra in the
## stream and can never desync a save/replay the way adding a new draw would.

var _rng: RngService
## monster_id -> its `tables[]` entry.
var _tables_by_monster: Dictionary = {}
## base id -> its `bases[]` entry.
var _bases_by_id: Dictionary = {}
## The `affixes[]` array of items.json, in file order.
var _affixes: Array[Dictionary] = []
## The `rarities[]` array of loot_tables.json, in file order.
var _rarities: Array[Dictionary] = []


## [param loot_tables] is the parsed `loot_tables.json` document and [param items]
## the parsed `items.json` document.
func _init(loot_tables: Dictionary, items: Dictionary, rng: RngService) -> void:
	_rng = rng
	var tables: Array = loot_tables.get("tables", [])
	for entry: Variant in tables:
		if entry is Dictionary:
			var table: Dictionary = entry as Dictionary
			_tables_by_monster[String(table.get("monster_id", ""))] = table
	var bases: Array = items.get("bases", [])
	for entry: Variant in bases:
		if entry is Dictionary:
			var base: Dictionary = entry as Dictionary
			_bases_by_id[String(base.get("id", ""))] = base
	var affixes: Array = items.get("affixes", [])
	for entry: Variant in affixes:
		if entry is Dictionary:
			_affixes.append(entry as Dictionary)
	var rarities: Array = loot_tables.get("rarities", [])
	for entry: Variant in rarities:
		if entry is Dictionary:
			_rarities.append(entry as Dictionary)


## The `items.json` entry for [param base_id], or an empty Dictionary. Exposed so
## adapters resolve a rolled item's base through the same indexed data the roll used.
func base(base_id: String) -> Dictionary:
	return _bases_by_id.get(base_id, {}) as Dictionary


## Rolls the drop for one kill of [param monster_id]. Returns the rolled item, or
## an empty Dictionary when nothing drops (no table, chance missed, or a base id
## missing from items.json — the data tests guard that integrity). [param
## is_elite] (G7, docs/0020) biases the rarity pick toward higher tiers — pass
## [method Monster.is_elite] straight through, the same way `monster_id` is
## already read off the dead monster.
func roll_drop(monster_id: String, is_elite: bool = false) -> Dictionary:
	var table: Dictionary = _tables_by_monster.get(monster_id, {}) as Dictionary
	if table.is_empty():
		return {}
	# Drawn unconditionally (even for drop_chance 1.0) so the stream advances the
	# same way per kill regardless of tuning.
	var drop_roll: float = _rng.randf()
	if drop_roll >= float(table.get("drop_chance", 0.0)):
		return {}

	var pool: Array = table.get("base_pool", [])
	if pool.is_empty():
		return {}
	var base_id: String = String(pool[_rng.randi_range(0, pool.size() - 1)])
	var item_base: Dictionary = base(base_id)
	if item_base.is_empty():
		return {}

	var rarity: Dictionary = _pick_rarity(is_elite)
	var affixes: Array[Dictionary] = _roll_affixes(
		String(item_base.get("slot", "")),
		int(rarity.get("affix_count_min", 0)),
		int(rarity.get("affix_count_max", 0))
	)

	return {
		"base_id": base_id,
		"name": _display_name(item_base, affixes),
		"slot": String(item_base.get("slot", "")),
		"rarity": String(rarity.get("id", "normal")),
		"affixes": _strip_to_rolled(affixes),
	}


## Weighted pick over the rarities, in file order. One randi_range draw,
## whichever weight column feeds it (see the class doc for why an elite kill
## reads `elite_weight` instead of `weight` rather than drawing again). Falls
## back to `weight` for a rarity entry missing `elite_weight` so older/partial
## fixtures (the non-elite domain test suite's) keep working unchanged.
func _pick_rarity(is_elite: bool = false) -> Dictionary:
	if _rarities.is_empty():
		return {}
	var weight_key: String = "elite_weight" if is_elite else "weight"
	var total: int = 0
	for rarity: Dictionary in _rarities:
		total += int(rarity.get(weight_key, rarity.get("weight", 0)))
	if total <= 0:
		return _rarities[0]
	var pick: int = _rng.randi_range(1, total)
	for rarity: Dictionary in _rarities:
		pick -= int(rarity.get(weight_key, rarity.get("weight", 0)))
		if pick <= 0:
			return rarity
	return _rarities[_rarities.size() - 1]


## Picks affixes eligible for [param slot] without replacement and rolls each
## value. The count draw happens before clamping so the stream shape only depends
## on the rarity, not on the pool size.
func _roll_affixes(slot: String, count_min: int, count_max: int) -> Array[Dictionary]:
	var rolled: Array[Dictionary] = []
	if count_max <= 0:
		return rolled
	var count: int = _rng.randi_range(count_min, count_max)
	var eligible: Array[Dictionary] = []
	for affix: Dictionary in _affixes:
		var slots: Array = affix.get("slots", [])
		if slots.has(slot):
			eligible.append(affix)
	count = mini(count, eligible.size())
	for _i: int in count:
		var index: int = _rng.randi_range(0, eligible.size() - 1)
		var affix: Dictionary = eligible.pop_at(index) as Dictionary
		var value: int = _rng.randi_range(int(affix.get("min", 0)), int(affix.get("max", 0)))
		rolled.append({
			"id": String(affix.get("id", "")),
			"kind": String(affix.get("kind", "")),
			"affix_name": String(affix.get("name", "")),
			"stat": String(affix.get("stat", "")),
			"value": value,
		})
	return rolled


## "<first prefix> <base name> <first suffix>", in rolled order. Extra affixes on
## rares don't lengthen the name — they still show in the item's affix list.
func _display_name(item_base: Dictionary, affixes: Array[Dictionary]) -> String:
	var name: String = String(item_base.get("name", "?"))
	for affix: Dictionary in affixes:
		if String(affix.get("kind", "")) == "prefix":
			name = "%s %s" % [String(affix.get("affix_name", "")), name]
			break
	for affix: Dictionary in affixes:
		if String(affix.get("kind", "")) == "suffix":
			name = "%s %s" % [name, String(affix.get("affix_name", ""))]
			break
	return name


## The persisted affix shape keeps only identity and math: id, stat, value.
## kind/affix_name were only needed to build the display name.
func _strip_to_rolled(affixes: Array[Dictionary]) -> Array[Dictionary]:
	var stripped: Array[Dictionary] = []
	for affix: Dictionary in affixes:
		stripped.append({
			"id": String(affix.get("id", "")),
			"stat": String(affix.get("stat", "")),
			"value": int(affix.get("value", 0)),
		})
	return stripped
