// Package override stores per-occurrence edits for recurring series
// (docs/domain-model.md §12): THIS-scope moves, metadata patches and
// cancellations for course meetings and recurring schedules.
package override

import (
	"context"
	"encoding/json"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	SeriesCourseMeeting = "course_meeting"
	SeriesRecurring     = "recurring_schedule"
)

const (
	ActionMove   = "move"
	ActionUpdate = "update"
	ActionCancel = "cancel"
)

type Override struct {
	ID                  string
	UserID              string
	SeriesType          string
	SeriesID            string
	OccurrenceDateLocal string
	Action              string
	ReplacementStartAt  *time.Time
	ReplacementEndAt    *time.Time
	Metadata            map[string]any
	Revision            int64
	CreatedAt           time.Time
	UpdatedAt           time.Time
	DeletedAt           *time.Time
}

func (o Override) Snapshot() map[string]any {
	s := map[string]any{
		"id":                  o.ID,
		"seriesType":          o.SeriesType,
		"seriesId":            o.SeriesID,
		"occurrenceDateLocal": o.OccurrenceDateLocal,
		"action":              o.Action,
		"replacementStartAt":  nil,
		"replacementEndAt":    nil,
		"metadata":            o.Metadata,
		"revision":            o.Revision,
		"createdAt":           o.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":           o.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if o.ReplacementStartAt != nil {
		s["replacementStartAt"] = o.ReplacementStartAt.UTC().Format(time.RFC3339)
	}
	if o.ReplacementEndAt != nil {
		s["replacementEndAt"] = o.ReplacementEndAt.UTC().Format(time.RFC3339)
	}
	if o.DeletedAt != nil {
		s["deletedAt"] = o.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const overrideColumns = `id, user_id, series_type, series_id, occurrence_date_local, action, replacement_start_at, replacement_end_at, metadata, revision, created_at, updated_at, deleted_at`

func scanOverride(scanner interface {
	Scan(dest ...any) error
}) (Override, error) {
	var o Override
	var id uuid.UUID
	var seriesID uuid.UUID
	var metadata []byte
	if err := scanner.Scan(&id, &o.UserID, &o.SeriesType, &seriesID, &o.OccurrenceDateLocal, &o.Action,
		&o.ReplacementStartAt, &o.ReplacementEndAt, &metadata, &o.Revision, &o.CreatedAt, &o.UpdatedAt, &o.DeletedAt); err != nil {
		return o, err
	}
	o.ID = id.String()
	o.SeriesID = seriesID.String()
	if len(metadata) > 0 {
		_ = json.Unmarshal(metadata, &o.Metadata)
	}
	return o, nil
}

// Upsert creates or updates the override for (series, date) inside db,
// bumping revision and journaling. Returns the stored override.
func (r *Repo) Upsert(ctx context.Context, db sync.DBTX, o *Override) error {
	var metadata []byte
	var err error
	if o.Metadata != nil {
		metadata, err = json.Marshal(o.Metadata)
		if err != nil {
			return err
		}
	}
	var existing Override
	existing, findErr := scanOverride(db.QueryRow(ctx, `SELECT `+overrideColumns+` FROM occurrence_overrides
		WHERE series_id = $1 AND occurrence_date_local = $2 AND deleted_at IS NULL`, o.SeriesID, o.OccurrenceDateLocal))
	if findErr == pgx.ErrNoRows {
		o.ID = uuid.NewString()
		now := time.Now().UTC()
		o.CreatedAt, o.UpdatedAt, o.Revision = now, now, 1
		if _, err := db.Exec(ctx, `
			INSERT INTO occurrence_overrides (id, user_id, series_type, series_id, occurrence_date_local, action, replacement_start_at, replacement_end_at, metadata, created_at, updated_at, revision)
			VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$10,1)`,
			o.ID, o.UserID, o.SeriesType, o.SeriesID, o.OccurrenceDateLocal, o.Action, o.ReplacementStartAt, o.ReplacementEndAt, metadata, now); err != nil {
			return err
		}
		_, err := sync.AppendChange(ctx, db, o.UserID, sync.EntityOverride, o.ID, sync.OpCreate, 1, o.Snapshot())
		return err
	}
	if findErr != nil {
		return findErr
	}
	// Update the existing row (keep its ID), bumping revision.
	o.ID = existing.ID
	var newRev int64
	err = db.QueryRow(ctx, `
		UPDATE occurrence_overrides
		SET action = $3, replacement_start_at = $4, replacement_end_at = $5, metadata = $6, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL
		RETURNING revision, updated_at`,
		o.ID, o.UserID, o.Action, o.ReplacementStartAt, o.ReplacementEndAt, metadata).Scan(&newRev, &o.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.NotFound("override")
	}
	if err != nil {
		return err
	}
	o.Revision = newRev
	_, err = sync.AppendChange(ctx, db, o.UserID, sync.EntityOverride, o.ID, sync.OpUpdate, newRev, o.Snapshot())
	return err
}

// BySeries lists live overrides of one series.
func (r *Repo) BySeries(ctx context.Context, userID, seriesType, seriesID string) ([]Override, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+overrideColumns+` FROM occurrence_overrides
		WHERE user_id = $1 AND series_type = $2 AND series_id = $3 AND deleted_at IS NULL`, userID, seriesType, seriesID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Override
	for rows.Next() {
		o, err := scanOverride(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, o)
	}
	return out, rows.Err()
}

// OfSeriesSet returns live overrides for many series ids at once
// (event projection batch loading).
func (r *Repo) OfSeriesSet(ctx context.Context, userID string, seriesType string, seriesIDs []string) (map[string][]Override, error) {
	out := make(map[string][]Override)
	if len(seriesIDs) == 0 {
		return out, nil
	}
	ids := make([]uuid.UUID, 0, len(seriesIDs))
	for _, s := range seriesIDs {
		if u, err := uuid.Parse(s); err == nil {
			ids = append(ids, u)
		}
	}
	rows, err := r.pool.Query(ctx, `SELECT `+overrideColumns+` FROM occurrence_overrides
		WHERE user_id = $1 AND series_type = $2 AND series_id = ANY($3) AND deleted_at IS NULL`,
		userID, seriesType, ids)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		o, err := scanOverride(rows)
		if err != nil {
			return nil, err
		}
		out[o.SeriesID] = append(out[o.SeriesID], o)
	}
	return out, rows.Err()
}

// Get loads one override by id.
func (r *Repo) Get(ctx context.Context, userID, overrideID string) (Override, error) {
	if _, err := uuid.Parse(overrideID); err != nil {
		return Override{}, apperr.NotFound("override")
	}
	o, err := scanOverride(r.pool.QueryRow(ctx, `SELECT `+overrideColumns+` FROM occurrence_overrides
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, overrideID, userID))
	if err == pgx.ErrNoRows {
		return o, apperr.NotFound("override")
	}
	return o, err
}
