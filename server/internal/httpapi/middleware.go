package httpapi

import (
	"context"
	"net/http"
	"strings"
)

// ctxKey is an unexported type for context keys, following the standard-
// library convention of avoiding collisions with other packages' keys.
type ctxKey int

const deviceIDKey ctxKey = iota

// requireDeviceAuth resolves the request's bearer token to a device id via
// h.auth and stores it in the request context. This is the *only* place a
// token is read or parsed - every handler downstream reads the resolved
// device id with deviceIDFromContext and never touches the Authorization
// header itself, so replacing the auth stub with real identity later means
// changing this function and the AuthService it calls, not any handler
// (docs/0013).
func (h *handlers) requireDeviceAuth(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		token := bearerToken(r)
		if token == "" {
			writeError(w, http.StatusUnauthorized, "missing bearer token")
			return
		}
		deviceID, err := h.auth.Authenticate(r.Context(), token)
		if err != nil {
			writeError(w, http.StatusUnauthorized, "invalid or unknown token")
			return
		}
		ctx := context.WithValue(r.Context(), deviceIDKey, deviceID)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

func bearerToken(r *http.Request) string {
	header := r.Header.Get("Authorization")
	const prefix = "Bearer "
	if !strings.HasPrefix(header, prefix) {
		return ""
	}
	return strings.TrimPrefix(header, prefix)
}

func deviceIDFromContext(ctx context.Context) (string, bool) {
	deviceID, ok := ctx.Value(deviceIDKey).(string)
	return deviceID, ok
}
