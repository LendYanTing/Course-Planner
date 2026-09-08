// Package todo owns todos and their scheduled blocks
// (docs/domain-model.md §7-9). A Todo is the work item; a TodoBlock is a
// concrete time slot in which part of that work is done; deadline_at is a
// point-in-time marker shown on week/month views.
package todo

import (
	"context"
	"encoding/json"
	"strconv"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Todo types and statuses (docs/domain-model.md §7).
const (
	TypeOneOff  = "one_off"
	TypeProject = "project"
)

const (
	StatusTodo       = "todo"
	StatusInProgress = "in_progress"
	StatusCompleted  = "completed"
	StatusCancelled  = "cancelled"
)

// Block statuses.
const (
	BlockStatusScheduled  = "scheduled"
	BlockStatusInProgress = "in_progress"
	BlockStatusCompleted  = "completed"
	BlockStatusSkipped    = "skipped"
)

// Priorities.
const (
	PriorityLow    = "low"
	PriorityNormal = "normal"
	PriorityHigh   = "high"
	PriorityUrgent = "urgent"
)

type Todo struct {
	ID               string
	UserID           string
	Title            string
	Type             string
	Description      *string
	CategoryID       *string
	TagIDs           []string
	Priority         string
	Status           string
	EstimatedMinutes *int
	Color            *string
	DeadlineAt       *time.Time
	Revision         int64
	CreatedAt        time.Time
	UpdatedAt        time.Time
	DeletedAt        *time.Time
}

func (t Todo) Snapshot() map[string]any {
	s := map[string]any{
		"id":               t.ID,
		"title":            t.Title,
		"type":             t.Type,
		"description":      t.Description,
		"categoryId":       t.CategoryID,
		"tagIds":           t.TagIDs,
		"priority":         t.Priority,
		"status":           t.Status,
		"estimatedMinutes": t.EstimatedMinutes,
		"color":            t.Color,
		"revision":         t.Revision,
		"createdAt":        t.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":        t.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if t.DeadlineAt != nil {
		s["deadlineAt"] = t.DeadlineAt.UTC().Format(time.RFC3339)
	} else {
		s["deadlineAt"] = nil
	}
	if t.DeletedAt != nil {
		s["deletedAt"] = t.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (t Todo) DTO() map[string]any {
	if t.TagIDs == nil {
		t.TagIDs = []string{}
	}
	return t.Snapshot()
}

type Block struct {
	ID        string
	UserID    string
	TodoID    string
	StartAt   time.Time
	EndAt     time.Time
	BlockNote *string
	Status    string
	Revision  int64
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

func (b Block) Snapshot() map[string]any {
	s := map[string]any{
		"id":        b.ID,
		"todoId":    b.TodoID,
		"startAt":   b.StartAt.UTC().Format(time.RFC3339),
		"endAt":     b.EndAt.UTC().Format(time.RFC3339),
		"blockNote": b.BlockNote,
		"status":    b.Status,
		"revision":  b.Revision,
		"createdAt": b.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt": b.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if b.DeletedAt != nil {
		s["deletedAt"] = b.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (b Block) DTO() map[string]any { return b.Snapshot() }

// ---- repository ---------------------------------------------------------------

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const todoColumns = `id, user_id, title, type, description, category_id, tag_ids, priority, status, estimated_minutes, color, deadline_at, revision, created_at, updated_at, deleted_at`

func scanTodo(scanner interface {
	Scan(dest ...any) error
}) (Todo, error) {
	var t Todo
	var id uuid.UUID
	var tagIDs []byte
	if err := scanner.Scan(&id, &t.UserID, &t.Title, &t.Type, &t.Description, &t.CategoryID, &tagIDs,
		&t.Priority, &t.Status, &t.EstimatedMinutes, &t.Color, &t.DeadlineAt,
		&t.Revision, &t.CreatedAt, &t.UpdatedAt, &t.DeletedAt); err != nil {
		return t, err
	}
	t.ID = id.String()
	t.TagIDs = []string{}
	if len(tagIDs) > 0 {
		_ = json.Unmarshal(tagIDs, &t.TagIDs)
	}
	return t, nil
}

func (r *Repo) Create(ctx context.Context, db sync.DBTX, t *Todo) error {
	if t.ID == "" {
		t.ID = uuid.NewString()
	}
	now := time.Now().UTC()
	t.CreatedAt, t.UpdatedAt, t.Revision = now, now, 1
	tagIDs, err := json.Marshal(nonNil(t.TagIDs))
	if err != nil {
		return err
	}
	if _, err := db.Exec(ctx, `
		INSERT INTO todos (id, user_id, title, type, description, category_id, tag_ids, priority, status, estimated_minutes, color, deadline_at, created_at, updated_at, revision)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$13,1)`,
		t.ID, t.UserID, t.Title, t.Type, t.Description, t.CategoryID, tagIDs,
		t.Priority, t.Status, t.EstimatedMinutes, t.Color, t.DeadlineAt, now); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, t.UserID, sync.EntityTodo, t.ID, sync.OpCreate, 1, t.Snapshot())
	return err
}

func (r *Repo) List(ctx context.Context, userID string, filter ListFilter) ([]Todo, error) {
	query := `SELECT ` + todoColumns + ` FROM todos WHERE user_id = $1 AND deleted_at IS NULL`
	args := []any{userID}
	n := 2
	if filter.Status != "" {
		query += ` AND status = $` + itoa(n)
		args = append(args, filter.Status)
		n++
	}
	if filter.CategoryID != "" {
		query += ` AND category_id = $` + itoa(n)
		args = append(args, filter.CategoryID)
		n++
	}
	if filter.Type != "" {
		query += ` AND type = $` + itoa(n)
		args = append(args, filter.Type)
		n++
	}
	if len(filter.TagIDs) > 0 {
		query += ` AND tag_ids @> $` + itoa(n)
		args = append(args, filter.TagIDs)
		n++
	}
	query += ` ORDER BY created_at DESC`
	rows, err := r.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Todo
	for rows.Next() {
		t, err := scanTodo(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, rows.Err()
}

func (r *Repo) Get(ctx context.Context, userID, todoID string) (Todo, error) {
	if _, err := uuid.Parse(todoID); err != nil {
		return Todo{}, apperr.NotFound("todo")
	}
	t, err := scanTodo(r.pool.QueryRow(ctx, `SELECT `+todoColumns+` FROM todos
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, todoID, userID))
	if err == pgx.ErrNoRows {
		return t, apperr.NotFound("todo")
	}
	return t, err
}

// GetAny loads a todo regardless of tombstone state (sync conflict handling).
func (r *Repo) GetAny(ctx context.Context, userID, todoID string) (Todo, error) {
	if _, err := uuid.Parse(todoID); err != nil {
		return Todo{}, apperr.NotFound("todo")
	}
	t, err := scanTodo(r.pool.QueryRow(ctx, `SELECT `+todoColumns+` FROM todos
		WHERE id = $1 AND user_id = $2`, todoID, userID))
	if err == pgx.ErrNoRows {
		return t, apperr.NotFound("todo")
	}
	return t, err
}

func (r *Repo) Update(ctx context.Context, db sync.DBTX, t *Todo, upd UpdateCmd, baseRevision int64) error {
	applyTodoUpdate(t, upd)
	tagIDs, err := json.Marshal(nonNil(t.TagIDs))
	if err != nil {
		return err
	}
	var newRev int64
	err = db.QueryRow(ctx, `
		UPDATE todos
		SET title=$3, type=$4, description=$5, category_id=$6, tag_ids=$7, priority=$8, status=$9,
		    estimated_minutes=$10, color=$11, deadline_at=$12, updated_at=now(), revision=revision+1
		WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL AND revision=$13
		RETURNING revision, updated_at`,
		t.ID, t.UserID, t.Title, t.Type, t.Description, t.CategoryID, tagIDs,
		t.Priority, t.Status, t.EstimatedMinutes, t.Color, t.DeadlineAt, baseRevision).Scan(&newRev, &t.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.StaleRevision(sync.EntityTodo, t.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	t.Revision = newRev
	_, err = sync.AppendChange(ctx, db, t.UserID, sync.EntityTodo, t.ID, sync.OpUpdate, newRev, t.Snapshot())
	return err
}

// Delete tombstones the todo and all its blocks (each journaled).
func (r *Repo) Delete(ctx context.Context, db sync.DBTX, t *Todo) error {
	blocks, err := r.ListBlocks(ctx, t.UserID, t.ID)
	if err != nil {
		return err
	}
	for _, b := range blocks {
		if err := r.DeleteBlock(ctx, db, &b); err != nil {
			return err
		}
	}
	var rev int64
	var deletedAt time.Time
	if err := db.QueryRow(ctx, `UPDATE todos SET deleted_at=now(), revision=revision+1, updated_at=now()
		WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, t.ID).Scan(&rev, &deletedAt); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, t.UserID, sync.EntityTodo, t.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(t.Snapshot(), rev, deletedAt))
	return err
}

// ---- blocks ----------------------------------------------------------------

const blockColumns = `id, user_id, todo_id, start_at, end_at, block_note, status, revision, created_at, updated_at, deleted_at`

func scanBlock(scanner interface {
	Scan(dest ...any) error
}) (Block, error) {
	var b Block
	var id uuid.UUID
	if err := scanner.Scan(&id, &b.UserID, &b.TodoID, &b.StartAt, &b.EndAt, &b.BlockNote, &b.Status,
		&b.Revision, &b.CreatedAt, &b.UpdatedAt, &b.DeletedAt); err != nil {
		return b, err
	}
	b.ID = id.String()
	return b, nil
}

func (r *Repo) CreateBlock(ctx context.Context, db sync.DBTX, b *Block) error {
	if b.ID == "" {
		b.ID = uuid.NewString()
	}
	now := time.Now().UTC()
	b.CreatedAt, b.UpdatedAt, b.Revision = now, now, 1
	if _, err := db.Exec(ctx, `
		INSERT INTO todo_blocks (id, user_id, todo_id, start_at, end_at, block_note, status, created_at, updated_at, revision)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$8,1)`,
		b.ID, b.UserID, b.TodoID, b.StartAt, b.EndAt, b.BlockNote, b.Status, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, db, b.UserID, sync.EntityTodoBlock, b.ID, sync.OpCreate, 1, b.Snapshot())
	return err
}

func (r *Repo) ListBlocks(ctx context.Context, userID, todoID string) ([]Block, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+blockColumns+` FROM todo_blocks
		WHERE user_id=$1 AND todo_id=$2 AND deleted_at IS NULL ORDER BY start_at`, userID, todoID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Block
	for rows.Next() {
		b, err := scanBlock(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

// BlocksInRange returns every live block of a user overlapping [start,end].
func (r *Repo) BlocksInRange(ctx context.Context, userID string, start, end time.Time) ([]Block, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+blockColumns+` FROM todo_blocks
		WHERE user_id=$1 AND deleted_at IS NULL AND start_at < $3 AND end_at > $2
		ORDER BY start_at`, userID, start, end)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Block
	for rows.Next() {
		b, err := scanBlock(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, rows.Err()
}

func (r *Repo) GetBlock(ctx context.Context, userID, blockID string) (Block, error) {
	if _, err := uuid.Parse(blockID); err != nil {
		return Block{}, apperr.NotFound("todo block")
	}
	b, err := scanBlock(r.pool.QueryRow(ctx, `SELECT `+blockColumns+` FROM todo_blocks
		WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL`, blockID, userID))
	if err == pgx.ErrNoRows {
		return b, apperr.NotFound("todo block")
	}
	return b, err
}

// GetBlockAny loads a block regardless of tombstone state.
func (r *Repo) GetBlockAny(ctx context.Context, userID, blockID string) (Block, error) {
	if _, err := uuid.Parse(blockID); err != nil {
		return Block{}, apperr.NotFound("todo block")
	}
	b, err := scanBlock(r.pool.QueryRow(ctx, `SELECT `+blockColumns+` FROM todo_blocks
		WHERE id=$1 AND user_id=$2`, blockID, userID))
	if err == pgx.ErrNoRows {
		return b, apperr.NotFound("todo block")
	}
	return b, err
}

func (r *Repo) UpdateBlock(ctx context.Context, db sync.DBTX, b *Block, upd UpdateBlockCmd, baseRevision int64) error {
	applyBlockUpdate(b, upd)
	var newRev int64
	err := db.QueryRow(ctx, `
		UPDATE todo_blocks
		SET start_at=$3, end_at=$4, block_note=$5, status=$6, updated_at=now(), revision=revision+1
		WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL AND revision=$7
		RETURNING revision, updated_at`,
		b.ID, b.UserID, b.StartAt, b.EndAt, b.BlockNote, b.Status, baseRevision).Scan(&newRev, &b.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.StaleRevision(sync.EntityTodoBlock, b.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	b.Revision = newRev
	_, err = sync.AppendChange(ctx, db, b.UserID, sync.EntityTodoBlock, b.ID, sync.OpUpdate, newRev, b.Snapshot())
	return err
}

func (r *Repo) DeleteBlock(ctx context.Context, db sync.DBTX, b *Block) error {
	var rev int64
	var deletedAt time.Time
	if err := db.QueryRow(ctx, `UPDATE todo_blocks SET deleted_at=now(), revision=revision+1, updated_at=now()
		WHERE id=$1 AND deleted_at IS NULL RETURNING revision, deleted_at`, b.ID).Scan(&rev, &deletedAt); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, db, b.UserID, sync.EntityTodoBlock, b.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(b.Snapshot(), rev, deletedAt))
	return err
}

// ---- update commands ---------------------------------------------------------

type UpdateCmd struct {
	Title            *string
	Type             *string
	Description      *string
	CategoryID       *string
	TagIDs           []string
	HasTagIDs        bool
	Priority         *string
	Status           *string
	EstimatedMinutes *int
	Color            *string
	DeadlineAt       *time.Time
	HasDeadline      bool // distinguishes "set to null" from "not provided"
}

func applyTodoUpdate(t *Todo, upd UpdateCmd) {
	if upd.Title != nil {
		t.Title = *upd.Title
	}
	if upd.Type != nil {
		t.Type = *upd.Type
	}
	if upd.Description != nil {
		t.Description = upd.Description
	}
	if upd.CategoryID != nil {
		t.CategoryID = upd.CategoryID
	}
	if upd.HasTagIDs {
		t.TagIDs = upd.TagIDs
	}
	if upd.Priority != nil {
		t.Priority = *upd.Priority
	}
	if upd.Status != nil {
		t.Status = *upd.Status
	}
	if upd.EstimatedMinutes != nil {
		t.EstimatedMinutes = upd.EstimatedMinutes
	}
	if upd.Color != nil {
		t.Color = upd.Color
	}
	if upd.HasDeadline {
		t.DeadlineAt = upd.DeadlineAt
	}
}

type UpdateBlockCmd struct {
	StartAt   *time.Time
	EndAt     *time.Time
	BlockNote *string
	Status    *string
}

func applyBlockUpdate(b *Block, upd UpdateBlockCmd) {
	if upd.StartAt != nil {
		b.StartAt = *upd.StartAt
	}
	if upd.EndAt != nil {
		b.EndAt = *upd.EndAt
	}
	if upd.BlockNote != nil {
		b.BlockNote = upd.BlockNote
	}
	if upd.Status != nil {
		b.Status = *upd.Status
	}
}

// ---- validation helpers --------------------------------------------------------

func ValidateTodoFields(title, typ, priority, status string) error {
	if title == "" || len(title) > 200 {
		return apperr.Validation("title", "must be 1-200 characters")
	}
	if typ != TypeOneOff && typ != TypeProject {
		return apperr.Validation("type", "must be one_off or project")
	}
	switch priority {
	case PriorityLow, PriorityNormal, PriorityHigh, PriorityUrgent:
	default:
		return apperr.Validation("priority", "must be low, normal, high or urgent")
	}
	switch status {
	case StatusTodo, StatusInProgress, StatusCompleted, StatusCancelled:
	default:
		return apperr.Validation("status", "must be todo, in_progress, completed or cancelled")
	}
	return nil
}

func ValidateBlockTimes(start, end time.Time, loc *time.Location) error {
	return timeutil.CheckSameLocalDay(start, end, loc, "todo block")
}

func nonNil(v []string) []string {
	if v == nil {
		return []string{}
	}
	return v
}

func itoa(n int) string {
	return strconv.Itoa(n)
}

type ListFilter struct {
	Status     string
	CategoryID string
	Type       string
	TagIDs     []string
}
