-- name: UpsertSave :exec
-- Last-write-wins upload of a save blob for a device/slot.
INSERT INTO saves (device_id, slot, schema_version, payload, updated_at)
VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)
ON CONFLICT (device_id, slot) DO UPDATE SET
    schema_version = excluded.schema_version,
    payload        = excluded.payload,
    updated_at     = CURRENT_TIMESTAMP;

-- name: GetSave :one
-- Fetch the current save blob for a device/slot.
SELECT device_id, slot, schema_version, payload, updated_at
FROM saves
WHERE device_id = ? AND slot = ?;
