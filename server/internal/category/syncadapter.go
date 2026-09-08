package category

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CategoryAdapter plugs todo categories into the sync push engine.
type CategoryAdapter struct {
	pool *pgxpool.Pool
}

func NewCategoryAdapter(pool *pgxpool.Pool) *CategoryAdapter {
	return &CategoryAdapter{pool: pool}
}

func loadCategoryAny(pool *pgxpool.Pool, ctx context.Context, userID, id string) (Category, sync.EntityState, error) {
	var c Category
	var cid uuid.UUID
	if _, err := uuid.Parse(id); err != nil {
		return c, sync.StateMissing, apperr.NotFound("category")
	}
	err := pool.QueryRow(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM todo_categories WHERE id=$1 AND user_id=$2`, id, userID).
		Scan(&cid, &c.Name, &c.Color, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt)
	if err != nil {
		return c, sync.StateMissing, nil
	}
	c.ID, c.UserID = cid.String(), userID
	if c.DeletedAt != nil {
		return c, sync.StateDeleted, nil
	}
	return c, sync.StateLive, nil
}

func (a *CategoryAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	c, state, err := loadCategoryAny(a.pool, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return c.Snapshot(), c.Revision, state, nil
}

func (a *CategoryAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	name, ok := fields["name"].(string)
	if !ok || name == "" {
		return apperr.Validation("name", "is required")
	}
	if err := validateName(name); err != nil {
		return err
	}
	color := strPtrOf(fields["color"])
	c := Category{ID: entityID, UserID: userID, Name: name, Color: color}
	now := time.Now().UTC()
	c.CreatedAt, c.UpdatedAt, c.Revision = now, now, 1
	if _, err := tx.Exec(ctx, `
		INSERT INTO todo_categories (id, user_id, name, color, created_at, updated_at, revision)
		VALUES ($1,$2,$3,$4,$5,$5,1)`, c.ID, userID, name, color, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, tx, userID, sync.EntityCategory, c.ID, sync.OpCreate, 1, c.Snapshot())
	return err
}

func (a *CategoryAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	c, state, err := loadCategoryAny(a.pool, ctx, userID, entityID)
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
		c.Name = *name
	}
	if color != nil {
		c.Color = color
	}
	if err := validateName(c.Name); err != nil {
		return 0, err
	}
	var newRev int64
	if err := tx.QueryRow(ctx, `UPDATE todo_categories SET name=$3, color=$4, updated_at=now(), revision=revision+1
		WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL AND revision=$5 RETURNING revision, updated_at`,
		entityID, userID, c.Name, c.Color, baseRevision).Scan(&newRev, &c.UpdatedAt); err != nil {
		return 0, apperr.StaleRevision(sync.EntityCategory, c.Revision, baseRevision)
	}
	c.Revision = newRev
	if _, err := sync.AppendChange(ctx, tx, userID, sync.EntityCategory, entityID, sync.OpUpdate, newRev, c.Snapshot()); err != nil {
		return 0, err
	}
	return newRev, nil
}

func (a *CategoryAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	c, state, err := loadCategoryAny(a.pool, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	var newRev int64
	var deletedAt time.Time
	if err := tx.QueryRow(ctx, `UPDATE todo_categories SET deleted_at=now(), revision=revision+1, updated_at=now()
		WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, entityID).Scan(&newRev, &deletedAt); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, tx, userID, sync.EntityCategory, entityID, sync.OpDelete, newRev, sync.TombstoneSnapshot(c.Snapshot(), newRev, deletedAt))
	return err
}

func strPtrOf(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}
