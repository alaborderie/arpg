package farming

import "testing"

// realSharedDataDir points at the repo-root shared/ directory - the actual
// single source of balance truth (ADR 0005) - from this package's location,
// server/internal/farming. Tests load these real files rather than fixtures
// so a change to shared/*.json that this package can't handle fails here,
// not just in the Godot client.
const realSharedDataDir = "../../../shared"

func TestLoadData_RealSharedFiles(t *testing.T) {
	data, err := LoadData(realSharedDataDir)
	if err != nil {
		t.Fatalf("LoadData(%q) failed: %v", realSharedDataDir, err)
	}

	if len(data.Monsters) == 0 {
		t.Fatal("expected at least one monster loaded from shared/monsters.json")
	}
	fallenImp, ok := data.MonsterByID["fallen_imp"]
	if !ok {
		t.Fatal(`expected "fallen_imp" in MonsterByID`)
	}
	if fallenImp.XPReward != 5 {
		t.Errorf("fallen_imp.XPReward = %d, want 5", fallenImp.XPReward)
	}
	if fallenImp.Name == "" {
		t.Error("fallen_imp.Name is empty")
	}

	rustySword, ok := data.ItemByID["rusty_sword"]
	if !ok {
		t.Fatal(`expected "rusty_sword" in ItemByID`)
	}
	if rustySword.Slot != "weapon" {
		t.Errorf("rusty_sword.Slot = %q, want %q", rustySword.Slot, "weapon")
	}

	if len(data.Rarities) == 0 {
		t.Fatal("expected at least one rarity loaded from shared/loot_tables.json")
	}
	wantRarities := map[string]bool{"normal": false, "magic": false, "rare": false}
	for _, r := range data.Rarities {
		if _, known := wantRarities[r.ID]; known {
			wantRarities[r.ID] = true
		}
	}
	for id, seen := range wantRarities {
		if !seen {
			t.Errorf("expected rarity %q to be loaded", id)
		}
	}

	table, ok := data.LootByMonster["fallen_imp"]
	if !ok {
		t.Fatal(`expected "fallen_imp" in LootByMonster`)
	}
	if table.DropChance != 0.35 {
		t.Errorf("fallen_imp loot table drop_chance = %v, want 0.35", table.DropChance)
	}
	if len(table.BasePool) == 0 {
		t.Error("expected fallen_imp loot table to have a non-empty base_pool")
	}
}

func TestLoadData_MissingDirectory(t *testing.T) {
	if _, err := LoadData("this-directory-does-not-exist"); err == nil {
		t.Fatal("expected an error loading a nonexistent shared data directory, got nil")
	}
}
