package farming

import (
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"sort"
)

// Sentinel errors the resolver returns for invalid tool-call sequencing or
// input. These are distinguished (rather than one generic error) so callers
// and tests can assert on the specific failure mode.
var (
	ErrSessionNotStarted     = errors.New("farming: start_map must be called before any other tool")
	ErrSessionAlreadyStarted = errors.New("farming: start_map has already been called for this session")
	ErrSessionEnded          = errors.New("farming: session has already ended, no further tool calls are accepted")
	ErrUnknownTool           = errors.New("farming: unknown tool name")
	ErrUnknownMonster        = errors.New("farming: unknown monster id")
	ErrInvalidKillCount      = errors.New("farming: kill_count must be >= 1")
)

// ToolCall is one tool invocation the resolver executes: the tool name and
// its raw JSON input, exactly as it would arrive in a real
// anthropic.ToolUseBlock (Name + Input). Kept independent of the anthropic
// SDK's own types so the resolver has zero dependency on it - only tools.go
// (schema definitions) and the future real AgentBrain need the SDK.
type ToolCall struct {
	Name  string          `json:"tool"`
	Input json.RawMessage `json:"input"`
}

// ToolResult is what Execute returns for a ToolCall: the same tool name and
// the raw JSON of one of the typed *Result structs in tools.go.
type ToolResult struct {
	Name   string          `json:"tool"`
	Output json.RawMessage `json:"output"`
}

// TranscriptStep pairs one ToolCall with its ToolResult, in execution order.
// This is the wire shape returned by the HTTP endpoint (see
// internal/httpapi/farm.go) - proof of exactly what the agent did and what
// the resolver computed for it, with no LLM involved.
type TranscriptStep struct {
	Tool   string          `json:"tool"`
	Input  json.RawMessage `json:"input"`
	Result json.RawMessage `json:"result"`
}

// RunSummary is the end-of-session rollup: total kills and XP across every
// engage_boss batch, currency earned from every vendor_items call, and
// whatever items are still held (not vendored) when the session ends.
type RunSummary struct {
	Kills          int           `json:"kills"`
	XPGained       int           `json:"xp_gained"`
	CurrencyGained int           `json:"currency_gained"`
	ItemsKept      []DropSummary `json:"items_kept"`
}

// SessionState is the resolver's state as of the last executed tool call -
// enough for an AgentBrain to decide its next call (docs/0014's
// "given the session state, returns the next tool call" seam).
type SessionState struct {
	MapID               string
	FarmTarget          string
	AvailableMonsterIDs []string
	Kills               int
	XPGained            int
	CurrencyGained      int
	Ended               bool
}

type sessionPhase int

const (
	phaseNotStarted sessionPhase = iota
	phaseStarted
	phaseEnded
)

// Resolver executes ToolCalls against an abstract farming session: seeded
// deterministic RNG (math/rand/v2, explicit seed) plus the loaded shared/
// balance Data. Same seed + same tool-call sequence always produces the same
// transcript and summary - there is no wall-clock, no goroutine
// interleaving and no hidden global state involved in a roll.
type Resolver struct {
	data *Data
	rng  *rand.Rand

	phase      sessionPhase
	mapID      string
	farmTarget string
	available  []string
	kills      int
	xpGained   int
	currency   int
	// inventory holds itemID -> rarityID -> count for items dropped but not
	// yet vendored.
	inventory map[string]map[string]int
}

// NewResolver builds a Resolver over data, seeded with seed. Two Resolvers
// built with the same data and seed, fed the same ToolCall sequence, always
// produce identical results - this is the determinism guarantee tested in
// resolver_test.go.
func NewResolver(data *Data, seed int64) *Resolver {
	return &Resolver{
		data:      data,
		rng:       rand.New(rand.NewPCG(0, uint64(seed))), //nolint:gosec // deterministic simulation RNG, not security-sensitive.
		inventory: make(map[string]map[string]int),
	}
}

// State returns a snapshot of the resolver's current state.
func (r *Resolver) State() SessionState {
	available := make([]string, len(r.available))
	copy(available, r.available)
	return SessionState{
		MapID:               r.mapID,
		FarmTarget:          r.farmTarget,
		AvailableMonsterIDs: available,
		Kills:               r.kills,
		XPGained:            r.xpGained,
		CurrencyGained:      r.currency,
		Ended:               r.phase == phaseEnded,
	}
}

// Summary computes the RunSummary from the resolver's current state. Called
// both by the end_session tool handler and by a caller (internal/farming's
// Service) that stops the loop at max_steps before end_session was reached,
// so a run always has a summary even if the scripted/real brain never
// explicitly wrapped up.
func (r *Resolver) Summary() RunSummary {
	return RunSummary{
		Kills:          r.kills,
		XPGained:       r.xpGained,
		CurrencyGained: r.currency,
		ItemsKept:      r.heldItems(),
	}
}

// Execute dispatches call to the matching tool handler and returns its
// typed result, JSON-encoded into a ToolResult.
func (r *Resolver) Execute(call ToolCall) (ToolResult, error) {
	if r.phase == phaseEnded {
		return ToolResult{}, ErrSessionEnded
	}
	if call.Name != ToolStartMap && r.phase == phaseNotStarted {
		return ToolResult{}, ErrSessionNotStarted
	}

	var (
		out any
		err error
	)
	switch call.Name {
	case ToolStartMap:
		out, err = r.handleStartMap(call.Input)
	case ToolSetFarmTarget:
		out, err = r.handleSetFarmTarget(call.Input)
	case ToolEngageBoss:
		out, err = r.handleEngageBoss(call.Input)
	case ToolVendorItems:
		out, err = r.handleVendorItems(call.Input)
	case ToolEndSession:
		out, err = r.handleEndSession(call.Input)
	default:
		return ToolResult{}, fmt.Errorf("%w: %q", ErrUnknownTool, call.Name)
	}
	if err != nil {
		return ToolResult{}, err
	}

	output, err := json.Marshal(out)
	if err != nil {
		return ToolResult{}, fmt.Errorf("farming: encode %s result: %w", call.Name, err)
	}
	return ToolResult{Name: call.Name, Output: output}, nil
}

func (r *Resolver) handleStartMap(input json.RawMessage) (StartMapResult, error) {
	if r.phase != phaseNotStarted {
		return StartMapResult{}, ErrSessionAlreadyStarted
	}
	var in StartMapInput
	if err := json.Unmarshal(input, &in); err != nil {
		return StartMapResult{}, fmt.Errorf("farming: decode %s input: %w", ToolStartMap, err)
	}

	// Coarse approximation (docs/0014): there is no shared/maps.json, so
	// every map draws from the full monster roster in shared/monsters.json.
	// map_id is carried through opaquely for now; a later milestone that
	// adds zone-restricted monster pools is an additive Data change here,
	// not a resolver redesign.
	available := make([]string, len(r.data.Monsters))
	for i, m := range r.data.Monsters {
		available[i] = m.ID
	}

	r.phase = phaseStarted
	r.mapID = in.MapID
	r.available = available

	return StartMapResult{MapID: in.MapID, AvailableMonsterIDs: available}, nil
}

func (r *Resolver) handleSetFarmTarget(input json.RawMessage) (SetFarmTargetResult, error) {
	var in SetFarmTargetInput
	if err := json.Unmarshal(input, &in); err != nil {
		return SetFarmTargetResult{}, fmt.Errorf("farming: decode %s input: %w", ToolSetFarmTarget, err)
	}
	monster, ok := r.data.MonsterByID[in.MonsterID]
	if !ok {
		return SetFarmTargetResult{}, fmt.Errorf("%w: %q", ErrUnknownMonster, in.MonsterID)
	}

	r.farmTarget = monster.ID
	return SetFarmTargetResult{MonsterID: monster.ID, MonsterName: monster.Name, XPReward: monster.XPReward}, nil
}

func (r *Resolver) handleEngageBoss(input json.RawMessage) (EngageBossResult, error) {
	var in EngageBossInput
	if err := json.Unmarshal(input, &in); err != nil {
		return EngageBossResult{}, fmt.Errorf("farming: decode %s input: %w", ToolEngageBoss, err)
	}
	monster, ok := r.data.MonsterByID[in.MonsterID]
	if !ok {
		return EngageBossResult{}, fmt.Errorf("%w: %q", ErrUnknownMonster, in.MonsterID)
	}
	if in.KillCount < 1 {
		return EngageBossResult{}, ErrInvalidKillCount
	}

	xpGained := in.KillCount * monster.XPReward
	batchDrops := make(map[string]map[string]int)

	if table, ok := r.data.LootByMonster[monster.ID]; ok && len(table.BasePool) > 0 && len(r.data.Rarities) > 0 {
		for i := 0; i < in.KillCount; i++ {
			// Fixed draw order per kill (drop roll, then base, then
			// rarity) mirrors the client LootRoller's contract (ADR
			// 0011): outcomes depend only on kill order, not on anything
			// else consuming the RNG stream.
			if r.rng.Float64() >= table.DropChance {
				continue
			}
			itemID := table.BasePool[r.rng.IntN(len(table.BasePool))]
			rarity := r.rollRarity()
			if batchDrops[itemID] == nil {
				batchDrops[itemID] = make(map[string]int)
			}
			batchDrops[itemID][rarity.ID]++
			r.addToInventory(itemID, rarity.ID, 1)
		}
	}

	r.kills += in.KillCount
	r.xpGained += xpGained

	return EngageBossResult{
		Kills:    in.KillCount,
		XPGained: xpGained,
		Drops:    flattenDrops(batchDrops),
	}, nil
}

// rollRarity draws a rarity from r.data.Rarities weighted by Weight, in
// file order - the same weighted-draw shape the client's LootRoller uses
// for rarity (ADR 0011), just without the affix rolls that determine a
// specific item's stats, since M6 only needs a rarity to price a vendor
// sale (see rarityValue).
func (r *Resolver) rollRarity() Rarity {
	total := 0
	for _, rarity := range r.data.Rarities {
		total += rarity.Weight
	}
	if total <= 0 {
		return r.data.Rarities[0]
	}
	roll := r.rng.IntN(total)
	acc := 0
	for _, rarity := range r.data.Rarities {
		acc += rarity.Weight
		if roll < acc {
			return rarity
		}
	}
	return r.data.Rarities[len(r.data.Rarities)-1]
}

func (r *Resolver) addToInventory(itemID, rarityID string, count int) {
	if r.inventory[itemID] == nil {
		r.inventory[itemID] = make(map[string]int)
	}
	r.inventory[itemID][rarityID] += count
}

func (r *Resolver) handleVendorItems(input json.RawMessage) (VendorItemsResult, error) {
	var in VendorItemsInput
	if len(input) > 0 {
		if err := json.Unmarshal(input, &in); err != nil {
			return VendorItemsResult{}, fmt.Errorf("farming: decode %s input: %w", ToolVendorItems, err)
		}
	}

	sellAll := len(in.ItemIDs) == 0
	wanted := make(map[string]bool, len(in.ItemIDs))
	for _, id := range in.ItemIDs {
		wanted[id] = true
	}

	itemsSold := 0
	currencyGained := 0
	for itemID, rarities := range r.inventory {
		if !sellAll && !wanted[itemID] {
			continue
		}
		for rarityID, count := range rarities {
			itemsSold += count
			currencyGained += count * rarityValue(rarityID, r.data.Rarities)
		}
		delete(r.inventory, itemID)
	}

	r.currency += currencyGained
	return VendorItemsResult{ItemsSold: itemsSold, CurrencyGained: currencyGained}, nil
}

// rarityValue is the coarse vendor-price model (docs/0014): 1 currency plus
// the rarity's max affix count from shared/loot_tables.json, so a normal
// item (0 affixes) sells for 1, a rare (up to 4 affixes) sells for 5 - it
// reuses the same data the real loot roll uses rather than inventing a
// separate pricing table, at the cost of ignoring which specific affixes
// actually rolled.
func rarityValue(rarityID string, rarities []Rarity) int {
	for _, r := range rarities {
		if r.ID == rarityID {
			return 1 + r.AffixCountMax
		}
	}
	return 1
}

func (r *Resolver) handleEndSession(_ json.RawMessage) (EndSessionResult, error) {
	r.phase = phaseEnded
	return EndSessionResult{Summary: r.Summary()}, nil
}

// heldItems flattens the resolver's inventory into a deterministic,
// sorted-by-item-then-rarity slice for RunSummary.ItemsKept.
func (r *Resolver) heldItems() []DropSummary {
	itemIDs := make([]string, 0, len(r.inventory))
	for id := range r.inventory {
		itemIDs = append(itemIDs, id)
	}
	sort.Strings(itemIDs)

	out := make([]DropSummary, 0, len(itemIDs))
	for _, id := range itemIDs {
		rarities := r.inventory[id]
		rarityIDs := make([]string, 0, len(rarities))
		for rid := range rarities {
			rarityIDs = append(rarityIDs, rid)
		}
		sort.Strings(rarityIDs)
		for _, rid := range rarityIDs {
			if count := rarities[rid]; count > 0 {
				out = append(out, DropSummary{ItemID: id, Rarity: rid, Count: count})
			}
		}
	}
	return out
}

func flattenDrops(drops map[string]map[string]int) []DropSummary {
	itemIDs := make([]string, 0, len(drops))
	for id := range drops {
		itemIDs = append(itemIDs, id)
	}
	sort.Strings(itemIDs)

	out := make([]DropSummary, 0, len(itemIDs))
	for _, id := range itemIDs {
		rarities := drops[id]
		rarityIDs := make([]string, 0, len(rarities))
		for rid := range rarities {
			rarityIDs = append(rarityIDs, rid)
		}
		sort.Strings(rarityIDs)
		for _, rid := range rarityIDs {
			out = append(out, DropSummary{ItemID: id, Rarity: rid, Count: rarities[rid]})
		}
	}
	return out
}
