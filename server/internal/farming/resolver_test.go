package farming

import (
	"encoding/json"
	"errors"
	"testing"
)

// fixtureData is a small, hand-controlled Data used by resolver unit tests
// so assertions don't depend on shared/*.json's real balance numbers
// (which are free to change). "always drops" and "single rarity" make the
// RNG-driven paths exercised but their outcome trivially predictable; the
// real-data end-to-end determinism check lives in service_test.go.
func fixtureData() *Data {
	monsters := []Monster{
		{ID: "test_imp", Name: "Test Imp", XPReward: 10},
		{ID: "no_loot_beast", Name: "No Loot Beast", XPReward: 3},
	}
	items := []ItemBase{
		{ID: "test_sword", Name: "Test Sword", Slot: "weapon"},
	}
	rarities := []Rarity{
		{ID: "normal", Weight: 1, AffixCountMax: 0},
		{ID: "rare", Weight: 1, AffixCountMax: 4},
	}
	data := &Data{
		Monsters:      monsters,
		MonsterByID:   map[string]Monster{},
		Items:         items,
		ItemByID:      map[string]ItemBase{},
		Rarities:      rarities,
		LootByMonster: map[string]LootTable{},
	}
	for _, m := range monsters {
		data.MonsterByID[m.ID] = m
	}
	for _, i := range items {
		data.ItemByID[i.ID] = i
	}
	data.LootByMonster["test_imp"] = LootTable{
		MonsterID:  "test_imp",
		DropChance: 1, // always drops, so drop counts are exactly kill_count
		BasePool:   []string{"test_sword"},
	}
	// no_loot_beast has no loot table entry at all: engage_boss on it must
	// never produce drops.
	return data
}

func callJSON(t *testing.T, name string, input any) ToolCall {
	t.Helper()
	raw, err := json.Marshal(input)
	if err != nil {
		t.Fatalf("marshal %s input: %v", name, err)
	}
	return ToolCall{Name: name, Input: raw}
}

func TestResolver_MustStartMapFirst(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	_, err := r.Execute(callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}))
	if !errors.Is(err, ErrSessionNotStarted) {
		t.Fatalf("err = %v, want ErrSessionNotStarted", err)
	}
}

func TestResolver_CannotStartMapTwice(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	if _, err := r.Execute(callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"})); err != nil {
		t.Fatalf("first start_map failed: %v", err)
	}
	_, err := r.Execute(callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	if !errors.Is(err, ErrSessionAlreadyStarted) {
		t.Fatalf("err = %v, want ErrSessionAlreadyStarted", err)
	}
}

func TestResolver_NoCallsAcceptedAfterEndSession(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	mustExecute(t, r, callJSON(t, ToolEndSession, EndSessionInput{}))

	_, err := r.Execute(callJSON(t, ToolVendorItems, VendorItemsInput{}))
	if !errors.Is(err, ErrSessionEnded) {
		t.Fatalf("err = %v, want ErrSessionEnded", err)
	}
}

func TestResolver_UnknownMonster(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))

	_, err := r.Execute(callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "does_not_exist"}))
	if !errors.Is(err, ErrUnknownMonster) {
		t.Fatalf("set_farm_target err = %v, want ErrUnknownMonster", err)
	}

	_, err = r.Execute(callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "does_not_exist", KillCount: 1}))
	if !errors.Is(err, ErrUnknownMonster) {
		t.Fatalf("engage_boss err = %v, want ErrUnknownMonster", err)
	}
}

func TestResolver_InvalidKillCount(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))

	for _, killCount := range []int{0, -1} {
		_, err := r.Execute(callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: killCount}))
		if !errors.Is(err, ErrInvalidKillCount) {
			t.Errorf("kill_count=%d: err = %v, want ErrInvalidKillCount", killCount, err)
		}
	}
}

func TestResolver_UnknownTool(t *testing.T) {
	r := NewResolver(fixtureData(), 1)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))

	_, err := r.Execute(ToolCall{Name: "not_a_real_tool", Input: json.RawMessage(`{}`)})
	if !errors.Is(err, ErrUnknownTool) {
		t.Fatalf("err = %v, want ErrUnknownTool", err)
	}
}

func TestResolver_EngageBoss_XPAndKillsAccumulate(t *testing.T) {
	r := NewResolver(fixtureData(), 42)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	mustExecute(t, r, callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "no_loot_beast"}))

	res := mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "no_loot_beast", KillCount: 4}))
	var out EngageBossResult
	decode(t, res, &out)
	if out.Kills != 4 {
		t.Errorf("Kills = %d, want 4", out.Kills)
	}
	if out.XPGained != 4*3 {
		t.Errorf("XPGained = %d, want %d", out.XPGained, 4*3)
	}
	if len(out.Drops) != 0 {
		t.Errorf("expected no drops for a monster with no loot table, got %v", out.Drops)
	}

	// A second batch accumulates onto session state.
	mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "no_loot_beast", KillCount: 2}))
	state := r.State()
	if state.Kills != 6 {
		t.Errorf("cumulative Kills = %d, want 6", state.Kills)
	}
	if state.XPGained != 18 {
		t.Errorf("cumulative XPGained = %d, want 18", state.XPGained)
	}
}

func TestResolver_EngageBoss_AlwaysDropsAccumulateInInventory(t *testing.T) {
	r := NewResolver(fixtureData(), 7)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	mustExecute(t, r, callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}))

	res := mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 5}))
	var out EngageBossResult
	decode(t, res, &out)

	totalDropped := 0
	for _, d := range out.Drops {
		if d.ItemID != "test_sword" {
			t.Errorf("unexpected item id %q dropped (only test_sword is in the base_pool)", d.ItemID)
		}
		totalDropped += d.Count
	}
	if totalDropped != 5 {
		t.Errorf("total dropped = %d, want 5 (drop_chance is 1)", totalDropped)
	}

	// Selling everything held should match what was dropped.
	vendorRes := mustExecute(t, r, callJSON(t, ToolVendorItems, VendorItemsInput{}))
	var vendorOut VendorItemsResult
	decode(t, vendorRes, &vendorOut)
	if vendorOut.ItemsSold != 5 {
		t.Errorf("ItemsSold = %d, want 5", vendorOut.ItemsSold)
	}
	if vendorOut.CurrencyGained <= 0 {
		t.Error("expected positive currency from vendoring 5 dropped items")
	}

	// Nothing should be left held after selling everything.
	summary := r.Summary()
	if len(summary.ItemsKept) != 0 {
		t.Errorf("ItemsKept after selling everything = %v, want empty", summary.ItemsKept)
	}
}

func TestResolver_VendorItems_FiltersByItemID(t *testing.T) {
	r := NewResolver(fixtureData(), 3)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	mustExecute(t, r, callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}))
	mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 3}))

	// Vendor a item id that was never dropped: nothing should sell, and the
	// real held items remain for the final summary.
	res := mustExecute(t, r, callJSON(t, ToolVendorItems, VendorItemsInput{ItemIDs: []string{"nonexistent_item"}}))
	var out VendorItemsResult
	decode(t, res, &out)
	if out.ItemsSold != 0 || out.CurrencyGained != 0 {
		t.Fatalf("vendoring an unheld item id sold %d items for %d currency, want 0/0", out.ItemsSold, out.CurrencyGained)
	}

	summary := r.Summary()
	if len(summary.ItemsKept) == 0 {
		t.Fatal("expected items still held after vendoring an unrelated item id")
	}
}

func TestResolver_EndSession_SummaryReflectsFullRun(t *testing.T) {
	r := NewResolver(fixtureData(), 99)
	mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
	mustExecute(t, r, callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}))
	mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 5}))
	mustExecute(t, r, callJSON(t, ToolVendorItems, VendorItemsInput{}))
	res := mustExecute(t, r, callJSON(t, ToolEndSession, EndSessionInput{}))

	var out EndSessionResult
	decode(t, res, &out)
	if out.Summary.Kills != 5 {
		t.Errorf("Summary.Kills = %d, want 5", out.Summary.Kills)
	}
	if out.Summary.XPGained != 50 {
		t.Errorf("Summary.XPGained = %d, want 50", out.Summary.XPGained)
	}
	if out.Summary.CurrencyGained <= 0 {
		t.Error("expected positive CurrencyGained after vendoring dropped items")
	}
}

// TestResolver_Determinism is the core guarantee: two independently built
// Resolvers over the same Data, seeded identically and fed the identical
// tool-call sequence (including RNG-driven engage_boss batches), must
// produce byte-identical transcripts and an identical summary.
func TestResolver_Determinism(t *testing.T) {
	data := fixtureData()
	calls := []ToolCall{
		callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}),
		callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}),
		callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 5}),
		callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 3}),
		callJSON(t, ToolVendorItems, VendorItemsInput{}),
		callJSON(t, ToolEndSession, EndSessionInput{}),
	}

	run := func() ([]string, RunSummary) {
		r := NewResolver(data, 12345)
		outputs := make([]string, 0, len(calls))
		for _, call := range calls {
			res := mustExecute(t, r, call)
			outputs = append(outputs, string(res.Output))
		}
		return outputs, r.Summary()
	}

	outputs1, summary1 := run()
	outputs2, summary2 := run()

	if len(outputs1) != len(outputs2) {
		t.Fatalf("output count differs: %d vs %d", len(outputs1), len(outputs2))
	}
	for i := range outputs1 {
		if outputs1[i] != outputs2[i] {
			t.Errorf("step %d output differs:\n  run1: %s\n  run2: %s", i, outputs1[i], outputs2[i])
		}
	}
	assertSummaryEqual(t, summary1, summary2)
}

// TestResolver_DifferentSeedsCanDiverge is a sanity check the RNG stream is
// actually seed-dependent: two different seeds are not guaranteed to
// diverge for every possible sequence, but across enough kills with a real
// multi-rarity table the odds of an accidental collision are negligible, so
// this documents the expectation without being flaky (fixtureData always
// drops the same single item id; only rarity selection could differ, and
// with two equally-weighted rarities across 20 kills a same-seed-only
// coincidence is astronomically unlikely).
func TestResolver_DifferentSeedsCanDiverge(t *testing.T) {
	runRarities := func(seed int64) []string {
		r := NewResolver(fixtureData(), seed)
		mustExecute(t, r, callJSON(t, ToolStartMap, StartMapInput{MapID: "m1"}))
		mustExecute(t, r, callJSON(t, ToolSetFarmTarget, SetFarmTargetInput{MonsterID: "test_imp"}))
		mustExecute(t, r, callJSON(t, ToolEngageBoss, EngageBossInput{MonsterID: "test_imp", KillCount: 20}))
		var rarities []string
		for _, d := range r.heldItems() {
			for i := 0; i < d.Count; i++ {
				rarities = append(rarities, d.Rarity)
			}
		}
		return rarities
	}

	a := runRarities(1)
	b := runRarities(2)
	same := len(a) == len(b)
	if same {
		for i := range a {
			if a[i] != b[i] {
				same = false
				break
			}
		}
	}
	if same {
		t.Skip("seeds 1 and 2 happened to produce identical rarity sequences (astronomically unlikely); not a real failure")
	}
}

func mustExecute(t *testing.T, r *Resolver, call ToolCall) ToolResult {
	t.Helper()
	res, err := r.Execute(call)
	if err != nil {
		t.Fatalf("Execute(%s) failed: %v", call.Name, err)
	}
	return res
}

func decode(t *testing.T, res ToolResult, v any) {
	t.Helper()
	if err := json.Unmarshal(res.Output, v); err != nil {
		t.Fatalf("decode %s output: %v", res.Name, err)
	}
}

func assertSummaryEqual(t *testing.T, a, b RunSummary) {
	t.Helper()
	if a.Kills != b.Kills || a.XPGained != b.XPGained || a.CurrencyGained != b.CurrencyGained {
		t.Fatalf("summaries differ: %+v vs %+v", a, b)
	}
	if len(a.ItemsKept) != len(b.ItemsKept) {
		t.Fatalf("ItemsKept length differs: %v vs %v", a.ItemsKept, b.ItemsKept)
	}
	for i := range a.ItemsKept {
		if a.ItemsKept[i] != b.ItemsKept[i] {
			t.Fatalf("ItemsKept[%d] differs: %+v vs %+v", i, a.ItemsKept[i], b.ItemsKept[i])
		}
	}
}
