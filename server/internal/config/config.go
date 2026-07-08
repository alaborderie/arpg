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
}

// Load reads configuration from the environment, applying defaults.
func Load() Config {
	return Config{
		Addr:   getenv("ARPG_ADDR", ":8080"),
		DBPath: getenv("ARPG_DB_PATH", "arpg.db"),
	}
}

func getenv(key, fallback string) string {
	if v, ok := os.LookupEnv(key); ok && v != "" {
		return v
	}
	return fallback
}
