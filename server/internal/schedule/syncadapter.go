package schedule

import (
	"context"
	"encoding/json"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// RecurringAdapter plugs recurring schedules into the sync push engine.
type RecurringAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewRecurringAdapter(pool *pgxpool.Pool, repo *Repo) *RecurringAdapter {
	return &RecurringAdapter{repo: repo, pool: pool}
}

func loadRecurringAny(repo *Repo, ctx context.Context, userID, id string) (RecurringSchedule, sync.EntityState, error) {
	if _, err := uuid.Parse(id); err != nil {
		return RecurringSchedule{}, sync.StateMissing, apperr.NotFound("recurring schedule")
	}
	rs, err := scanRS(repo.pool.QueryRow(ctx, `SELECT `+rsColumns+` FROM recurring_schedules WHERE id=$1 AND user_id=$2`, id, userID))
	if err != nil {
		return rs, sync.StateMissing, nil
	}
	if rs.DeletedAt != nil {
		return rs, sync.StateDeleted, nil
	}
	return rs, sync.StateLive, nil
}

func (a *RecurringAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	rs, state, err := loadRecurringAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return rs.Snapshot(), rs.Revision, state, nil
}

func (a *RecurringAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	title, err := adaptString(fields, "title")
	if err != nil {
		return err
	}
	rule, err := adaptRule(fields)
	if err != nil {
		return err
	}
	if err := rule.Validate(); err != nil {
		return err
	}
	rs := RecurringSchedule{
		ID: entityID, UserID: userID, Title: title, Rule: rule,
		Color: adaptStringPtr(fields, "color"), Notes: adaptStringPtr(fields, "notes"),
	}
	return a.repo.Create(ctx, tx, &rs)
}

func (a *RecurringAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd := UpdateCmd{}
	if has, v := adaptStringOpt(fields, "title"); has {
		upd.Title = v
	}
	if has, v := adaptStringOpt(fields, "color"); has {
		upd.Color = v
	}
	if has, v := adaptStringOpt(fields, "notes"); has {
		upd.Notes = v
	}
	if raw, ok := fields["rule"]; ok {
		var rule Rule
		jsonBytes, err := json.Marshal(raw)
		if err != nil {
			return 0, apperr.Validation("rule", "invalid rule object")
		}
		if err := json.Unmarshal(jsonBytes, &rule); err != nil {
			return 0, apperr.Validation("rule", "invalid rule object")
		}
		if err := rule.Validate(); err != nil {
			return 0, err
		}
		upd.Rule = &rule
	}
	rs, state, err := loadRecurringAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	if upd.Title != nil && (*upd.Title == "" || len(*upd.Title) > 100) {
		return 0, apperr.Validation("title", "must be 1-100 characters")
	}
	if err := a.repo.Update(ctx, tx, &rs, upd, baseRevision); err != nil {
		return 0, err
	}
	return rs.Revision, nil
}

func (a *RecurringAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	rs, state, err := loadRecurringAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	return a.repo.Delete(ctx, tx, &rs)
}

func adaptString(f map[string]any, key string) (string, error) {
	v, ok := f[key]
	if !ok || v == nil {
		return "", apperr.Validation(key, "is required")
	}
	s, ok := v.(string)
	if !ok {
		return "", apperr.Validation(key, "must be a string")
	}
	return s, nil
}

func adaptStringPtr(f map[string]any, key string) *string {
	if v, ok := f[key]; ok && v != nil {
		if s, ok := v.(string); ok {
			return &s
		}
	}
	return nil
}

func adaptStringOpt(f map[string]any, key string) (bool, *string) {
	if v, ok := f[key]; ok {
		if v == nil {
			return true, nil
		}
		if s, ok := v.(string); ok {
			return true, &s
		}
	}
	return false, nil
}

func adaptRule(f map[string]any) (Rule, error) {
	v, ok := f["rule"]
	if !ok || v == nil {
		return Rule{}, apperr.Validation("rule", "is required")
	}
	jsonBytes, err := json.Marshal(v)
	if err != nil {
		return Rule{}, apperr.Validation("rule", "invalid rule object")
	}
	var rule Rule
	if err := json.Unmarshal(jsonBytes, &rule); err != nil {
		return Rule{}, apperr.Validation("rule", "invalid rule object")
	}
	return rule, nil
}
