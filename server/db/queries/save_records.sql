-- name: UpsertSave :exec
-- Unconditional upsert of a save blob for a device/slot. Callers (the saves
-- service) are responsible for the last-write-wins comparison against
-- saved_at_unix *before* calling this - by the time this query runs, the
-- upload has already been decided as newer-or-first.
INSERT INTO save_records (device_id, slot, schema_version, payload, saved_at_unix, updated_at)
VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)
ON CONFLICT (device_id, slot) DO UPDATE SET
    schema_version = excluded.schema_version,
    payload        = excluded.payload,
    saved_at_unix  = excluded.saved_at_unix,
    updated_at     = CURRENT_TIMESTAMP;

-- name: GetSave :one
-- Fetch the current save blob for a device/slot. payload is opaque (an
-- application-versioned JSON blob, see docs/0012) - this layer never parses
-- it, only stores and returns it verbatim.
SELECT device_id, slot, schema_version, payload, saved_at_unix, updated_at
FROM save_records
WHERE device_id = ? AND slot = ?;
