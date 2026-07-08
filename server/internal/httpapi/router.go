// Package httpapi wires the server's HTTP surface.
//
// Routes are grouped and handlers hang off a small struct so the auth and
// save-sync services added in M5 (and the AI-agent endpoints in M6) slot in
// without reshaping existing code.
package httpapi

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"github.com/alaborderie/arpg/server/internal/farming"
)

// AuthService resolves bearer tokens to device identities and registers new
// devices. Implemented by internal/auth.Service; handlers and middleware
// depend on this interface so the M5 device-id stub can be replaced by real
// auth later without reshaping the HTTP layer (docs/0013).
type AuthService interface {
	RegisterDevice(ctx context.Context, deviceID string) (token string, err error)
	Authenticate(ctx context.Context, token string) (deviceID string, err error)
}

// SaveService is the save-sync business logic (last-write-wins upload and
// download of one opaque blob per device). Implemented by
// internal/saves.Service.
type SaveService interface {
	Upload(ctx context.Context, deviceID string, schemaVersion int64, payload []byte, savedAtUnix int64) (storedSavedAtUnix int64, err error)
	Download(ctx context.Context, deviceID string) (schemaVersion int64, payload []byte, savedAtUnix int64, err error)
}

// FarmService drives one AI-farming map run (M6) for an authenticated
// device: a deterministic, LLM-free simulation over shared/ balance data
// (see internal/farming and docs/0014). Unlike AuthService/SaveService this
// interface's methods take/return internal/farming's own exported types
// rather than primitives - the run summary and tool-call transcript are
// nested and JSON-shaped by design, so farming's DTOs *are* the wire
// contract, not an internal detail to hide.
type FarmService interface {
	Run(ctx context.Context, deviceID string, req farming.RunRequest) (farming.RunOutput, error)
}

// NewRouter builds the HTTP handler for the whole server.
func NewRouter(logger *slog.Logger, auth AuthService, saves SaveService, farm FarmService) http.Handler {
	r := chi.NewRouter()

	r.Use(middleware.RequestID)
	r.Use(middleware.Recoverer)
	r.Use(requestLogger(logger))

	h := &handlers{logger: logger, auth: auth, saves: saves, farm: farm}

	r.Get("/health", h.health)

	r.Route("/v1", func(r chi.Router) {
		r.Post("/auth/device", h.registerDevice)

		r.Group(func(r chi.Router) {
			r.Use(h.requireDeviceAuth)
			r.Put("/save", h.uploadSave)
			r.Get("/save", h.downloadSave)
			r.Post("/farm/run", h.runFarm)
		})
	})

	return r
}

// handlers carries the dependencies shared by every route handler. auth,
// saves and farm are interfaces (not the concrete service types) so
// handlers never depend on how tokens are minted, how saves are persisted,
// or how a farm run is simulated - only on the operations each needs.
type handlers struct {
	logger *slog.Logger
	auth   AuthService
	saves  SaveService
	farm   FarmService
}

// requestLogger emits one structured slog line per request.
func requestLogger(logger *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			start := time.Now()
			ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)

			next.ServeHTTP(ww, r)

			logger.Info("request",
				"method", r.Method,
				"path", r.URL.Path,
				"status", ww.Status(),
				"bytes", ww.BytesWritten(),
				"duration_ms", time.Since(start).Milliseconds(),
				"request_id", middleware.GetReqID(r.Context()),
			)
		})
	}
}
