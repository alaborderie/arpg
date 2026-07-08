package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
)

// deviceAuthRequest is the body of POST /v1/auth/device.
type deviceAuthRequest struct {
	DeviceID string `json:"device_id"`
}

// deviceAuthResponse is the body returned on successful registration. Token
// is an opaque bearer credential the client stores and sends as
// "Authorization: Bearer <token>" on every subsequent request.
type deviceAuthResponse struct {
	DeviceID string `json:"device_id"`
	Token    string `json:"token"`
}

// registerDevice handles POST /v1/auth/device: the client's self-generated
// device id in, a bearer token out. There is no password and no proof of
// identity beyond "you know this device id" - see docs/0013 for why that is
// an acceptable stub for now and how AuthService is the seam a real identity
// check would replace.
func (h *handlers) registerDevice(w http.ResponseWriter, r *http.Request) {
	var req deviceAuthRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON body")
		return
	}
	deviceID := strings.TrimSpace(req.DeviceID)
	if deviceID == "" {
		writeError(w, http.StatusBadRequest, "device_id is required")
		return
	}

	token, err := h.auth.RegisterDevice(r.Context(), deviceID)
	if err != nil {
		h.logger.Error("register device failed", "err", err)
		writeError(w, http.StatusInternalServerError, "internal error")
		return
	}

	writeJSON(w, http.StatusOK, deviceAuthResponse{DeviceID: deviceID, Token: token})
}
