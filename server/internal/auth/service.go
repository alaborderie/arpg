// Package auth implements the M5 device-auth stub: a client proves nothing
// beyond "I hold this self-generated device id" and gets back an opaque
// bearer token for subsequent requests. There is no password, no email, no
// real identity check - see docs/0013 for why that is an acceptable stub and
// how it is structured so real auth can replace RegisterDevice/Authenticate
// later without touching the HTTP layer or callers.
package auth

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"strings"

	"github.com/alaborderie/arpg/server/internal/store/sqlcgen"
)

// ErrInvalidDeviceID is returned when RegisterDevice is called with an empty
// device id.
var ErrInvalidDeviceID = errors.New("auth: device_id is required")

// ErrInvalidToken is returned when Authenticate is called with an empty or
// unrecognized bearer token.
var ErrInvalidToken = errors.New("auth: invalid or unknown token")

// tokenBytes is the amount of randomness in a generated token (before hex
// encoding, so the token itself is twice this many characters). 32 bytes of
// crypto/rand is comfortably unguessable for a stub with no other secret
// material behind it.
const tokenBytes = 32

// queries is the subset of sqlcgen.Queries the auth service needs. Declaring
// it here (rather than depending on the concrete *sqlcgen.Queries) keeps this
// package's dependency explicit and easy to fake in tests.
type queries interface {
	GetDeviceByID(ctx context.Context, id string) (sqlcgen.GetDeviceByIDRow, error)
	GetDeviceByToken(ctx context.Context, token string) (sqlcgen.GetDeviceByTokenRow, error)
	CreateDevice(ctx context.Context, arg sqlcgen.CreateDeviceParams) error
}

// Service resolves device ids to bearer tokens and back. It is the only place
// in the server that mints or checks a token - handlers call Authenticate via
// the httpapi middleware and never inspect a token themselves.
type Service struct {
	q        queries
	genToken func() (string, error)
}

// NewService builds an auth Service backed by q.
func NewService(q *sqlcgen.Queries) *Service {
	return &Service{q: q, genToken: generateToken}
}

// RegisterDevice returns the bearer token for deviceID, minting one on first
// contact. Idempotent by design: a device re-registering (e.g. after
// reinstalling but keeping its stored device id) gets its existing token back
// rather than a fresh one, so a retried registration never invalidates a
// token already in use elsewhere.
func (s *Service) RegisterDevice(ctx context.Context, deviceID string) (string, error) {
	deviceID = strings.TrimSpace(deviceID)
	if deviceID == "" {
		return "", ErrInvalidDeviceID
	}

	existing, err := s.q.GetDeviceByID(ctx, deviceID)
	switch {
	case err == nil:
		return existing.Token, nil
	case errors.Is(err, sql.ErrNoRows):
		// Fall through to registration below.
	default:
		return "", fmt.Errorf("auth: look up device: %w", err)
	}

	token, err := s.genToken()
	if err != nil {
		return "", fmt.Errorf("auth: generate token: %w", err)
	}
	if err := s.q.CreateDevice(ctx, sqlcgen.CreateDeviceParams{ID: deviceID, Token: token}); err != nil {
		return "", fmt.Errorf("auth: create device: %w", err)
	}
	return token, nil
}

// Authenticate resolves a bearer token to the device id that owns it, or
// ErrInvalidToken if the token is empty or unknown. This is the single seam a
// real auth implementation would replace: everything downstream only ever
// sees the resulting device id, never the token or how it was validated.
func (s *Service) Authenticate(ctx context.Context, token string) (string, error) {
	if token == "" {
		return "", ErrInvalidToken
	}
	device, err := s.q.GetDeviceByToken(ctx, token)
	if errors.Is(err, sql.ErrNoRows) {
		return "", ErrInvalidToken
	}
	if err != nil {
		return "", fmt.Errorf("auth: look up token: %w", err)
	}
	return device.ID, nil
}

func generateToken() (string, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}
