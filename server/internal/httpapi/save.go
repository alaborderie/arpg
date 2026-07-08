package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"

	"github.com/alaborderie/arpg/server/internal/saves"
)

// saveUploadRequest is the body of PUT /v1/save. Payload is the client's
// versioned save envelope (game/domain/save_data.gd, ADR 0012), carried
// opaquely: this server never parses it, only compares SavedAtUnix for
// last-write-wins and stores Payload verbatim.
type saveUploadRequest struct {
	SchemaVersion int64           `json:"schema_version"`
	SavedAtUnix   int64           `json:"saved_at_unix"`
	Payload       json.RawMessage `json:"payload"`
}

// saveResponse is returned by both PUT and GET /v1/save. Payload is omitted
// on a successful upload (the client already has what it sent); it is always
// present on a successful download and on a 409 conflict is left empty since
// the client already has a newer or equal save locally and only needs the
// stored timestamp to decide what to do next.
type saveResponse struct {
	SchemaVersion int64           `json:"schema_version,omitempty"`
	SavedAtUnix   int64           `json:"saved_at_unix"`
	Payload       json.RawMessage `json:"payload,omitempty"`
}

// uploadSave handles PUT /v1/save: last-write-wins upload of the
// authenticated device's save blob. Rejects (409) an upload whose
// saved_at_unix is not strictly newer than what is already stored, returning
// the stored timestamp so the client can fetch it instead of assuming its
// local save "won".
func (h *handlers) uploadSave(w http.ResponseWriter, r *http.Request) {
	deviceID, ok := deviceIDFromContext(r.Context())
	if !ok {
		// requireDeviceAuth always sets this before routing here; a missing
		// value would be a wiring bug, not a client error.
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	var req saveUploadRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	if len(req.Payload) == 0 {
		writeError(w, http.StatusBadRequest, "payload is required")
		return
	}

	stored, err := h.saves.Upload(r.Context(), deviceID, req.SchemaVersion, []byte(req.Payload), req.SavedAtUnix)
	var staleErr *saves.StaleUploadError
	switch {
	case errors.As(err, &staleErr):
		writeJSON(w, http.StatusConflict, saveResponse{SavedAtUnix: staleErr.StoredSavedAtUnix})
		return
	case err != nil:
		h.logger.Error("upload save failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	writeJSON(w, http.StatusOK, saveResponse{SchemaVersion: req.SchemaVersion, SavedAtUnix: stored})
}

// downloadSave handles GET /v1/save: returns the authenticated device's
// stored save blob and its saved_at_unix, or 404 if it has never uploaded
// one.
func (h *handlers) downloadSave(w http.ResponseWriter, r *http.Request) {
	deviceID, ok := deviceIDFromContext(r.Context())
	if !ok {
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	schemaVersion, payload, savedAtUnix, err := h.saves.Download(r.Context(), deviceID)
	if errors.Is(err, saves.ErrNotFound) {
		writeError(w, http.StatusNotFound, "no save stored for this device")
		return
	}
	if err != nil {
		h.logger.Error("download save failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	writeJSON(w, http.StatusOK, saveResponse{
		SchemaVersion: schemaVersion,
		SavedAtUnix:   savedAtUnix,
		Payload:       json.RawMessage(payload),
	})
}
