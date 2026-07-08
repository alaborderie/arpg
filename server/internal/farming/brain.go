package farming

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/anthropics/anthropic-sdk-go"
)

// AgentBrain decides the next tool call given the session's current state
// and the transcript so far. This is the seam a real LLM integration plugs
// into (docs/0014): the tool schema (tools.go) and the resolver
// (resolver.go) are already shaped for it, so a real implementation only
// has to satisfy this interface.
type AgentBrain interface {
	// NextCall returns the next ToolCall to execute, or ok=false if the
	// brain has nothing further to do - a safety fallback the run loop
	// (see Service.Run) uses to stop; a well-behaved brain should always
	// eventually call end_session itself instead of relying on it.
	NextCall(ctx context.Context, state SessionState, transcript []TranscriptStep) (call ToolCall, ok bool, err error)
}

// ScriptedBrain is a deterministic, hard-coded AgentBrain: the ONE stub
// implementation the milestone calls for, used by tests and by
// Service until a real LLM-backed brain exists. It always issues the same
// fixed sequence of tool calls for a given configuration: start_map,
// set_farm_target, one engage_boss call per entry in KillBatches,
// vendor_items, then end_session.
//
// The sequence depends only on how many calls have been made so far (len of
// the transcript), never on the resolver's state or any randomness - so a
// ScriptedBrain configuration always drives the same tool-call sequence.
// Combined with a seeded Resolver, that is the whole determinism story
// (resolver_test.go and service_test.go both exercise it end to end).
type ScriptedBrain struct {
	MapID       string
	MonsterID   string
	KillBatches []int // e.g. []int{5, 5, 5}: three engage_boss calls of 5 kills each.
}

// NewScriptedBrain builds a ScriptedBrain. killBatches should be non-empty;
// each entry becomes the kill_count of one engage_boss call, in order.
func NewScriptedBrain(mapID, monsterID string, killBatches []int) *ScriptedBrain {
	batches := make([]int, len(killBatches))
	copy(batches, killBatches)
	return &ScriptedBrain{MapID: mapID, MonsterID: monsterID, KillBatches: batches}
}

// NextCall implements AgentBrain.
func (b *ScriptedBrain) NextCall(_ context.Context, _ SessionState, transcript []TranscriptStep) (ToolCall, bool, error) {
	step := len(transcript)
	switch {
	case step == 0:
		return mustToolCall(ToolStartMap, StartMapInput{MapID: b.MapID}), true, nil
	case step == 1:
		return mustToolCall(ToolSetFarmTarget, SetFarmTargetInput{MonsterID: b.MonsterID}), true, nil
	case step < 2+len(b.KillBatches):
		killCount := b.KillBatches[step-2]
		return mustToolCall(ToolEngageBoss, EngageBossInput{MonsterID: b.MonsterID, KillCount: killCount}), true, nil
	case step == 2+len(b.KillBatches):
		return mustToolCall(ToolVendorItems, VendorItemsInput{}), true, nil
	case step == 3+len(b.KillBatches):
		return mustToolCall(ToolEndSession, EndSessionInput{}), true, nil
	default:
		return ToolCall{}, false, nil
	}
}

// mustToolCall marshals a fixed, ScriptedBrain-owned input literal into a
// ToolCall. Every caller passes one of the plain input structs in tools.go
// (strings/ints/slices only), which cannot fail to marshal - panicking here
// would be wrong for arbitrary/untrusted input, but this function only ever
// sees literals this package constructs itself.
func mustToolCall(name string, input any) ToolCall {
	raw, err := json.Marshal(input)
	if err != nil {
		panic(fmt.Sprintf("farming: marshal %s input: %v", name, err))
	}
	return ToolCall{Name: name, Input: raw}
}

// ErrAnthropicBrainNotImplemented is returned by NewAnthropicBrain.
var ErrAnthropicBrainNotImplemented = errors.New(
	"farming: Anthropic-backed AgentBrain is not implemented (M6 ships tool " +
		"schemas and the resolver seam only - see docs/0014)",
)

// NewAnthropicBrain is the constructor stub for the future AgentBrain
// backed by a real client.Messages.New call using Definitions()/
// ToolUnionParams() as its Tools. It always returns
// ErrAnthropicBrainNotImplemented: wiring an actual model call is
// deliberately out of scope for M6 (docs/0014) so that this package makes
// zero network calls and needs zero API keys, in production or in tests.
//
// When implemented for real, it will additionally need:
//   - An API key (ANTHROPIC_API_KEY via env, never committed) threaded
//     through client construction.
//   - A model choice (client and model are already accepted here so the
//     signature doesn't change later).
//   - A loop-guard independent of Service's max_steps: an LLM agent, unlike
//     ScriptedBrain, is not guaranteed to call end_session on its own, so
//     the real implementation needs its own bounded tool-call budget and a
//     policy for what happens when it's exhausted without ending cleanly.
//   - A decision on whether/how a run's transcript is persisted (M6 does
//     not persist runs at all - see docs/0014's "future work").
func NewAnthropicBrain(_ anthropic.Client, _ anthropic.Model) (AgentBrain, error) {
	return nil, ErrAnthropicBrainNotImplemented
}
