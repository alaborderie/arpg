-- Migration 0002: device auth stub + save-sync last-write-wins column.
--
-- Adds a bearer token per device (the auth stub, M5 - see docs/0013) and the
-- client-supplied save timestamp the sync protocol compares for last-write-wins.
-- Kept portable (see db/README.md): plain ADD COLUMN + a separate unique index
-- instead of an inline UNIQUE (SQLite can't add a UNIQUE column in one ALTER
-- statement), both supported by Postgres too.
--
-- Also renames "saves" to "save_records": sqlc's singularizer treats a plain
-- "saves" table as the irregular -ves/-fe family (leaf/leaves, wolf/wolves)
-- and generates a Go model type named "Safe", not "Save". Renaming sidesteps
-- the mis-singularization instead of fighting the inflector.

ALTER TABLE device_accounts ADD COLUMN token TEXT NOT NULL DEFAULT '';
CREATE UNIQUE INDEX IF NOT EXISTS idx_device_accounts_token ON device_accounts (token);

ALTER TABLE saves RENAME TO save_records;
ALTER TABLE save_records ADD COLUMN saved_at_unix INTEGER NOT NULL DEFAULT 0;
