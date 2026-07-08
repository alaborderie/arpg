// Package migrations embeds the plain-SQL migration files so the server binary
// can apply them at startup without shelling out to a separate tool. See
// db/README.md for the portability rules the SQL itself follows.
package migrations

import "embed"

// FS holds every "*.sql" migration file in this directory. internal/store
// reads it back, sorted by filename, to run whichever haven't been applied yet
// (tracked in a schema_migrations table) — see internal/store/migrate.go.
//
//go:embed *.sql
var FS embed.FS
