package httpapi

import (
	"fmt"
	"net/http"
	"testing"
)

func TestDownloadSave_NotFoundBeforeAnyUpload(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	rec := doRequest(t, router, http.MethodGet, "/v1/save", "", token)

	if rec.Code != http.StatusNotFound {
		t.Fatalf("status = %d, want %d (body %s)", rec.Code, http.StatusNotFound, rec.Body.String())
	}
}

func TestUploadThenDownloadSave_HappyPath(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	body := `{"schema_version":1,"saved_at_unix":1000,"payload":{"master_seed":42,"player":{"health":85}}}`
	uploadRec := doRequest(t, router, http.MethodPut, "/v1/save", body, token)
	if uploadRec.Code != http.StatusOK {
		t.Fatalf("upload status = %d, want %d (body %s)", uploadRec.Code, http.StatusOK, uploadRec.Body.String())
	}
	var uploadResp saveResponse
	decodeBody(t, uploadRec, &uploadResp)
	if uploadResp.SavedAtUnix != 1000 {
		t.Errorf("upload saved_at_unix = %d, want 1000", uploadResp.SavedAtUnix)
	}

	downloadRec := doRequest(t, router, http.MethodGet, "/v1/save", "", token)
	if downloadRec.Code != http.StatusOK {
		t.Fatalf("download status = %d, want %d (body %s)", downloadRec.Code, http.StatusOK, downloadRec.Body.String())
	}
	var downloadResp saveResponse
	decodeBody(t, downloadRec, &downloadResp)
	if downloadResp.SavedAtUnix != 1000 {
		t.Errorf("download saved_at_unix = %d, want 1000", downloadResp.SavedAtUnix)
	}
	if downloadResp.SchemaVersion != 1 {
		t.Errorf("download schema_version = %d, want 1", downloadResp.SchemaVersion)
	}
	wantPayload := `{"master_seed":42,"player":{"health":85}}`
	if string(downloadResp.Payload) != wantPayload {
		t.Errorf("download payload = %s, want %s (must round-trip byte-for-byte: the server never parses it)", downloadResp.Payload, wantPayload)
	}
}

// TestUploadSave_RejectsStaleUpload covers last-write-wins in the direction
// the milestone calls "reject uploads older than what's stored": once a save
// with saved_at_unix=2000 is on the server, an upload claiming an older or
// equal timestamp must be rejected and the server's copy left untouched.
func TestUploadSave_RejectsStaleUpload(t *testing.T) {
	tests := []struct {
		name             string
		staleSavedAtUnix int64
	}{
		{name: "older timestamp", staleSavedAtUnix: 1000},
		{name: "equal timestamp", staleSavedAtUnix: 2000},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			router := newTestRouter(t)
			token := registerDeviceForTest(t, router, "device-a")

			newer := `{"schema_version":1,"saved_at_unix":2000,"payload":{"tag":"newer"}}`
			if rec := doRequest(t, router, http.MethodPut, "/v1/save", newer, token); rec.Code != http.StatusOK {
				t.Fatalf("seed upload status = %d, want %d", rec.Code, http.StatusOK)
			}

			stale := fmt.Sprintf(`{"schema_version":1,"saved_at_unix":%d,"payload":{"tag":"stale"}}`, tc.staleSavedAtUnix)
			rec := doRequest(t, router, http.MethodPut, "/v1/save", stale, token)
			if rec.Code != http.StatusConflict {
				t.Fatalf("stale upload status = %d, want %d (body %s)", rec.Code, http.StatusConflict, rec.Body.String())
			}
			var conflict saveResponse
			decodeBody(t, rec, &conflict)
			if conflict.SavedAtUnix != 2000 {
				t.Errorf("conflict reports stored saved_at_unix = %d, want 2000", conflict.SavedAtUnix)
			}

			// The rejected upload must not have overwritten the stored save.
			downloadRec := doRequest(t, router, http.MethodGet, "/v1/save", "", token)
			var downloadResp saveResponse
			decodeBody(t, downloadRec, &downloadResp)
			if downloadResp.SavedAtUnix != 2000 {
				t.Errorf("stored saved_at_unix = %d after rejected upload, want unchanged 2000", downloadResp.SavedAtUnix)
			}
			if string(downloadResp.Payload) != `{"tag":"newer"}` {
				t.Errorf("stored payload = %s, want unchanged {\"tag\":\"newer\"}", downloadResp.Payload)
			}
		})
	}
}

// TestUploadSave_AcceptsNewerUpload covers the other direction of
// last-write-wins: an upload strictly newer than what is stored replaces it.
func TestUploadSave_AcceptsNewerUpload(t *testing.T) {
	router := newTestRouter(t)
	token := registerDeviceForTest(t, router, "device-a")

	first := `{"schema_version":1,"saved_at_unix":1000,"payload":{"tag":"first"}}`
	if rec := doRequest(t, router, http.MethodPut, "/v1/save", first, token); rec.Code != http.StatusOK {
		t.Fatalf("first upload status = %d, want %d", rec.Code, http.StatusOK)
	}

	second := `{"schema_version":1,"saved_at_unix":2000,"payload":{"tag":"second"}}`
	rec := doRequest(t, router, http.MethodPut, "/v1/save", second, token)
	if rec.Code != http.StatusOK {
		t.Fatalf("second upload status = %d, want %d (body %s)", rec.Code, http.StatusOK, rec.Body.String())
	}

	downloadRec := doRequest(t, router, http.MethodGet, "/v1/save", "", token)
	var downloadResp saveResponse
	decodeBody(t, downloadRec, &downloadResp)
	if downloadResp.SavedAtUnix != 2000 {
		t.Errorf("stored saved_at_unix = %d, want 2000", downloadResp.SavedAtUnix)
	}
	if string(downloadResp.Payload) != `{"tag":"second"}` {
		t.Errorf("stored payload = %s, want {\"tag\":\"second\"}", downloadResp.Payload)
	}
}

func TestSaveRoutes_RequireAuth(t *testing.T) {
	tests := []struct {
		name        string
		bearerToken string
	}{
		{name: "missing token", bearerToken: ""},
		{name: "wrong token", bearerToken: "not-a-real-token"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			router := newTestRouter(t)
			// Register a real device so we know a valid token exists and is
			// simply not the one being sent.
			registerDeviceForTest(t, router, "device-a")

			uploadRec := doRequest(t, router, http.MethodPut, "/v1/save",
				`{"schema_version":1,"saved_at_unix":1000,"payload":{}}`, tc.bearerToken)
			if uploadRec.Code != http.StatusUnauthorized {
				t.Errorf("upload status = %d, want %d", uploadRec.Code, http.StatusUnauthorized)
			}

			downloadRec := doRequest(t, router, http.MethodGet, "/v1/save", "", tc.bearerToken)
			if downloadRec.Code != http.StatusUnauthorized {
				t.Errorf("download status = %d, want %d", downloadRec.Code, http.StatusUnauthorized)
			}
		})
	}
}

// TestSaveSync_IsolatedPerDevice makes sure one device's uploads never leak
// into another device's download - the last-write-wins comparison and
// storage are keyed by the authenticated device id, not global.
func TestSaveSync_IsolatedPerDevice(t *testing.T) {
	router := newTestRouter(t)
	tokenA := registerDeviceForTest(t, router, "device-a")
	tokenB := registerDeviceForTest(t, router, "device-b")

	body := `{"schema_version":1,"saved_at_unix":1000,"payload":{"tag":"device-a-save"}}`
	if rec := doRequest(t, router, http.MethodPut, "/v1/save", body, tokenA); rec.Code != http.StatusOK {
		t.Fatalf("upload status = %d, want %d", rec.Code, http.StatusOK)
	}

	rec := doRequest(t, router, http.MethodGet, "/v1/save", "", tokenB)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("device-b download status = %d, want %d (device-a's save must not be visible)", rec.Code, http.StatusNotFound)
	}
}
