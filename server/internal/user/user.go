// Package user owns the user table: creation (registration) and lookup.
// The user's timezone is fixed at creation per docs/domain-model.md §1.
package user

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type User struct {
	ID           string    `json:"id"`
	Username     string    `json:"username"`
	Email        *string   `json:"email"`
	PasswordHash string    `json:"-"`
	Timezone     string    `json:"timezone"`
	CreatedAt    time.Time `json:"createdAt"`
	UpdatedAt    time.Time `json:"updatedAt"`
}

// DTO is the API shape (never exposes the password hash).
func (u User) DTO() map[string]any {
	return map[string]any{
		"id":        u.ID,
		"username":  u.Username,
		"email":     u.Email,
		"timezone":  u.Timezone,
		"createdAt": u.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt": u.UpdatedAt.UTC().Format(time.RFC3339),
	}
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// Create inserts a user inside the given tx (registration also writes an
// auth event and the initial sync state).
func (r *Repo) Create(ctx context.Context, db sync.DBTX, u *User) error {
	if _, err := db.Exec(ctx, `
		INSERT INTO users (id, username, email, password_hash, timezone, created_at, updated_at)
		VALUES ($1, $2, $3, $4, $5, now(), now())`,
		u.ID, u.Username, u.Email, u.PasswordHash, u.Timezone); err != nil {
		return err
	}
	if _, err := db.Exec(ctx, `INSERT INTO sync_states (user_id, current_seq) VALUES ($1, 0) ON CONFLICT DO NOTHING`, u.ID); err != nil {
		return err
	}
	return nil
}

func (r *Repo) ByUsername(ctx context.Context, username string) (User, error) {
	var u User
	var id uuid.UUID
	err := r.pool.QueryRow(ctx, `
		SELECT id, username, email, password_hash, timezone, created_at, updated_at
		FROM users WHERE username = $1`, username).
		Scan(&id, &u.Username, &u.Email, &u.PasswordHash, &u.Timezone, &u.CreatedAt, &u.UpdatedAt)
	if err == pgx.ErrNoRows {
		return u, apperr.NotFound("user")
	}
	u.ID = id.String()
	return u, err
}

func (r *Repo) ByID(ctx context.Context, id string) (User, error) {
	var u User
	var uid uuid.UUID
	if _, err := uuid.Parse(id); err != nil {
		return u, apperr.NotFound("user")
	}
	err := r.pool.QueryRow(ctx, `
		SELECT id, username, email, password_hash, timezone, created_at, updated_at
		FROM users WHERE id = $1`, id).
		Scan(&uid, &u.Username, &u.Email, &u.PasswordHash, &u.Timezone, &u.CreatedAt, &u.UpdatedAt)
	if err == pgx.ErrNoRows {
		return u, apperr.NotFound("user")
	}
	u.ID = uid.String()
	return u, err
}

// RecordAuthEvent logs security-relevant auth events (docs/security.md §7).
// Never includes credentials.
func (r *Repo) RecordAuthEvent(ctx context.Context, userID string, username, event, detail string) {
	_, _ = r.pool.Exec(ctx, `
		INSERT INTO auth_events (user_id, username, event, detail) VALUES ($1, $2, $3, $4)`,
		userID, username, event, detail)
}
