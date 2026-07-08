// Package farming implements the M6 AI-farming groundwork: a deterministic,
// server-side map-run resolver that reuses the same shared/*.json balance
// data as the Godot client (ADR 0005), a JSON-Schema tool-call surface an LLM
// agent could drive (ADR 0014), and a stub scripted "brain" that exercises it
// without ever calling a real model. See docs/0014 for the full design and
// docs/0013 for why this lives alongside internal/saves rather than inside
// it.
package farming

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// Monster is the subset of a shared/monsters.json entry the resolver needs.
// Unknown fields (armor, resistances, ai, ...) are ignored by
// encoding/json - this struct only claims the balance numbers the coarse
// simulation actually uses.
type Monster struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	XPReward  int    `json:"xp_reward"`
	MaxHealth int    `json:"max_health"`
}

type monstersFile struct {
	SchemaVersion int       `json:"schema_version"`
	Monsters      []Monster `json:"monsters"`
}

// ItemBase is the subset of a shared/items.json base entry the resolver
// needs to describe a drop.
type ItemBase struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Slot string `json:"slot"`
}

type itemsFile struct {
	SchemaVersion int        `json:"schema_version"`
	Bases         []ItemBase `json:"bases"`
	// Affixes are part of shared/items.json but not read here: the coarse
	// vendor-value model (docs/0014) prices a drop by base + rarity only, not
	// its rolled affixes, so the affix pool is out of scope for M6.
}

// Rarity is a shared/loot_tables.json rarity bucket: a relative weight for
// the weighted draw, in file order (the same "order is the pick order"
// contract the client's LootRoller relies on - reordering entries changes
// roll outcomes).
type Rarity struct {
	ID            string `json:"id"`
	Weight        int    `json:"weight"`
	AffixCountMax int    `json:"affix_count_max"`
}

// LootTable is a shared/loot_tables.json per-monster drop table.
type LootTable struct {
	MonsterID  string   `json:"monster_id"`
	DropChance float64  `json:"drop_chance"`
	BasePool   []string `json:"base_pool"`
}

type lootTablesFile struct {
	SchemaVersion int         `json:"schema_version"`
	Rarities      []Rarity    `json:"rarities"`
	Tables        []LootTable `json:"tables"`
}

// Data is the loaded, indexed subset of shared/*.json the farming resolver
// needs. It never reads shared/combat.json or shared/player.json - the
// coarse simulation resolves monster kills and loot, not live combat rolls
// (see docs/0014 "coarse approximation" section for why that's an
// acceptable simplification for AI-farming groundwork).
type Data struct {
	Monsters      []Monster
	MonsterByID   map[string]Monster
	Items         []ItemBase
	ItemByID      map[string]ItemBase
	Rarities      []Rarity
	LootByMonster map[string]LootTable
}

// LoadData reads monsters.json, items.json and loot_tables.json from dir
// (normally the repo-root shared/ directory - the single source of balance
// truth per ADR 0005) and indexes them for lookup. dir is path-configurable
// deliberately: production resolves it from config.SharedDataDir, tests pass
// a relative path straight to the real repo shared/ directory so they never
// drift from what the client loads.
func LoadData(dir string) (*Data, error) {
	var monsters monstersFile
	if err := readJSON(filepath.Join(dir, "monsters.json"), &monsters); err != nil {
		return nil, fmt.Errorf("farming: load monsters: %w", err)
	}
	var items itemsFile
	if err := readJSON(filepath.Join(dir, "items.json"), &items); err != nil {
		return nil, fmt.Errorf("farming: load items: %w", err)
	}
	var lootTables lootTablesFile
	if err := readJSON(filepath.Join(dir, "loot_tables.json"), &lootTables); err != nil {
		return nil, fmt.Errorf("farming: load loot tables: %w", err)
	}

	data := &Data{
		Monsters:      monsters.Monsters,
		MonsterByID:   make(map[string]Monster, len(monsters.Monsters)),
		Items:         items.Bases,
		ItemByID:      make(map[string]ItemBase, len(items.Bases)),
		Rarities:      lootTables.Rarities,
		LootByMonster: make(map[string]LootTable, len(lootTables.Tables)),
	}
	for _, m := range monsters.Monsters {
		data.MonsterByID[m.ID] = m
	}
	for _, i := range items.Bases {
		data.ItemByID[i.ID] = i
	}
	for _, t := range lootTables.Tables {
		data.LootByMonster[t.MonsterID] = t
	}
	return data, nil
}

func readJSON(path string, v any) error {
	b, err := os.ReadFile(path) //nolint:gosec // path is caller-configured (config/tests), not request-derived.
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("unmarshal %s: %w", path, err)
	}
	return nil
}
