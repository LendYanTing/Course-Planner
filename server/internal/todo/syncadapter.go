package todo

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// TodoAdapter plugs todos into the sync push engine.
type TodoAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewTodoAdapter(pool *pgxpool.Pool, repo *Repo) *TodoAdapter {
	return &TodoAdapter{repo: repo, pool: pool}
}

func (a *TodoAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	t, err := a.repo.GetAny(ctx, userID, entityID)
	if err != nil {
		if ae, ok := apperr.From(err); ok && ae.Code == apperr.CodeNotFound {
			return nil, 0, sync.StateMissing, nil
		}
		return nil, 0, sync.StateMissing, err
	}
	if t.DeletedAt != nil {
		return t.Snapshot(), t.Revision, sync.StateDeleted, nil
	}
	return t.Snapshot(), t.Revision, sync.StateLive, nil
}

func (a *TodoAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	cmd, err := todoFromFields(fields)
	if err != nil {
		return err
	}
	t := Todo{
		ID: entityID, UserID: userID,
		Title: cmd.Title, Type: cmd.Type, Description: cmd.Description,
		CategoryID: cmd.CategoryID, TagIDs: nonNil(cmd.TagIDs),
		Priority: cmd.Priority, Status: cmd.Status,
		EstimatedMinutes: cmd.EstimatedMinutes, Color: cmd.Color, DeadlineAt: cmd.DeadlineAt,
	}
	return a.repo.Create(ctx, tx, &t)
}

func (a *TodoAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd, err := todoUpdateFromFields(fields)
	if err != nil {
		return 0, err
	}
	t, err := a.repo.GetAny(ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if t.DeletedAt != nil {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	if err := a.repo.Update(ctx, tx, &t, upd, baseRevision); err != nil {
		return 0, err
	}
	return t.Revision, nil
}

func (a *TodoAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	t, err := a.repo.GetAny(ctx, userID, entityID)
	if err != nil {
		return err
	}
	if t.DeletedAt != nil {
		return nil // idempotent
	}
	return a.repo.Delete(ctx, tx, &t)
}

// BlockAdapter plugs todo blocks into the sync push engine.
type BlockAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
	loc  func(ctx context.Context, userID string) *time.Location
}

func NewBlockAdapter(pool *pgxpool.Pool, repo *Repo, tz func(ctx context.Context, userID string) *time.Location) *BlockAdapter {
	return &BlockAdapter{repo: repo, pool: pool, loc: tz}
}

func (a *BlockAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	b, err := a.repo.GetBlockAny(ctx, userID, entityID)
	if err != nil {
		if ae, ok := apperr.From(err); ok && ae.Code == apperr.CodeNotFound {
			return nil, 0, sync.StateMissing, nil
		}
		return nil, 0, sync.StateMissing, err
	}
	if b.DeletedAt != nil {
		return b.Snapshot(), b.Revision, sync.StateDeleted, nil
	}
	return b.Snapshot(), b.Revision, sync.StateLive, nil
}

func (a *BlockAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	cmd, err := blockFromFields(fields)
	if err != nil {
		return err
	}
	if _, err := a.repo.Get(ctx, userID, cmd.TodoID); err != nil {
		return apperr.Validation("todoId", "parent todo does not exist")
	}
	loc := a.loc(ctx, userID)
	if err := ValidateBlockTimes(cmd.StartAt, cmd.EndAt, loc); err != nil {
		return err
	}
	b := Block{
		ID: entityID, UserID: userID, TodoID: cmd.TodoID,
		StartAt: cmd.StartAt, EndAt: cmd.EndAt, BlockNote: cmd.BlockNote, Status: cmd.Status,
	}
	return a.repo.CreateBlock(ctx, tx, &b)
}

func (a *BlockAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd, err := blockUpdateFromFields(fields)
	if err != nil {
		return 0, err
	}
	b, err := a.repo.GetBlockAny(ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if b.DeletedAt != nil {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	next := b
	applyBlockUpdate(&next, upd)
	loc := a.loc(ctx, userID)
	if err := ValidateBlockTimes(next.StartAt, next.EndAt, loc); err != nil {
		return 0, err
	}
	if err := a.repo.UpdateBlock(ctx, tx, &next, upd, baseRevision); err != nil {
		return 0, err
	}
	return next.Revision, nil
}

func (a *BlockAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	b, err := a.repo.GetBlockAny(ctx, userID, entityID)
	if err != nil {
		return err
	}
	if b.DeletedAt != nil {
		return nil
	}
	return a.repo.DeleteBlock(ctx, tx, &b)
}

// ---- map decoders -------------------------------------------------------------

func todoFromFields(f map[string]any) (CreateCmd, error) {
	cmd := CreateCmd{Type: TypeOneOff, Priority: PriorityNormal, Status: StatusTodo}
	var err error
	if cmd.Title, err = reqString(f, "title", true); err != nil {
		return cmd, err
	}
	if v, ok := f["type"].(string); ok && v != "" {
		cmd.Type = v
	}
	cmd.Description, err = reqStringPtr(f, "description")
	if err != nil {
		return cmd, err
	}
	cmd.CategoryID, err = reqStringPtr(f, "categoryId")
	if err != nil {
		return cmd, err
	}
	if raw, ok := f["tagIds"].([]any); ok {
		cmd.TagIDs = []string{}
		for _, v := range raw {
			if s, ok := v.(string); ok {
				cmd.TagIDs = append(cmd.TagIDs, s)
			}
		}
	}
	if v, ok := f["priority"].(string); ok {
		cmd.Priority = v
	}
	if v, ok := f["status"].(string); ok {
		cmd.Status = v
	}
	cmd.EstimatedMinutes, err = reqIntPtr(f, "estimatedMinutes")
	if err != nil {
		return cmd, err
	}
	cmd.Color, err = reqStringPtr(f, "color")
	if err != nil {
		return cmd, err
	}
	if v, ok := f["deadlineAt"]; ok && v != nil {
		s, ok := v.(string)
		if !ok {
			return cmd, apperr.Validation("deadlineAt", "must be RFC3339")
		}
		t, err := timeutil.ParseInstant(s)
		if err != nil {
			return cmd, err
		}
		cmd.DeadlineAt = &t
	}
	if err := ValidateTodoFields(cmd.Title, cmd.Type, cmd.Priority, cmd.Status); err != nil {
		return cmd, err
	}
	return cmd, nil
}

func todoUpdateFromFields(f map[string]any) (UpdateCmd, error) {
	upd := UpdateCmd{}
	var err error
	if has(f, "title") {
		v, err := reqString(f, "title", true)
		if err != nil {
			return upd, err
		}
		upd.Title = &v
	}
	if has(f, "type") {
		v, err := reqString(f, "type", true)
		if err != nil {
			return upd, err
		}
		upd.Type = &v
	}
	if has(f, "description") {
		upd.Description, err = reqStringPtr(f, "description")
		if err != nil {
			return upd, err
		}
	}
	if has(f, "categoryId") {
		upd.CategoryID, err = reqStringPtr(f, "categoryId")
		if err != nil {
			return upd, err
		}
	}
	if has(f, "tagIds") {
		upd.HasTagIDs = true
		upd.TagIDs = []string{}
		if raw, ok := f["tagIds"].([]any); ok {
			for _, v := range raw {
				if s, ok := v.(string); ok {
					upd.TagIDs = append(upd.TagIDs, s)
				}
			}
		}
	}
	if has(f, "priority") {
		v, err := reqString(f, "priority", true)
		if err != nil {
			return upd, err
		}
		upd.Priority = &v
	}
	if has(f, "status") {
		v, err := reqString(f, "status", true)
		if err != nil {
			return upd, err
		}
		upd.Status = &v
	}
	if has(f, "estimatedMinutes") {
		upd.EstimatedMinutes, err = reqIntPtr(f, "estimatedMinutes")
		if err != nil {
			return upd, err
		}
	}
	if has(f, "color") {
		upd.Color, err = reqStringPtr(f, "color")
		if err != nil {
			return upd, err
		}
	}
	if has(f, "deadlineAt") {
		upd.HasDeadline = true
		if v, ok := f["deadlineAt"].(string); ok && v != "" {
			t, err := timeutil.ParseInstant(v)
			if err != nil {
				return upd, err
			}
			upd.DeadlineAt = &t
		}
	}
	return upd, nil
}

func blockFromFields(f map[string]any) (CreateBlockCmd, error) {
	cmd := CreateBlockCmd{Status: BlockStatusScheduled}
	var err error
	if cmd.TodoID, err = reqString(f, "todoId", true); err != nil {
		return cmd, err
	}
	startStr, err := reqString(f, "startAt", true)
	if err != nil {
		return cmd, err
	}
	endStr, err := reqString(f, "endAt", true)
	if err != nil {
		return cmd, err
	}
	if cmd.StartAt, err = timeutil.ParseInstant(startStr); err != nil {
		return cmd, err
	}
	if cmd.EndAt, err = timeutil.ParseInstant(endStr); err != nil {
		return cmd, err
	}
	cmd.BlockNote, err = reqStringPtr(f, "blockNote")
	if err != nil {
		return cmd, err
	}
	if v, ok := f["status"].(string); ok && v != "" {
		cmd.Status = v
	}
	switch cmd.Status {
	case BlockStatusScheduled, BlockStatusInProgress, BlockStatusCompleted, BlockStatusSkipped:
	default:
		return cmd, apperr.Validation("status", "invalid block status")
	}
	return cmd, nil
}

func blockUpdateFromFields(f map[string]any) (UpdateBlockCmd, error) {
	upd := UpdateBlockCmd{}
	if has(f, "startAt") {
		s, ok := f["startAt"].(string)
		if !ok || s == "" {
			return upd, apperr.Validation("startAt", "must be RFC3339")
		}
		t, err := timeutil.ParseInstant(s)
		if err != nil {
			return upd, err
		}
		upd.StartAt = &t
	}
	if has(f, "endAt") {
		s, ok := f["endAt"].(string)
		if !ok || s == "" {
			return upd, apperr.Validation("endAt", "must be RFC3339")
		}
		t, err := timeutil.ParseInstant(s)
		if err != nil {
			return upd, err
		}
		upd.EndAt = &t
	}
	var err error
	if has(f, "blockNote") {
		upd.BlockNote, err = reqStringPtr(f, "blockNote")
		if err != nil {
			return upd, err
		}
	}
	if has(f, "status") {
		v, err := reqString(f, "status", true)
		if err != nil {
			return upd, err
		}
		upd.Status = &v
	}
	return upd, nil
}

func has(f map[string]any, key string) bool {
	_, ok := f[key]
	return ok
}

func reqString(f map[string]any, key string, required bool) (string, error) {
	v, ok := f[key]
	if !ok || v == nil {
		if required {
			return "", apperr.Validation(key, "is required")
		}
		return "", nil
	}
	s, ok := v.(string)
	if !ok {
		return "", apperr.Validation(key, "must be a string")
	}
	return s, nil
}

func reqStringPtr(f map[string]any, key string) (*string, error) {
	v, ok := f[key]
	if !ok || v == nil {
		return nil, nil
	}
	s, ok := v.(string)
	if !ok {
		return nil, apperr.Validation(key, "must be a string or null")
	}
	return &s, nil
}

func reqIntPtr(f map[string]any, key string) (*int, error) {
	v, ok := f[key]
	if !ok || v == nil {
		return nil, nil
	}
	switch n := v.(type) {
	case float64:
		i := int(n)
		return &i, nil
	case int:
		return &n, nil
	default:
		return nil, apperr.Validation(key, "must be an integer or null")
	}
}
