package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
)

func newTestRouter() http.Handler {
	// Discard logs so test output stays clean.
	return NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)))
}

func TestRoutes(t *testing.T) {
	router := newTestRouter()

	tests := []struct {
		name       string
		method     string
		path       string
		wantStatus int
	}{
		{name: "health returns ok", method: http.MethodGet, path: "/health", wantStatus: http.StatusOK},
		{name: "unknown route is 404", method: http.MethodGet, path: "/nope", wantStatus: http.StatusNotFound},
		{name: "wrong method is 405", method: http.MethodPost, path: "/health", wantStatus: http.StatusMethodNotAllowed},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			req := httptest.NewRequest(tc.method, tc.path, nil)
			rec := httptest.NewRecorder()

			router.ServeHTTP(rec, req)

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d", rec.Code, tc.wantStatus)
			}
		})
	}
}

func TestHealthBody(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	rec := httptest.NewRecorder()

	newTestRouter().ServeHTTP(rec, req)

	if ct := rec.Header().Get("Content-Type"); ct != "application/json" {
		t.Errorf("content-type = %q, want application/json", ct)
	}

	var got healthResponse
	if err := json.NewDecoder(rec.Body).Decode(&got); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if got.Status != "ok" {
		t.Errorf("status = %q, want %q", got.Status, "ok")
	}
	if got.Service != "arpg-server" {
		t.Errorf("service = %q, want %q", got.Service, "arpg-server")
	}
}
