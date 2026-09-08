// Package sync implements the server side of the sync protocol
// (docs/sync-protocol.md): the per-user monotonic cursor, the append-only
// change journal (which doubles as revision history and tombstone store),
// idempotent operation handling, and field-aware three-way merge.
//
// journal.go is the write path shared by every repository: any persisted
// mutation must, inside the same transaction, call AppendChange so that
// entity revision bumps and sync_seq allocation stay atomic.
package sync

import (
	"context"
	"encoding/json"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Entity types exchanged over the sync protocol.
const (
	EntityCalendar  = "academic_calendar"
	EntityPeriod    = "period_template"
	EntityCourse    = "course"
	EntityMeeting   = "course_meeting"
	EntityRecurring = "recurring_schedule"
	EntityTodo      = "todo"
	EntityTodoBlock = "todo_block"
	EntityTag       = "tag"
	EntityCategory  = "todo_category"
	EntityOverride  = "occurrence_override"
)

// Operation names on the wire.
const (
	OpCreate = "create"
	OpUpdate = "update"
	OpDelete = "delete"
)

// DBTX is satisfied by both *pgxpool.Pool and pgx.Tx.
type DBTX interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
	Query(ctx context.Context, sql string, args ...any) (pgx.Rows, error)
	QueryRow(ctx context.Context, sql string, args ...any) pgx.Row
}

// AppendChange allocates the next sync_seq for userID and appends one journal
// entry. Must run inside the same transaction as the data mutation.
// payload is the full API-shaped snapshot of the entity at this revision
// (tombstones additionally carry deletedAt).
func AppendChange(ctx context.Context, db DBTX, userID, entityType, entityID string, operation string, revision int64, payload map[string]any) (int64, error) {
	var seq int64
	err := db.QueryRow(ctx, `
		INSERT INTO sync_states (user_id, current_seq) VALUES ($1, 1)
		ON CONFLICT (user_id) DO UPDATE SET current_seq = sync_states.current_seq + 1, updated_at = now()
		RETURNING current_seq`, userID).Scan(&seq)
	if err != nil {
		return 0, err
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return 0, err
	}
	if _, err := db.Exec(ctx, `
		INSERT INTO sync_changes (user_id, sync_seq, entity_type, entity_id, operation, revision, payload)
		VALUES ($1, $2, $3, $4, $5, $6, $7)`,
		userID, seq, entityType, entityID, operation, revision, raw); err != nil {
		return 0, err
	}
	return seq, nil
}

// TombstoneSnapshot builds the delete payload: last known fields plus the
// deletion marker.
func TombstoneSnapshot(base map[string]any, revision int64, deletedAt time.Time) map[string]any {
	snap := map[string]any{}
	for k, v := range base {
		snap[k] = v
	}
	snap["revision"] = revision
	snap["deletedAt"] = deletedAt.UTC().Format(time.RFC3339)
	return snap
}

// Change is one journal row on the wire.
type Change struct {
	SyncSeq    int64          `json:"syncSeq"`
	EntityType string         `json:"entityType"`
	EntityID   string         `json:"entityId"`
	Operation  string         `json:"operation"`
	Revision   int64          `json:"revision"`
	Payload    map[string]any `json:"payload"`
	CreatedAt  string         `json:"createdAt"`
}

// State is the per-user cursor value.
type State struct {
	ServerCursor int64 `json:"serverCursor"`
}

// Journal provides read access to the sync log.
type Journal struct {
	pool *pgxpool.Pool
}

func NewJournal(pool *pgxpool.Pool) *Journal { return &Journal{pool: pool} }

// CurrentCursor returns the user's latest sync_seq (0 when never written).
func (j *Journal) CurrentCursor(ctx context.Context, userID string) (int64, error) {
	var seq int64
	err := j.pool.QueryRow(ctx, `SELECT current_seq FROM sync_states WHERE user_id = $1`, userID).Scan(&seq)
	if err == pgx.ErrNoRows {
		return 0, nil
	}
	return seq, err
}

// ChangesSince returns up to limit journal entries with sync_seq > after.
func (j *Journal) ChangesSince(ctx context.Context, userID string, after int64, limit int) ([]Change, int64, bool, error) {
	rows, err := j.pool.Query(ctx, `
		SELECT sync_seq, entity_type, entity_id, operation, revision, payload, created_at
		FROM sync_changes
		WHERE user_id = $1 AND sync_seq > $2
		ORDER BY sync_seq ASC
		LIMIT $3`, userID, after, limit+1)
	if err != nil {
		return nil, 0, false, err
	}
	defer rows.Close()

	var out []Change
	for rows.Next() {
		var c Change
		var payload []byte
		var createdAt time.Time
		var entityID uuid.UUID
		if err := rows.Scan(&c.SyncSeq, &c.EntityType, &entityID, &c.Operation, &c.Revision, &payload, &createdAt); err != nil {
			return nil, 0, false, err
		}
		c.EntityID = entityID.String()
		c.CreatedAt = createdAt.UTC().Format(time.RFC3339)
		if err := json.Unmarshal(payload, &c.Payload); err != nil {
			return nil, 0, false, err
		}
		out = append(out, c)
	}
	if err := rows.Err(); err != nil {
		return nil, 0, false, err
	}
	hasMore := false
	next := after
	if len(out) > limit {
		hasMore = true
		out = out[:limit]
	}
	if len(out) > 0 {
		next = out[len(out)-1].SyncSeq
	}
	return out, next, hasMore, nil
}

// SnapshotAtRevision returns the newest stored snapshot of an entity with
// revision <= maxRevision — the "base" leg of the three-way merge. Returns
// nil when the entity has no history at or below that revision.
func (j *Journal) SnapshotAtRevision(ctx context.Context, userID, entityType, entityID string, maxRevision int64) (map[string]any, error) {
	var payload []byte
	err := j.pool.QueryRow(ctx, `
		SELECT payload FROM sync_changes
		WHERE user_id = $1 AND entity_type = $2 AND entity_id = $3 AND revision <= $4
		ORDER BY revision DESC LIMIT 1`,
		userID, entityType, entityID, maxRevision).Scan(&payload)
	if err == pgx.ErrNoRows {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]any
	if err := json.Unmarshal(payload, &m); err != nil {
		return nil, err
	}
	return m, nil
}
