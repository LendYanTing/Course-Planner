package todo

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Service holds todo/block domain rules. ConflictState on write responses is
// computed against course occurrences via the ConflictProbe injected at
// wiring time (keeps this package independent of course expansion).
type Service struct {
	pool       *pgxpool.Pool
	repo       *Repo
	Conflicter ConflictProbe
}

// ConflictProbe reports whether [start,end) overlaps any course occurrence
// (soft-conflict detection for todo blocks).
type ConflictProbe func(ctx context.Context, userID string, start, end time.Time) (bool, error)

func NewService(pool *pgxpool.Pool, repo *Repo) *Service {
	return &Service{pool: pool, repo: repo}
}

func (s *Service) SetConflicter(probe ConflictProbe) { s.Conflicter = probe }

// ---- todos -----------------------------------------------------------------

type CreateCmd struct {
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
}

func (s *Service) Create(ctx context.Context, userID string, cmd CreateCmd) (Todo, error) {
	if cmd.Type == "" {
		cmd.Type = TypeOneOff
	}
	if cmd.Priority == "" {
		cmd.Priority = PriorityNormal
	}
	if cmd.Status == "" {
		cmd.Status = StatusTodo
	}
	if err := ValidateTodoFields(cmd.Title, cmd.Type, cmd.Priority, cmd.Status); err != nil {
		return Todo{}, err
	}
	t := Todo{
		UserID: userID, Title: cmd.Title, Type: cmd.Type,
		Description: cmd.Description, CategoryID: cmd.CategoryID,
		TagIDs: nonNil(cmd.TagIDs), Priority: cmd.Priority, Status: cmd.Status,
		EstimatedMinutes: cmd.EstimatedMinutes, Color: cmd.Color, DeadlineAt: cmd.DeadlineAt,
	}
	err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Create(ctx, tx, &t)
	})
	return t, err
}

func (s *Service) List(ctx context.Context, userID string, filter ListFilter) ([]Todo, error) {
	return s.repo.List(ctx, userID, filter)
}

func (s *Service) Get(ctx context.Context, userID, id string) (Todo, error) {
	return s.repo.Get(ctx, userID, id)
}

func (s *Service) Update(ctx context.Context, userID, id string, upd UpdateCmd, baseRevision int64) (Todo, error) {
	t, err := s.repo.Get(ctx, userID, id)
	if err != nil {
		return t, err
	}
	next := t
	applyTodoUpdate(&next, upd)
	if err := ValidateTodoFields(next.Title, next.Type, next.Priority, next.Status); err != nil {
		return t, err
	}
	if baseRevision == 0 {
		baseRevision = t.Revision
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Update(ctx, tx, &next, upd, baseRevision)
	})
	return next, err
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	t, err := s.repo.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Delete(ctx, tx, &t)
	})
}

// ---- blocks ------------------------------------------------------------------

type CreateBlockCmd struct {
	TodoID    string
	StartAt   time.Time
	EndAt     time.Time
	BlockNote *string
	Status    string
}

// CreateBlockResult carries the block plus its computed conflict state.
type CreateBlockResult struct {
	Block         Block
	ConflictState string // none | soft_conflict
}

func (s *Service) CreateBlock(ctx context.Context, userID string, cmd CreateBlockCmd, loc *time.Location) (CreateBlockResult, error) {
	t, err := s.repo.Get(ctx, userID, cmd.TodoID)
	if err != nil {
		return CreateBlockResult{}, err
	}
	if err := ValidateBlockTimes(cmd.StartAt, cmd.EndAt, loc); err != nil {
		return CreateBlockResult{}, err
	}
	if cmd.Status == "" {
		cmd.Status = BlockStatusScheduled
	}
	if cmd.Status != BlockStatusScheduled && cmd.Status != BlockStatusInProgress &&
		cmd.Status != BlockStatusCompleted && cmd.Status != BlockStatusSkipped {
		return CreateBlockResult{}, apperr.Validation("status", "invalid block status")
	}
	b := Block{
		UserID: userID, TodoID: t.ID, StartAt: cmd.StartAt, EndAt: cmd.EndAt,
		BlockNote: cmd.BlockNote, Status: cmd.Status,
	}
	if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.CreateBlock(ctx, tx, &b)
	}); err != nil {
		return CreateBlockResult{}, err
	}
	state := "none"
	if s.Conflicter != nil {
		if overlaps, err := s.Conflicter(ctx, userID, b.StartAt, b.EndAt); err == nil && overlaps {
			state = "soft_conflict"
		}
	}
	return CreateBlockResult{Block: b, ConflictState: state}, nil
}

func (s *Service) ListBlocks(ctx context.Context, userID, todoID string) ([]Block, error) {
	if _, err := s.repo.Get(ctx, userID, todoID); err != nil {
		return nil, err
	}
	return s.repo.ListBlocks(ctx, userID, todoID)
}

func (s *Service) UpdateBlock(ctx context.Context, userID, id string, upd UpdateBlockCmd, baseRevision int64, loc *time.Location) (CreateBlockResult, error) {
	b, err := s.repo.GetBlock(ctx, userID, id)
	if err != nil {
		return CreateBlockResult{}, err
	}
	next := b
	applyBlockUpdate(&next, upd)
	if err := ValidateBlockTimes(next.StartAt, next.EndAt, loc); err != nil {
		return CreateBlockResult{}, err
	}
	if next.Status != BlockStatusScheduled && next.Status != BlockStatusInProgress &&
		next.Status != BlockStatusCompleted && next.Status != BlockStatusSkipped {
		return CreateBlockResult{}, apperr.Validation("status", "invalid block status")
	}
	if baseRevision == 0 {
		baseRevision = b.Revision
	}
	if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.UpdateBlock(ctx, tx, &next, upd, baseRevision)
	}); err != nil {
		return CreateBlockResult{}, err
	}
	state := "none"
	if s.Conflicter != nil {
		if overlaps, err := s.Conflicter(ctx, userID, next.StartAt, next.EndAt); err == nil && overlaps {
			state = "soft_conflict"
		}
	}
	return CreateBlockResult{Block: next, ConflictState: state}, nil
}

func (s *Service) DeleteBlock(ctx context.Context, userID, id string) error {
	b, err := s.repo.GetBlock(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.DeleteBlock(ctx, tx, &b)
	})
}
