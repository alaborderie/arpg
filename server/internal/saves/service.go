// Package saves implements the M5 cloud-save sync protocol: last-write-wins
// upload/download of a single opaque save blob per device. The blob is the
// client's versioned save envelope (game/domain/save_data.gd, ADR 0012) - this
// package stores and returns it verbatim and never parses its contents, per
// the server-boundary rule in CLAUDE.md ("keep the blob opaque but design the
// handler/service split so validation can be inserted" - see docs/0013 for
// where that validation would slot in later).
package saves

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/alaborderie/arpg/server/internal/store/sqlcgen"
)

// DefaultSlot is the only save slot M5 uses. The schema already carries a
// slot column (ADR 0012 called out multiple slots as a straightforward
// future extension); the sync protocol just always addresses slot 0 for now,
// so multi-slot support later is additive here and in the HTTP layer, not a
// redesign.
const DefaultSlot int64 = 0

// ErrNotFound is returned by Download when the device has never uploaded a
// save to this slot.
var ErrNotFound = errors.New("saves: no save stored for this device")

// StaleUploadError is returned by Upload when savedAtUnix is not newer than
// the timestamp already stored - the upload is rejected, not merged, per the
// last-write-wins rule (ADR 0012 / docs/0013). StoredSavedAtUnix lets the
// caller report what is actually on the server so a client can decide to
// download instead.
type StaleUploadError struct {
	StoredSavedAtUnix int64
}

func (e *StaleUploadError) Error() string {
	return fmt.Sprintf("saves: upload is not newer than the stored save (stored saved_at_unix=%d)", e.StoredSavedAtUnix)
}

// queries is the subset of sqlcgen.Queries the saves service needs.
type queries interface {
	GetSave(ctx context.Context, arg sqlcgen.GetSaveParams) (sqlcgen.GetSaveRow, error)
	UpsertSave(ctx context.Context, arg sqlcgen.UpsertSaveParams) error
}

// Service implements upload/download with last-write-wins semantics.
type Service struct {
	q queries
}

// NewService builds a saves Service backed by q.
func NewService(q *sqlcgen.Queries) *Service {
	return &Service{q: q}
}

// Upload stores payload for deviceID if savedAtUnix is newer than whatever is
// already stored (or nothing is stored yet). payload is treated as opaque
// bytes - this function reads none of it. Returns the stored savedAtUnix on
// success (the value the caller just uploaded), or a *StaleUploadError
// wrapping the timestamp already on the server if the upload was rejected.
func (s *Service) Upload(ctx context.Context, deviceID string, schemaVersion int64, payload []byte, savedAtUnix int64) (int64, error) {
	existing, err := s.q.GetSave(ctx, sqlcgen.GetSaveParams{DeviceID: deviceID, Slot: DefaultSlot})
	switch {
	case errors.Is(err, sql.ErrNoRows):
		// Nothing stored yet - any upload is accepted.
	case err != nil:
		return 0, fmt.Errorf("saves: look up existing save: %w", err)
	default:
		if savedAtUnix <= existing.SavedAtUnix {
			return 0, &StaleUploadError{StoredSavedAtUnix: existing.SavedAtUnix}
		}
	}

	err = s.q.UpsertSave(ctx, sqlcgen.UpsertSaveParams{
		DeviceID:      deviceID,
		Slot:          DefaultSlot,
		SchemaVersion: schemaVersion,
		Payload:       string(payload),
		SavedAtUnix:   savedAtUnix,
	})
	if err != nil {
		return 0, fmt.Errorf("saves: upsert save: %w", err)
	}
	return savedAtUnix, nil
}

// Download returns the stored save for deviceID, or ErrNotFound if the device
// has never uploaded one.
func (s *Service) Download(ctx context.Context, deviceID string) (schemaVersion int64, payload []byte, savedAtUnix int64, err error) {
	row, err := s.q.GetSave(ctx, sqlcgen.GetSaveParams{DeviceID: deviceID, Slot: DefaultSlot})
	if errors.Is(err, sql.ErrNoRows) {
		return 0, nil, 0, ErrNotFound
	}
	if err != nil {
		return 0, nil, 0, fmt.Errorf("saves: get save: %w", err)
	}
	return row.SchemaVersion, []byte(row.Payload), row.SavedAtUnix, nil
}
