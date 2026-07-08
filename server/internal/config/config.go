// Package config loads runtime configuration from the environment.
//
// Values come from env vars (12-factor) so the same binary runs identically in
// dev, CI and production. Because the client never depends on the server, every
// field has a safe local default.
package config

import "os"

// Config holds all runtime configuration for the server.
type Config struct {
	// Addr is the listen address, e.g. ":8080".
	Addr string
	// DBPath is the SQLite database file (or ":memory:"). Relative paths
	// resolve against the process's working directory (server/ when run via
	// `make run-server`).
	DBPath string
	// SharedDataDir is shared/*.json's location - the single source of
	// balance truth (ADR 0005) the M6 farming resolver loads. Relative
	// paths resolve against the process's working directory; the default
	// assumes `server/` (the `make run-server`/`go run ./cmd/server`
	// working directory), one level up from the repo root's shared/.
	SharedDataDir string
}

// Load reads configuration from the environment, applying defaults.
func Load() Config {
	return Config{
		Addr:          getenv("ARPG_ADDR", ":8080"),
		DBPath:        getenv("ARPG_DB_PATH", "arpg.db"),
		SharedDataDir: getenv("ARPG_SHARED_DATA_DIR", "../shared"),
	}
}

func getenv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
