// Package tag owns simple, user-scoped named tags with colors
// (docs/domain-model.md §10).
package tag

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

type Tag struct {
	ID        string
	UserID    string
	Name      string
	Color     *string
	Revision  int64
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

func (t Tag) Snapshot() map[string]any {
	s := map[string]any{
		"id":        t.ID,
		"name":      t.Name,
		"color":     t.Color,
		"revision":  t.Revision,
		"createdAt": t.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt": t.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if t.DeletedAt != nil {
		s["deletedAt"] = t.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (t Tag) DTO() map[string]any { return t.Snapshot() }

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

// Create makes a tag; id may be empty (server-generated) or client-supplied
// (offline-created entities pushed via sync).
func (s *Service) Create(ctx context.Context, userID, id, name string, color *string) (Tag, error) {
	if err := validateName(name); err != nil {
		return Tag{}, err
	}
	if id == "" {
		id = uuid.NewString()
	}
	t := Tag{ID: id, UserID: userID, Name: name, Color: color}
	err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		now := time.Now().UTC()
		t.CreatedAt, t.UpdatedAt, t.Revision = now, now, 1
		if _, err := tx.Exec(ctx, `
			INSERT INTO tags (id, user_id, name, color, created_at, updated_at, revision)
			VALUES ($1,$2,$3,$4,$5,$5,1)`, t.ID, userID, name, color, now); err != nil {
			return err
		}
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityTag, t.ID, sync.OpCreate, 1, t.Snapshot())
		return err
	})
	return t, err
}

func (s *Service) List(ctx context.Context, userID string) ([]Tag, error) {
	rows, err := s.pool.Query(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM tags WHERE user_id = $1 AND deleted_at IS NULL ORDER BY name`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Tag
	for rows.Next() {
		var t Tag
		var id uuid.UUID
		if err := rows.Scan(&id, &t.Name, &t.Color, &t.Revision, &t.CreatedAt, &t.UpdatedAt, &t.DeletedAt); err != nil {
			return nil, err
		}
		t.ID, t.UserID = id.String(), userID
		out = append(out, t)
	}
	return out, rows.Err()
}

func (s *Service) Update(ctx context.Context, userID, id string, name *string, color *string) (Tag, error) {
	t, err := s.Get(ctx, userID, id)
	if err != nil {
		return t, err
	}
	if name != nil {
		if err := validateName(*name); err != nil {
			return t, err
		}
		t.Name = *name
	}
	if color != nil {
		t.Color = color
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		var newRev int64
		if err := tx.QueryRow(ctx, `UPDATE tags SET name=$3, color=$4, updated_at=now(), revision=revision+1
			WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL RETURNING revision, updated_at`,
			t.ID, userID, t.Name, t.Color).Scan(&newRev, &t.UpdatedAt); err != nil {
			return err
		}
		t.Revision = newRev
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityTag, t.ID, sync.OpUpdate, newRev, t.Snapshot())
		return err
	})
	return t, err
}

func (s *Service) Get(ctx context.Context, userID, id string) (Tag, error) {
	var t Tag
	var tid uuid.UUID
	if _, err := uuid.Parse(id); err != nil {
		return t, apperr.NotFound("tag")
	}
	err := s.pool.QueryRow(ctx, `SELECT id, name, color, revision, created_at, updated_at, deleted_at
		FROM tags WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL`, id, userID).
		Scan(&tid, &t.Name, &t.Color, &t.Revision, &t.CreatedAt, &t.UpdatedAt, &t.DeletedAt)
	if err == pgx.ErrNoRows {
		return t, apperr.NotFound("tag")
	}
	t.ID, t.UserID = tid.String(), userID
	return t, err
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	t, err := s.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		var newRev int64
		var deletedAt time.Time
		if err := tx.QueryRow(ctx, `UPDATE tags SET deleted_at=now(), revision=revision+1, updated_at=now()
			WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, t.ID).Scan(&newRev, &deletedAt); err != nil {
			return err
		}
		_, err := sync.AppendChange(ctx, tx, userID, sync.EntityTag, t.ID, sync.OpDelete, newRev, sync.TombstoneSnapshot(t.Snapshot(), newRev, deletedAt))
		return err
	})
}
