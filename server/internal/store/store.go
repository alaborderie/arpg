// Package store owns the SQLite connection and applies migrations at startup.
// It wraps the sqlc-generated Queries (internal/store/sqlcgen) behind a single
// Store type; service packages (internal/auth, internal/saves) depend on
// *sqlcgen.Queries, not on database/sql directly, so swapping storage details
// later stays contained here.
package store

import (
	"context"
	"database/sql"
	"fmt"

	// Pure-Go SQLite driver: no cgo, so CI needs no C toolchain (ADR 0006).
	_ "modernc.org/sqlite"

	"github.com/alaborderie/arpg/server/internal/store/sqlcgen"
)

// Store is the server's database handle: a connection plus the generated
// query methods, already migrated to the latest schema.
type Store struct {
	db      *sql.DB
	Queries *sqlcgen.Queries
}

// Open connects to the SQLite database at dsn (a file path, or ":memory:" for
// tests) and applies any migrations that have not run yet. dsn is passed
// straight to the "sqlite" driver.
func Open(ctx context.Context, dsn string) (*Store, error) {
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("store: open %s: %w", dsn, err)
	}
	// modernc.org/sqlite is not safe for concurrent writers across multiple
	// connections; a single pooled connection keeps every statement
	// serialized through the same handle, which is what a file-based SQLite
	// database needs regardless of driver.
	db.SetMaxOpenConns(1)

	if err := db.PingContext(ctx); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("store: ping %s: %w", dsn, err)
	}
	if err := migrate(ctx, db); err != nil {
		_ = db.Close()
		return nil, fmt.Errorf("store: migrate %s: %w", dsn, err)
	}
	return &Store{db: db, Queries: sqlcgen.New(db)}, nil
}

// Close releases the underlying database connection.
func (s *Store) Close() error {
	return s.db.Close()
}
