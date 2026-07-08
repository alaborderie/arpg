package httpapi

import (
	"net/http"
	"testing"

	"github.com/alaborderie/arpg/server/internal/farming"
)

func TestRunFarm_RequiresAuth(t *testing.T) {
	router := newTestRouter(t)

	rec := doRequest(t, router, http.MethodPost, "/v1/farm/run", `{"seed":1}`, "")

	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusUnauthorized, rec.Body.String())
	}
}

func TestRunFarm_RejectsInvalidJSON(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	rec := doRequest(t, router, http.MethodPost, "/v1/farm/run", `not json`, token)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusBadRequest, rec.Body.String())
	}
}

func TestRunFarm_HappyPath(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	rec := doRequest(t, router, http.MethodPost, "/v1/farm/run", `{"seed":7}`, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusOK, rec.Body.String())
	}

	var resp farmRunResponse
	decodeBody(t, rec, &resp)

	if len(resp.Transcript) == 0 {
		t.Fatal("expected a non-empty tool-call transcript")
	}
	if resp.Transcript[0].Tool != farming.ToolStartMap {
		t.Errorf("first tool call = %q, want %q", resp.Transcript[0].Tool, farming.ToolStartMap)
	}
	last := resp.Transcript[len(resp.Transcript)-1]
	if last.Tool != farming.ToolEndSession {
		t.Errorf("last tool call = %q, want %q", last.Tool, farming.ToolEndSession)
	}
	if resp.Summary.Kills <= 0 {
		t.Errorf("Summary.Kills = %d, want > 0", resp.Summary.Kills)
	}
	if resp.Summary.XPGained <= 0 {
		t.Errorf("Summary.XPGained = %d, want > 0", resp.Summary.XPGained)
	}
}

func TestRunFarm_SameSeedIsDeterministic(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	rec1 := doRequest(t, router, http.MethodPost, "/v1/farm/run", `{"seed":123,"map_id":"m1"}`, token)
	rec2 := doRequest(t, router, http.MethodPost, "/v1/farm/run", `{"seed":123,"map_id":"m1"}`, token)

	if rec1.Code != http.StatusOK || rec2.Code != http.StatusOK {
		t.Fatalf("status = %d/%d, want both %d", rec1.Code, rec2.Code, http.StatusOK)
	}
	if rec1.Body.String() != rec2.Body.String() {
		t.Fatalf("responses for the same seed differ:\n  run1: %s\n  run2: %s", rec1.Body.String(), rec2.Body.String())
	}
}

func TestRunFarm_RespectsMaxSteps(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	rec := doRequest(t, router, http.MethodPost, "/v1/farm/run", `{"seed":1,"max_steps":2}`, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusOK, rec.Body.String())
	}

	var resp farmRunResponse
	decodeBody(t, rec, &resp)
	if len(resp.Transcript) != 2 {
		t.Fatalf("transcript length = %d, want 2", len(resp.Transcript))
	}
}
