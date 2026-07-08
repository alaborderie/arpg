package httpapi

import (
	"net/http"
	"testing"
)

func TestRegisterDevice(t *testing.T) {
	tests := []struct {
		name       string
		body       string
		wantStatus int
	}{
		{name: "happy path", body: `{"device_id":"device-a"}`, wantStatus: http.StatusOK},
		{name: "missing device_id", body: `{}`, wantStatus: http.StatusBadRequest},
		{name: "blank device_id", body: `{"device_id":"   "}`, wantStatus: http.StatusBadRequest},
		{name: "invalid JSON", body: `not json`, wantStatus: http.StatusBadRequest},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			router := newTestRouter(t)
			rec := doRequest(t, router, http.MethodPost, "/v1/auth/device", tc.body, "")

			if rec.Code != tc.wantStatus {
				t.Fatalf("status = %d, want %d (body %s)", rec.Code, tc.wantStatus, rec.Body.String())
			}
			if tc.wantStatus == http.StatusOK {
				var resp deviceAuthResponse
				decodeBody(t, rec, &resp)
				if resp.DeviceID != "device-a" {
					t.Errorf("device_id = %q, want %q", resp.DeviceID, "device-a")
				}
				if resp.Token == "" {
					t.Error("token is empty, want a non-empty bearer token")
				}
			}
		})
	}
}

// TestRegisterDeviceIsIdempotent covers the auth stub's core promise: a
// device re-registering (e.g. retrying after a dropped response) gets back
// the *same* token, not a freshly minted one that would invalidate the token
// already in use elsewhere.
func TestRegisterDeviceIsIdempotent(t *testing.T) {
	router := newTestRouter(t)

	first := registerDeviceForTest(t, router, "device-repeat")
	second := registerDeviceForTest(t, router, "device-repeat")

	if first != second {
		t.Fatalf("token changed on re-registration: first = %q, second = %q", first, second)
	}
}

// TestRegisterDeviceDifferentDevicesGetDifferentTokens is a sanity check that
// the stub is not handing out one shared token to everyone.
func TestRegisterDeviceDifferentDevicesGetDifferentTokens(t *testing.T) {
	router := newTestRouter(t)

	tokenA := registerDeviceForTest(t, router, "device-a")
	tokenB := registerDeviceForTest(t, router, "device-b")

	if tokenA == tokenB {
		t.Fatalf("device-a and device-b got the same token %q", tokenA)
	}
}
