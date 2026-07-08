package farming

import (
	"context"
	"fmt"
)

// DefaultMapID is used when a RunRequest doesn't specify one.
const DefaultMapID = "default"

// DefaultMaxSteps bounds a Service.Run loop when a RunRequest doesn't
// specify max_steps. It comfortably covers ScriptedBrain's fixed sequence
// (currently 7 calls) with headroom for a future, less predictable brain.
const DefaultMaxSteps = 20

// DefaultKillBatches is the ScriptedBrain farming plan Service.Run uses:
// three engage_boss batches of five kills each.
var DefaultKillBatches = []int{5, 5, 5}

// RunRequest is the input to Service.Run.
type RunRequest struct {
	// Seed makes the run reproducible: the same Seed, MapID and MaxSteps
	// always drive the same tool-call sequence to the same outcome.
	Seed int64
	// MapID selects the map to farm. Optional; defaults to DefaultMapID.
	MapID string
	// MaxSteps bounds how many tool calls the run loop executes before
	// stopping even if end_session was never called. Optional; defaults to
	// DefaultMaxSteps.
	MaxSteps int
}

// RunOutput is Service.Run's result.
type RunOutput struct {
	Summary    RunSummary       `json:"summary"`
	Transcript []TranscriptStep `json:"transcript"`
}

// Service drives an AgentBrain through a Resolver for one farming run. It
// is the seam internal/httpapi's farm endpoint depends on: replacing the
// scripted brain with a real Anthropic-backed one later is a change to how
// Run picks its AgentBrain, not to Run's signature or to the HTTP layer
// above it.
type Service struct {
	data *Data
}

// NewService builds a Service backed by data (normally loaded once at
// startup via LoadData against the repo's shared/ directory).
func NewService(data *Data) *Service {
	return &Service{data: data}
}

// Run executes one farming session: seeds a Resolver, drives it with a
// ScriptedBrain - the only AgentBrain implementation that exists today, see
// docs/0014 - for up to MaxSteps tool calls or until end_session is called,
// whichever comes first, and returns the resulting transcript and summary.
//
// deviceID identifies the authenticated device that requested the run
// (resolved by the caller via auth.Service/requireDeviceAuth, per
// docs/0013's guidance that M6 should reuse that seam). No run is persisted
// today - see docs/0014's future-work section - but accepting deviceID now
// means adding per-device run history later only touches Service, not the
// HTTP layer or its interface.
func (s *Service) Run(ctx context.Context, deviceID string, req RunRequest) (RunOutput, error) {
	mapID := req.MapID
	if mapID == "" {
		mapID = DefaultMapID
	}
	maxSteps := req.MaxSteps
	if maxSteps <= 0 {
		maxSteps = DefaultMaxSteps
	}

	brain := NewScriptedBrain(mapID, s.defaultFarmTarget(), DefaultKillBatches)
	resolver := NewResolver(s.data, req.Seed)

	out, err := runLoop(ctx, resolver, brain, maxSteps)
	if err != nil {
		return RunOutput{}, fmt.Errorf("farming: run session for device %s: %w", deviceID, err)
	}
	return out, nil
}

// defaultFarmTarget picks the ScriptedBrain's farm target deterministically:
// the first monster in shared/monsters.json's declared order. This is
// deliberately coarse groundwork (docs/0014) - a real agent would choose a
// target based on player state or an explicit request - the stub brain only
// needs *a* valid, in-data target to prove the seam end to end.
func (s *Service) defaultFarmTarget() string {
	if len(s.data.Monsters) == 0 {
		return ""
	}
	return s.data.Monsters[0].ID
}

// runLoop drives brain against resolver until it returns ok=false, calls
// end_session, or maxSteps is reached - whichever happens first. This is
// the shared execution core a real (non-scripted) brain would reuse
// unchanged: only the AgentBrain argument differs.
func runLoop(ctx context.Context, resolver *Resolver, brain AgentBrain, maxSteps int) (RunOutput, error) {
	transcript := make([]TranscriptStep, 0, maxSteps)

	for step := 0; step < maxSteps; step++ {
		call, ok, err := brain.NextCall(ctx, resolver.State(), transcript)
		if err != nil {
			return RunOutput{}, fmt.Errorf("brain: %w", err)
		}
		if !ok {
			break
		}

		result, err := resolver.Execute(call)
		if err != nil {
			return RunOutput{}, fmt.Errorf("execute %s: %w", call.Name, err)
		}
		transcript = append(transcript, TranscriptStep{
			Tool:   call.Name,
			Input:  call.Input,
			Result: result.Output,
		})

		if call.Name == ToolEndSession {
			break
		}
	}

	return RunOutput{Summary: resolver.Summary(), Transcript: transcript}, nil
}
