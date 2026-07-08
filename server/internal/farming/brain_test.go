package farming

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/anthropics/anthropic-sdk-go"
)

// TestScriptedBrain_FixedSequence proves ScriptedBrain always drives the
// documented fixed sequence - start_map, set_farm_target, one engage_boss
// per KillBatches entry, vendor_items, end_session - based purely on how
// many calls have happened so far, never on the (here, always-zero) session
// state or transcript contents.
func TestScriptedBrain_FixedSequence(t *testing.T) {
	brain := NewScriptedBrain("map-1", "fallen_imp", []int{5, 3})
	wantSequence := []string{
		ToolStartMap,
		ToolSetFarmTarget,
		ToolEngageBoss,
		ToolEngageBoss,
		ToolVendorItems,
		ToolEndSession,
	}

	var transcript []TranscriptStep
	for i, want := range wantSequence {
		call, ok, err := brain.NextCall(context.Background(), SessionState{}, transcript)
		if err != nil {
			t.Fatalf("step %d: NextCall returned error: %v", i, err)
		}
		if !ok {
			t.Fatalf("step %d: NextCall returned ok=false, want a call for %q", i, want)
		}
		if call.Name != want {
			t.Fatalf("step %d: call.Name = %q, want %q", i, call.Name, want)
		}
		transcript = append(transcript, TranscriptStep{Tool: call.Name, Input: call.Input})
	}

	// One more call after the fixed sequence is exhausted: the brain has
	// nothing further to do.
	call, ok, err := brain.NextCall(context.Background(), SessionState{}, transcript)
	if err != nil {
		t.Fatalf("final NextCall returned error: %v", err)
	}
	if ok {
		t.Fatalf("expected ok=false once the scripted sequence is exhausted, got a call: %+v", call)
	}
}

func TestScriptedBrain_EngageBossInputsMatchKillBatches(t *testing.T) {
	killBatches := []int{7, 2, 9}
	brain := NewScriptedBrain("map-1", "cinder_wraith", killBatches)

	var transcript []TranscriptStep
	// Skip start_map and set_farm_target.
	for i := 0; i < 2; i++ {
		call, _, _ := brain.NextCall(context.Background(), SessionState{}, transcript)
		transcript = append(transcript, TranscriptStep{Tool: call.Name, Input: call.Input})
	}

	for i, want := range killBatches {
		call, ok, err := brain.NextCall(context.Background(), SessionState{}, transcript)
		if err != nil || !ok {
			t.Fatalf("engage_boss step %d: ok=%v err=%v", i, ok, err)
		}
		var in EngageBossInput
		if err := json.Unmarshal(call.Input, &in); err != nil {
			t.Fatalf("engage_boss step %d: decode input: %v", i, err)
		}
		if in.MonsterID != "cinder_wraith" {
			t.Errorf("engage_boss step %d: monster_id = %q, want %q", i, in.MonsterID, "cinder_wraith")
		}
		if in.KillCount != want {
			t.Errorf("engage_boss step %d: kill_count = %d, want %d", i, in.KillCount, want)
		}
		transcript = append(transcript, TranscriptStep{Tool: call.Name, Input: call.Input})
	}
}

func TestNewAnthropicBrain_NotImplemented(t *testing.T) {
	brain, err := NewAnthropicBrain(anthropic.Client{}, "")
	if brain != nil {
		t.Errorf("expected a nil AgentBrain, got %v", brain)
	}
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
}
