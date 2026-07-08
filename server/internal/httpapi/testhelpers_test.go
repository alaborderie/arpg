package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alaborderie/arpg/server/internal/auth"
	"github.com/alaborderie/arpg/server/internal/farming"
	"github.com/alaborderie/arpg/server/internal/saves"
	"github.com/alaborderie/arpg/server/internal/store"
)

// testSharedDataDir points at the repo-root shared/ directory from this
// package's location, server/internal/httpapi - the same real balance data
// internal/farming's own tests load, so the farm endpoint is exercised
// against the actual shared/monsters.json roster rather than a fixture.
const testSharedDataDir = "../../../shared"

// newTestRouter builds a router backed by a fresh, migrated, temp-file SQLite
// database - the real auth and saves services, not fakes, so these tests
// exercise the actual last-write-wins and token-resolution logic end to end
// (minus the network). Each test gets its own database file under t.TempDir,
// so tests never share state.
func newTestRouter(t *testing.T) http.Handler {
	t.Helper()

	dbPath := filepath.Join(t.TempDir(), "test.db")
	st, err := store.Open(context.Background(), dbPath)
	if err != nil {
		t.Fatalf("open test store: %v", err)
	}
	t.Cleanup(func() {
		_ = st.Close()
	})

	authSvc := auth.NewService(st.Queries)
	saveSvc := saves.NewService(st.Queries)

	farmData, err := farming.LoadData(testSharedDataDir)
	if err != nil {
		t.Fatalf("load shared data for farm service: %v", err)
	}
	farmSvc := farming.NewService(farmData)

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))

	return NewRouter(logger, authSvc, saveSvc, farmSvc)
}

// registerDeviceForTest registers deviceID against router and returns its
// bearer token, failing the test on any error. A small shared helper so
// auth_test.go and save_test.go don't each reimplement the request.
func registerDeviceForTest(t *testing.T, router http.Handler, deviceID string) string {
	t.Helper()

	rec := doRequest(t, router, http.MethodPost, "/v1/auth/device", `{"device_id":"`+deviceID+`"}`, "")
	if rec.Code != http.StatusOK {
		t.Fatalf("register device: status = %d, body = %s", rec.Code, rec.Body.String())
	}

	var resp deviceAuthResponse
	decodeBody(t, rec, &resp)
	return resp.Token
}

// doRequest performs a single request against router with an optional JSON
// body and bearer token, returning the recorded response.
func doRequest(t *testing.T, router http.Handler, method, path, body, bearerToken string) *httptest.ResponseRecorder {
	t.Helper()

	var reader *strings.Reader
	if body != "" {
		reader = strings.NewReader(body)
	} else {
		reader = strings.NewReader("")
	}
	req := httptest.NewRequest(method, path, reader)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if bearerToken != "" {
		req.Header.Set("Authorization", "Bearer "+bearerToken)
	}
	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)
	return rec
}

// decodeBody JSON-decodes rec's body into v, failing the test on error.
func decodeBody(t *testing.T, rec *httptest.ResponseRecorder, v any) {
	t.Helper()
	if err := json.NewDecoder(rec.Body).Decode(v); err != nil {
		t.Fatalf("decode response body %q: %v", rec.Body.String(), err)
	}
}
