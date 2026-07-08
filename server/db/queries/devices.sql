-- name: GetDeviceByID :one
-- Looks up a device account by its self-generated id (used to make device
-- registration idempotent: re-registering an already-known device returns its
-- existing token instead of minting a new one).
SELECT id, token, created_at
FROM device_accounts
WHERE id = ?;

-- name: GetDeviceByToken :one
-- Resolves a bearer token to its device id. The only query the auth middleware
-- needs; handlers never run this themselves (see docs/0013).
SELECT id, token, created_at
FROM device_accounts
WHERE token = ?;

-- name: CreateDevice :exec
-- Registers a brand-new device with a freshly generated token.
INSERT INTO device_accounts (id, token) VALUES (?, ?);
