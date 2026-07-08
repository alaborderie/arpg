package farming

import (
	"github.com/anthropics/anthropic-sdk-go"
)

// Tool name constants. These are the exact strings that would appear in an
// anthropic.ToolUseBlock.Name from a real Messages API response, and the
// ToolCall.Name the resolver dispatches on (see resolver.go).
const (
	ToolStartMap      = "start_map"
	ToolSetFarmTarget = "set_farm_target"
	ToolEngageBoss    = "engage_boss"
	ToolVendorItems   = "vendor_items"
	ToolEndSession    = "end_session"
)

// Definitions returns the five tool definitions an LLM agent would receive
// in MessageNewParams.Tools, built from anthropic.ToolParam/
// anthropic.ToolInputSchemaParam - the same types a real
// client.Messages.New call takes (see the anthropic-sdk-go tools example).
// Defining them here as data means the day the real Anthropic-backed
// AgentBrain (see brain.go) is implemented, it passes Definitions() straight
// through; nothing about the schema shape needs to change.
//
// Each JSON Schema is deliberately small and flat: LLM tool-calling accuracy
// degrades with schema complexity, and the resolver only needs a handful of
// scalars/arrays per call (docs/0014).
func Definitions() []anthropic.ToolParam {
	return []anthropic.ToolParam{
		startMapTool(),
		setFarmTargetTool(),
		engageBossTool(),
		vendorItemsTool(),
		endSessionTool(),
	}
}

// ToolUnionParams adapts Definitions() to []anthropic.ToolUnionParam, the
// slice type MessageNewParams.Tools actually takes (the SDK wraps each
// concrete tool param in a union so bash/web-search/custom tools can share a
// slice type).
func ToolUnionParams() []anthropic.ToolUnionParam {
	defs := Definitions()
	tools := make([]anthropic.ToolUnionParam, len(defs))
	for i := range defs {
		tools[i] = anthropic.ToolUnionParam{OfTool: &defs[i]}
	}
	return tools
}

func startMapTool() anthropic.ToolParam {
	return anthropic.ToolParam{
		Name: ToolStartMap,
		Description: anthropic.String(
			"Begin a farming run on the given map. Must be the first tool call " +
				"of a session. Returns the map id and the monster ids available to " +
				"farm on it.",
		),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"map_id": map[string]any{
					"type":        "string",
					"description": "Identifier of the map to run, e.g. \"default\".",
				},
			},
			Required: []string{"map_id"},
		},
	}
}

// StartMapInput is the typed shape of start_map's input, matching
// startMapTool's JSON Schema.
type StartMapInput struct {
	MapID string `json:"map_id"`
}

// StartMapResult is the typed shape of start_map's tool result.
type StartMapResult struct {
	MapID               string   `json:"map_id"`
	AvailableMonsterIDs []string `json:"available_monster_ids"`
}

func setFarmTargetTool() anthropic.ToolParam {
	return anthropic.ToolParam{
		Name: ToolSetFarmTarget,
		Description: anthropic.String(
			"Choose which monster id (from the current map's available monster " +
				"ids) to farm. Must be called after start_map and before " +
				"engage_boss.",
		),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"monster_id": map[string]any{
					"type":        "string",
					"description": "A monster id from the start_map result's available_monster_ids.",
				},
			},
			Required: []string{"monster_id"},
		},
	}
}

// SetFarmTargetInput is the typed shape of set_farm_target's input.
type SetFarmTargetInput struct {
	MonsterID string `json:"monster_id"`
}

// SetFarmTargetResult is the typed shape of set_farm_target's tool result.
type SetFarmTargetResult struct {
	MonsterID   string `json:"monster_id"`
	MonsterName string `json:"monster_name"`
	XPReward    int    `json:"xp_reward"`
}

func engageBossTool() anthropic.ToolParam {
	return anthropic.ToolParam{
		Name: ToolEngageBoss,
		Description: anthropic.String(
			"Fight the current farm target kill_count times. Coarsely resolves " +
				"XP and item drops from shared/monsters.json and " +
				"shared/loot_tables.json rather than simulating individual combat " +
				"rounds. Can be called multiple times in a session to farm in " +
				"batches.",
		),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"monster_id": map[string]any{
					"type":        "string",
					"description": "The monster id to fight; normally the current farm target.",
				},
				"kill_count": map[string]any{
					"type":        "integer",
					"minimum":     1,
					"description": "How many kills to resolve in this batch.",
				},
			},
			Required: []string{"monster_id", "kill_count"},
		},
	}
}

// EngageBossInput is the typed shape of engage_boss's input.
type EngageBossInput struct {
	MonsterID string `json:"monster_id"`
	KillCount int    `json:"kill_count"`
}

// DropSummary is one aggregated drop outcome: count copies of item_id at a
// given rarity dropped during a batch.
type DropSummary struct {
	ItemID string `json:"item_id"`
	Rarity string `json:"rarity"`
	Count  int    `json:"count"`
}

// EngageBossResult is the typed shape of engage_boss's tool result.
type EngageBossResult struct {
	Kills    int           `json:"kills"`
	XPGained int           `json:"xp_gained"`
	Drops    []DropSummary `json:"drops"`
}

func vendorItemsTool() anthropic.ToolParam {
	return anthropic.ToolParam{
		Name: ToolVendorItems,
		Description: anthropic.String(
			"Sell held items for currency. If item_ids is omitted or empty, " +
				"vendors every item currently held by the session.",
		),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{
				"item_ids": map[string]any{
					"type":        "array",
					"items":       map[string]any{"type": "string"},
					"description": "Item ids to sell. Omit to sell everything held.",
				},
			},
		},
	}
}

// VendorItemsInput is the typed shape of vendor_items's input.
type VendorItemsInput struct {
	ItemIDs []string `json:"item_ids,omitempty"`
}

// VendorItemsResult is the typed shape of vendor_items's tool result.
type VendorItemsResult struct {
	ItemsSold      int `json:"items_sold"`
	CurrencyGained int `json:"currency_gained"`
}

func endSessionTool() anthropic.ToolParam {
	return anthropic.ToolParam{
		Name: ToolEndSession,
		Description: anthropic.String(
			"End the farming session and produce its summary. Must be the last " +
				"tool call.",
		),
		InputSchema: anthropic.ToolInputSchemaParam{
			Properties: map[string]any{},
		},
	}
}

// EndSessionInput is the typed shape of end_session's input: no fields, an
// empty object.
type EndSessionInput struct{}

// EndSessionResult is the typed shape of end_session's tool result.
type EndSessionResult struct {
	Summary RunSummary `json:"summary"`
}
