extends GdUnitTestSuite
## Unit tests for [SupportCatalog] (G8, docs/0021) — indexing
## `shared/supports.json`-shaped data, the deterministic pick-3 offer (drawn
## from the FULL pool every time, owned supports included), and the
## owned-ids -> contribution-Dictionary math [PlayerStats.compose] consumes.

const SUPPORTS_DATA: Dictionary = {
	"schema_version": 1,
	"supports": [
		{
			"id": "added_projectiles", "name": "Added Projectiles",
			"description": "+1 projectile.", "family": "pipeline",
			"stat": "added_projectiles", "value": 1,
		},
		{
			"id": "increased_damage", "name": "Increased Damage",
			"description": "+damage.", "family": "stat", "stat": "damage_pct", "value": 15.0,
		},
		{
			"id": "added_flat_fire_damage", "name": "Added Fire Damage",
			"description": "+fire.", "family": "stat", "stat": "added_flat_damage",
			"element": "fire", "value": 3,
		},
		{
			"id": "life_on_kill", "name": "Life on Kill",
			"description": "+heal.", "family": "stat", "stat": "life_on_kill", "value": 3,
		},
	],
}


func test_support_looks_up_by_id() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var support: Dictionary = catalog.support("increased_damage")
	assert_str(String(support.get("name", ""))).is_equal("Increased Damage")


func test_support_with_unknown_id_returns_empty() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	assert_bool(catalog.support("does_not_exist").is_empty()).is_true()


func test_all_supports_returns_every_entry_in_file_order() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var all: Array[Dictionary] = catalog.all_supports()
	assert_int(all.size()).is_equal(4)
	assert_str(String(all[0].get("id", ""))).is_equal("added_projectiles")
	assert_str(String(all[3].get("id", ""))).is_equal("life_on_kill")


func test_offer_returns_the_requested_count_of_distinct_supports() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var offer: Array[Dictionary] = catalog.offer(RngService.new(1), 3)
	assert_int(offer.size()).is_equal(3)
	var ids: Array[String] = []
	for support: Dictionary in offer:
		ids.append(String(support.get("id", "")))
	for id_value: String in ids:
		assert_int(ids.count(id_value)).is_equal(1)


func test_offer_is_deterministic_for_the_same_seed() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var first: Array[Dictionary] = catalog.offer(RngService.new(99), 3)
	var second: Array[Dictionary] = catalog.offer(RngService.new(99), 3)
	assert_int(first.size()).is_equal(second.size())
	for i: int in first.size():
		assert_str(String(first[i].get("id", ""))).is_equal(String(second[i].get("id", "")))


func test_offer_differs_for_a_different_seed() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var a: Array[Dictionary] = catalog.offer(RngService.new(1), 3)
	var b: Array[Dictionary] = catalog.offer(RngService.new(2), 3)
	var a_ids: Array[String] = []
	var b_ids: Array[String] = []
	for support: Dictionary in a:
		a_ids.append(String(support.get("id", "")))
	for support: Dictionary in b:
		b_ids.append(String(support.get("id", "")))
	assert_bool(a_ids == b_ids).is_false()


## The "your call, document it" decision (docs/0021): the draw is over the
## FULL pool every time, so an offer can (and, with a small enough pool and
## enough draws, will) include a support already owned — this is a
## repeated_rng_never_excludes_the_full_pool proof, not a flaky one: with a
## 4-support pool and an owned set covering 3 of them, a subsequent 3-pick
## offer with a fixed seed still draws successfully at full count (no
## artificial shrinkage from "excluded" ids).
func test_offer_never_excludes_already_owned_supports() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	# Simulate having already picked 3 of the 4 supports — offer() takes no
	# "owned" parameter at all, so it can't have shrunk the pool.
	var offer: Array[Dictionary] = catalog.offer(RngService.new(5), 4)
	assert_int(offer.size()).is_equal(4)


func test_contribution_for_owned_is_all_zero_for_no_supports() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var empty: Array[String] = []
	var contribution: Dictionary = catalog.contribution_for_owned(empty)
	assert_float(float(contribution.get("damage_pct", -1.0))).is_equal_approx(0.0, 0.0001)
	assert_int(int(contribution.get("added_projectiles", -1))).is_equal(0)
	assert_int(int(contribution.get("life_on_kill", -1))).is_equal(0)
	assert_bool((contribution.get("added_flat_damage", {}) as Dictionary).is_empty()).is_true()


## Stacking (docs/0021): owning the same support twice sums its value twice —
## mechanically simple because [method contribution_for_owned] iterates the
## raw (possibly-repeated) owned-id list rather than a deduplicated set.
func test_contribution_for_owned_stacks_duplicate_supports() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var owned: Array[String] = ["increased_damage", "increased_damage", "added_projectiles"]
	var contribution: Dictionary = catalog.contribution_for_owned(owned)
	assert_float(float(contribution.get("damage_pct", 0.0))).is_equal_approx(30.0, 0.0001)
	assert_int(int(contribution.get("added_projectiles", 0))).is_equal(1)


func test_contribution_for_owned_merges_added_flat_damage_by_element() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var owned: Array[String] = ["added_flat_fire_damage", "added_flat_fire_damage"]
	var contribution: Dictionary = catalog.contribution_for_owned(owned)
	var flat: Dictionary = contribution.get("added_flat_damage", {})
	assert_int(int(flat.get("fire", 0))).is_equal(6)


## An unknown owned id (a stale save from a renamed/removed support) is
## silently skipped rather than crashing the sum — same "degrade instead of
## crash" convention every other BalanceData-backed lookup in this project uses.
func test_contribution_for_owned_ignores_unknown_ids() -> void:
	var catalog: SupportCatalog = SupportCatalog.new(SUPPORTS_DATA)
	var owned: Array[String] = ["does_not_exist", "life_on_kill"]
	var contribution: Dictionary = catalog.contribution_for_owned(owned)
	assert_int(int(contribution.get("life_on_kill", 0))).is_equal(3)
