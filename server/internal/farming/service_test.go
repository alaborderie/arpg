package farming

import (
	"context"
	"testing"
)

func loadRealData(t *testing.T) *Data {
	t.Helper()
	data, err := LoadData(realSharedDataDir)
	if err != nil {
		t.Fatalf("LoadData(%q): %v", realSharedDataDir, err)
	}
	return data
}

func TestService_Run_Deterministic(t *testing.T) {
	data := loadRealData(t)
	req := RunRequest{Seed: 4242, MapID: "verdant-fen"}

	run := func() RunOutput {
		svc := NewService(data)
		out, err := svc.Run(context.Background(), "device-a", req)
		if err != nil {
			t.Fatalf("Run failed: %v", err)
		}
		return out
	}

	out1 := run()
	out2 := run()

	if len(out1.Transcript) != len(out2.Transcript) {
		t.Fatalf("transcript length differs: %d vs %d", len(out1.Transcript), len(out2.Transcript))
	}
	for i := range out1.Transcript {
		a, b := out1.Transcript[i], out2.Transcript[i]
		if a.Tool != b.Tool || string(a.Input) != string(b.Input) || string(a.Result) != string(b.Result) {
			t.Fatalf("transcript step %d differs:\n  run1: %+v\n  run2: %+v", i, a, b)
		}
	}
	assertSummaryEqual(t, out1.Summary, out2.Summary)
}

func TestService_Run_FullSequenceCompletesAndEndsSession(t *testing.T) {
	data := loadRealData(t)
	svc := NewService(data)

	out, err := svc.Run(context.Background(), "device-a", RunRequest{Seed: 1})
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	wantSteps := 2 + len(DefaultKillBatches) + 2 // start_map, set_farm_target, N engages, vendor, end_session
	if len(out.Transcript) != wantSteps {
		t.Fatalf("transcript length = %d, want %d", len(out.Transcript), wantSteps)
	}
	if out.Transcript[len(out.Transcript)-1].Tool != ToolEndSession {
		t.Fatalf("last tool call = %q, want %q", out.Transcript[len(out.Transcript)-1].Tool, ToolEndSession)
	}

	wantKills := 0
	for _, batch := range DefaultKillBatches {
		wantKills += batch
	}
	if out.Summary.Kills != wantKills {
		t.Errorf("Summary.Kills = %d, want %d", out.Summary.Kills, wantKills)
	}

	target := data.Monsters[0]
	wantXP := wantKills * target.XPReward
	if out.Summary.XPGained != wantXP {
		t.Errorf("Summary.XPGained = %d, want %d", out.Summary.XPGained, wantXP)
	}
}

func TestService_Run_DefaultsMapIDAndMaxSteps(t *testing.T) {
	data := loadRealData(t)
	svc := NewService(data)

	out, err := svc.Run(context.Background(), "device-a", RunRequest{Seed: 1})
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}

	var startInput StartMapInput
	decode(t, ToolResult{Output: out.Transcript[0].Input}, &startInput)
	if startInput.MapID != DefaultMapID {
		t.Errorf("start_map map_id = %q, want default %q", startInput.MapID, DefaultMapID)
	}
}

func TestService_Run_MaxStepsStopsEarlyWithoutEndSession(t *testing.T) {
	data := loadRealData(t)
	svc := NewService(data)

	out, err := svc.Run(context.Background(), "device-a", RunRequest{Seed: 1, MaxSteps: 2})
	if err != nil {
		t.Fatalf("Run failed: %v", err)
	}
	if len(out.Transcript) != 2 {
		t.Fatalf("transcript length = %d, want 2", len(out.Transcript))
	}
	for _, step := range out.Transcript {
		if step.Tool == ToolEndSession {
			t.Fatal("end_session should not have been reached with max_steps=2")
		}
	}
	// No kills happened yet (only start_map + set_farm_target ran), but a
	// summary must still be produced from whatever partial state exists.
	if out.Summary.Kills != 0 {
		t.Errorf("Summary.Kills = %d, want 0 before any engage_boss call", out.Summary.Kills)
	}
}
