package httpapi

import (
	"encoding/json"
	"net/http"

	"github.com/alaborderie/arpg/server/internal/farming"
)

// farmRunRequest is the body of POST /v1/farm/run. map_id and max_steps are
// optional; farming.Service applies its own defaults (DefaultMapID,
// DefaultMaxSteps) when they're zero-valued.
type farmRunRequest struct {
	Seed     int64  `json:"seed"`
	MapID    string `json:"map_id,omitempty"`
	MaxSteps int    `json:"max_steps,omitempty"`
}

// farmRunResponse is the body returned on a successful run: the final
// summary and the full tool-call transcript that produced it, proving the
// resolver/tool-schema seam end to end without any LLM involved (M6,
// docs/0014). No run is persisted - see docs/0014's future-work section.
type farmRunResponse struct {
	Summary    farming.RunSummary       `json:"summary"`
	Transcript []farming.TranscriptStep `json:"transcript"`
}

// runFarm handles POST /v1/farm/run: drives the M6 stub AgentBrain through
// the deterministic farming resolver for the authenticated device and
// returns the run's summary and transcript. Requires requireDeviceAuth, per
// docs/0013's note that M6 should reuse the existing device-auth seam
// rather than invent its own.
func (h *handlers) runFarm(w http.ResponseWriter, r *http.Request) {
	deviceID, ok := deviceIDFromContext(r.Context())
	if !ok {
		// requireDeviceAuth always sets this before routing here; a missing
		// value would be a wiring bug, not a client error.
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	var req farmRunRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}

	out, err := h.farm.Run(r.Context(), deviceID, farming.RunRequest{
		Seed:     req.Seed,
		MapID:    req.MapID,
		MaxSteps: req.MaxSteps,
	})
	if err != nil {
		h.logger.Error("farm run failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	writeJSON(w, http.StatusOK, farmRunResponse{Summary: out.Summary, Transcript: out.Transcript})
}
