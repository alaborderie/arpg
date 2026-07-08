// Command server is the ARPG backend.
//
// It is OPTIONAL from the client's perspective: the game is fully playable with
// no connection. For now the server exposes only a health check; device auth and
// cloud-save sync arrive in M5, and the AI-farming agent runner in M6. Everything
// with economic value is validated server-side and never trusted from the client.
package main

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/alaborderie/arpg/server/internal/auth"
	"github.com/alaborderie/arpg/server/internal/config"
	"github.com/alaborderie/arpg/server/internal/httpapi"
	"github.com/alaborderie/arpg/server/internal/saves"
	"github.com/alaborderie/arpg/server/internal/store"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	slog.SetDefault(logger)

	cfg := config.Load()

	st, err := store.Open(context.Background(), cfg.DBPath)
	if err != nil {
		logger.Error("open store failed", "err", err)
		os.Exit(1)
	}
	defer func() {
		if err := st.Close(); err != nil {
			logger.Error("close store failed", "err", err)
		}
	}()

	authSvc := auth.NewService(st.Queries)
	saveSvc := saves.NewService(st.Queries)

	srv := &http.Server{
		Addr:              cfg.Addr,
		Handler:           httpapi.NewRouter(logger, authSvc, saveSvc),
		ReadHeaderTimeout: 5 * time.Second,
	}

	go func() {
		logger.Info("server starting", "addr", cfg.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logger.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	// Block until we get an interrupt, then drain in-flight requests.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()

	logger.Info("server shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		logger.Error("graceful shutdown failed", "err", err)
		os.Exit(1)
	}
	logger.Info("server stopped")
}
