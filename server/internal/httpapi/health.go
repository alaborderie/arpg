package httpapi

import (
	"encoding/json"
	"net/http"
)

// healthResponse is the payload returned by GET /health. It is deliberately
// dependency-free so the endpoint works before any database is wired in.
type healthResponse struct {
	Status  string `json:"status"`
	Service string `json:"service"`
}

// health reports that the process is up and serving.
func (h *handlers) health(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, healthResponse{
		Status:  "ok",
		Service: "arpg-server",
	})
}

// writeJSON encodes payload as JSON with the given status code.
func writeJSON(w http.ResponseWriter, status int, payload any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(payload)
}
