package tag

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TagAdapter plugs tags into the sync push engine.
type TagAdapter struct {
	svc  *Service
	pool *pgxpool.Pool
}

func NewTagAdapter(pool *pgxpool.Pool, svc *Service) *TagAdapter {
	return &TagAdapter{svc: svc, pool: pool}
}

func loadTagAny(pool *pgxpool.Pool, ctx context.Context, userID, id string) (Tag, sync.EntityState, error) {
	var t Tag
	var tid uuid.UUID
	if _, err := uuid.Parse(id); err != nil {
		return t, sync.StateMissing, apperr.NotFound("tag")
	}
	err := pool.QueryRow(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM tags WHERE id=$1 AND user_id=$2`, id, userID).
		Scan(&tid, &t.Name, &t.Color, &t.Revision, &t.CreatedAt, &t.UpdatedAt, &t.DeletedAt)
	if err != nil {
		return t, sync.StateMissing, nil
	}
	t.ID, t.UserID = tid.String(), userID
	if t.DeletedAt != nil {
		return t, sync.StateDeleted, nil
	}
	return t, sync.StateLive, nil
}

func (a *TagAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	t, state, err := loadTagAny(a.pool, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return t.Snapshot(), t.Revision, state, nil
}

func (a *TagAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	name, ok := fields["name"].(string)
	if !ok || name == "" {
		return apperr.Validation("name", "is required")
	}
	color := strPtrOf(fields["color"])
	if err := validateName(name); err != nil {
		return err
	}
	t := Tag{ID: entityID, UserID: userID, Name: name, Color: color}
	now := time.Now().UTC()
	t.CreatedAt, t.UpdatedAt, t.Revision = now, now, 1
	if _, err := tx.Exec(ctx, `
		INSERT INTO tags (id, user_id, name, color, created_at, updated_at, revision)
		VALUES ($1,$2,$3,$4,$5,$5,1)`, t.ID, userID, name, color, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, tx, userID, sync.EntityTag, t.ID, sync.OpCreate, 1, t.Snapshot())
	return err
}

func (a *TagAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	t, state, err := loadTagAny(a.pool, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	var name *string
	var color *string
	if v, ok := fields["name"].(string); ok {
		name = &v
	}
	if v, ok := fields["color"].(string); ok {
		color = &v
	}
	if name != nil {
		t.Name = *name
	}
	if color != nil {
		t.Color = color
	}
	if err := validateName(t.Name); err != nil {
		return 0, err
	}
	var newRev int64
	if err := tx.QueryRow(ctx, `UPDATE tags SET name=$3, color=$4, updated_at=now(), revision=revision+1
		WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL AND revision=$5 RETURNING revision, updated_at`,
		entityID, userID, t.Name, t.Color, baseRevision).Scan(&newRev, &t.UpdatedAt); err != nil {
		return 0, apperr.StaleRevision(sync.EntityTag, t.Revision, baseRevision)
	}
	t.Revision = newRev
	if _, err := sync.AppendChange(ctx, tx, userID, sync.EntityTag, entityID, sync.OpUpdate, newRev, t.Snapshot()); err != nil {
		return 0, err
	}
	return newRev, nil
}

func (a *TagAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	t, state, err := loadTagAny(a.pool, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	var newRev int64
	var deletedAt = t.UpdatedAt
	if err := tx.QueryRow(ctx, `UPDATE tags SET deleted_at=now(), revision=revision+1, updated_at=now()
		WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, entityID).Scan(&newRev, &deletedAt); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, tx, userID, sync.EntityTag, entityID, sync.OpDelete, newRev, sync.TombstoneSnapshot(t.Snapshot(), newRev, deletedAt))
	return err
}

func strPtrOf(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}
