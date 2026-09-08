// Package category owns todo categories (docs/domain-model.md §11).
package category

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Category struct {
	ID        string
	UserID    string
	Name      string
	Color     *string
	Revision  int64
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

func (c Category) Snapshot() map[string]any {
	s := map[string]any{
		"id":        c.ID,
		"name":      c.Name,
		"color":     c.Color,
		"revision":  c.Revision,
		"createdAt": c.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt": c.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if c.DeletedAt != nil {
		s["deletedAt"] = c.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (c Category) DTO() map[string]any { return c.Snapshot() }

type Service struct {
	pool *pgxpool.Pool
}

func NewService(pool *pgxpool.Pool) *Service { return &Service{pool: pool} }

func validateName(name string) error {
	if name == "" || len(name) > 50 {
		return apperr.Validation("name", "must be 1-50 characters")
	}
	return nil
}

// Create makes a category; id may be empty (server-generated) or
// client-supplied (offline-created entities pushed via sync).
func (s *Service) Create(ctx context.Context, userID, id, name string, color *string) (Category, error) {
	if err := validateName(name); err != nil {
		return Category{}, err
	}
	if id == "" {
		id = uuid.NewString()
	}
	c := Category{ID: id, UserID: userID, Name: name, Color: color}
	err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		now := time.Now().UTC()
		c.CreatedAt, c.UpdatedAt, c.Revision = now, now, 1
		if _, err := tx.Exec(ctx, `
			INSERT INTO todo_categories (id, user_id, name, color, created_at, updated_at, revision)
			VALUES ($1,$2,$3,$4,$5,$5,1)`, c.ID, userID, name, color, now); err != nil {
			return err
		}
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityCategory, c.ID, sync.OpCreate, 1, c.Snapshot())
		return err
	})
	return c, err
}

func (s *Service) List(ctx context.Context, userID string) ([]Category, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM todo_categories WHERE user_id = $1 AND deleted_at IS NULL ORDER BY name`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Category
	for rows.Next() {
		var c Category
		var id uuid.UUID
		if err := rows.Scan(&id, &c.Name, &c.Color, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt); err != nil {
			return nil, err
		}
		c.ID, c.UserID = id.String(), userID
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Service) Update(ctx context.Context, userID, id string, name *string, color *string) (Category, error) {
	c, err := s.Get(ctx, userID, id)
	if err != nil {
		return c, err
	}
	if name != nil {
		if err := validateName(*name); err != nil {
			return c, err
		}
		c.Name = *name
	}
	if color != nil {
		c.Color = color
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		var newRev int64
		if err := tx.QueryRow(ctx, `UPDATE todo_categories SET name=$3, color=$4, updated_at=now(), revision=revision+1
			WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL RETURNING revision, updated_at`,
			c.ID, userID, c.Name, c.Color).Scan(&newRev, &c.UpdatedAt); err != nil {
			return err
		}
		c.Revision = newRev
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityCategory, c.ID, sync.OpUpdate, newRev, c.Snapshot())
		return err
	})
	return c, err
}

func (s *Service) Get(ctx context.Context, userID, id string) (Category, error) {
	var c Category
	var cid uuid.UUID
	if _, err := uuid.Parse(id); err != nil {
		return c, apperr.NotFound("category")
	}
	err := s.pool.QueryRow(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM todo_categories WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL`, id, userID).
		Scan(&cid, &c.Name, &c.Color, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt)
	if err == pgx.ErrNoRows {
		return c, apperr.NotFound("category")
	}
	c.ID, c.UserID = cid.String(), userID
	return c, err
}

// Delete soft-deletes the category; todos keep their categoryId but the
// reference disappears from lists (clients treat missing categories as null).
func (s *Service) Delete(ctx context.Context, userID, id string) error {
	c, err := s.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		var newRev int64
		var deletedAt time.Time
		if err := tx.QueryRow(ctx, `UPDATE todo_categories SET deleted_at=now(), revision=revision+1, updated_at=now()
			WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, c.ID).Scan(&newRev, &deletedAt); err != nil {
			return err
		}
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityCategory, c.ID, sync.OpDelete, newRev, sync.TombstoneSnapshot(c.Snapshot(), newRev, deletedAt))
		return err
	})
}
