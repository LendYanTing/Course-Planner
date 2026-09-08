package calendar

import (
	"context"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CalendarAdapter plugs academic calendars into the sync push engine.
type CalendarAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewCalendarAdapter(pool *pgxpool.Pool, repo *Repo) *CalendarAdapter {
	return &CalendarAdapter{repo: repo, pool: pool}
}

func loadCalendarAny(repo *Repo, ctx context.Context, userID, id string) (Calendar, sync.EntityState, error) {
	var c Calendar
	if _, err := parseUUID(id); err != nil {
		return c, sync.StateMissing, apperr.NotFound("calendar")
	}
	row := repo.pool.QueryRow(ctx, `SELECT `+calendarColumns+` FROM academic_calendars WHERE id=$1 AND user_id=$2`, id, userID)
	var err error
	c, err = scanCalendarAny(row)
	if err != nil {
		if ae, ok := apperr.From(err); ok && ae.Code == apperr.CodeNotFound {
			return c, sync.StateMissing, nil
		}
		return c, sync.StateMissing, err
	}
	if c.DeletedAt != nil {
		return c, sync.StateDeleted, nil
	}
	return c, sync.StateLive, nil
}

const calendarColumns = `id, user_id, name, first_day, total_weeks, revision, created_at, updated_at, deleted_at`

func scanCalendarAny(scanner interface {
	Scan(dest ...any) error
}) (Calendar, error) {
	var c Calendar
	var id uuidValue
	if err := scanner.Scan(&id, &c.UserID, &c.Name, &c.FirstDay, &c.TotalWeeks, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt); err != nil {
		return c, apperr.NotFound("calendar")
	}
	c.ID = id.String()
	return c, nil
}

func (a *CalendarAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	c, state, err := loadCalendarAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return c.Snapshot(), c.Revision, state, nil
}

func (a *CalendarAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	cmd, err := calendarFromFields(fields)
	if err != nil {
		return err
	}
	c := Calendar{ID: entityID, UserID: userID, Name: cmd.Name, FirstDay: cmd.FirstDay, TotalWeeks: cmd.TotalWeeks}
	return a.repo.CreateCalendar(ctx, tx, &c)
}

func (a *CalendarAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd, err := calendarUpdateFromFields(fields)
	if err != nil {
		return 0, err
	}
	c, state, err := loadCalendarAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	if err := validateCalendarFields(c.Name, c.FirstDay, c.TotalWeeks); err != nil {
		return 0, err
	}
	if err := a.repo.UpdateCalendar(ctx, tx, &c, upd, baseRevision); err != nil {
		return 0, err
	}
	return c.Revision, nil
}

func (a *CalendarAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	c, state, err := loadCalendarAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state == sync.StateDeleted {
		return nil
	}
	if state == sync.StateMissing {
		return nil
	}
	return a.repo.DeleteCalendar(ctx, tx, &c)
}

func validateCalendarFields(name, firstDay string, totalWeeks int) error {
	if name == "" || len(name) > 100 {
		return apperr.Validation("name", "must be 1-100 characters")
	}
	if err := timeutil.ValidateDate(firstDay); err != nil {
		return err
	}
	if totalWeeks < 1 || totalWeeks > 60 {
		return apperr.Validation("totalWeeks", "must be between 1 and 60")
	}
	return nil
}

func calendarFromFields(f map[string]any) (CreateCalendarCmd, error) {
	cmd := CreateCalendarCmd{}
	var err error
	if cmd.Name, err = fieldString(f, "title"); err != nil {
		// calendars use "name"
		cmd.Name, err = fieldString(f, "name")
		if err != nil {
			return cmd, err
		}
	}
	if cmd.FirstDay, err = fieldString(f, "firstDay"); err != nil {
		return cmd, err
	}
	if v, ok := f["totalWeeks"].(float64); ok {
		cmd.TotalWeeks = int(v)
	}
	if err := validateCalendarFields(cmd.Name, cmd.FirstDay, cmd.TotalWeeks); err != nil {
		return cmd, err
	}
	return cmd, nil
}

func calendarUpdateFromFields(f map[string]any) (UpdateCalendarCmd, error) {
	upd := UpdateCalendarCmd{}
	if has, v := fieldStringOpt(f, "name"); has {
		upd.Name = v
	}
	if has, v := fieldStringOpt(f, "firstDay"); has {
		upd.FirstDay = v
	}
	if v, ok := f["totalWeeks"].(float64); ok {
		n := int(v)
		upd.TotalWeeks = &n
	}
	return upd, nil
}

func fieldString(f map[string]any, key string) (string, error) {
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

func fieldStringOpt(f map[string]any, key string) (bool, *string) {
	v, ok := f[key]
	if !ok {
		return false, nil
	}
	if v == nil {
		return true, nil
	}
	if s, ok := v.(string); ok {
		return true, &s
	}
	return true, nil
}

// PeriodAdapter plugs period templates into the sync push engine.
type PeriodAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewPeriodAdapter(pool *pgxpool.Pool, repo *Repo) *PeriodAdapter {
	return &PeriodAdapter{repo: repo, pool: pool}
}

func loadPeriodAny(repo *Repo, ctx context.Context, userID, id string) (Period, sync.EntityState, error) {
	var p Period
	if _, err := parseUUID(id); err != nil {
		return p, sync.StateMissing, apperr.NotFound("period")
	}
	row := repo.pool.QueryRow(ctx, `SELECT id, user_id, calendar_id, period_no, start_local, end_local, revision, created_at, updated_at, deleted_at
		FROM period_templates WHERE id=$1 AND user_id=$2`, id, userID)
	var pid uuidValue
	if err := row.Scan(&pid, &p.UserID, &p.CalendarID, &p.PeriodNo, &p.StartLocal, &p.EndLocal, &p.Revision, &p.CreatedAt, &p.UpdatedAt, &p.DeletedAt); err != nil {
		return p, sync.StateMissing, nil
	}
	p.ID = pid.String()
	if p.DeletedAt != nil {
		return p, sync.StateDeleted, nil
	}
	return p, sync.StateLive, nil
}

func (a *PeriodAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	p, state, err := loadPeriodAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return p.Snapshot(), p.Revision, state, nil
}

func (a *PeriodAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	calendarID, err := fieldString(fields, "calendarId")
	if err != nil {
		return err
	}
	p := Period{ID: entityID, UserID: userID, CalendarID: calendarID}
	if v, ok := fields["periodNo"].(float64); ok {
		p.PeriodNo = int(v)
	}
	if p.StartLocal, err = fieldString(fields, "startLocal"); err != nil {
		return err
	}
	if p.EndLocal, err = fieldString(fields, "endLocal"); err != nil {
		return err
	}
	if _, state, err := loadCalendarAny(a.repo, ctx, userID, calendarID); err != nil || state != sync.StateLive {
		return apperr.Validation("calendarId", "calendar does not exist")
	}
	if err := validatePeriod(p.PeriodNo, p.StartLocal, p.EndLocal); err != nil {
		return err
	}
	return a.repo.CreatePeriod(ctx, tx, &p)
}

func (a *PeriodAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd := UpdatePeriodCmd{}
	if v, ok := fields["periodNo"].(float64); ok {
		n := int(v)
		upd.PeriodNo = &n
	}
	if has, v := fieldStringOpt(fields, "startLocal"); has {
		upd.StartLocal = v
	}
	if has, v := fieldStringOpt(fields, "endLocal"); has {
		upd.EndLocal = v
	}
	p, state, err := loadPeriodAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	nextNo, nextStart, nextEnd := p.PeriodNo, p.StartLocal, p.EndLocal
	if upd.PeriodNo != nil {
		nextNo = *upd.PeriodNo
	}
	if upd.StartLocal != nil {
		nextStart = *upd.StartLocal
	}
	if upd.EndLocal != nil {
		nextEnd = *upd.EndLocal
	}
	if err := validatePeriod(nextNo, nextStart, nextEnd); err != nil {
		return 0, err
	}
	if err := a.repo.UpdatePeriod(ctx, tx, &p, upd, baseRevision); err != nil {
		return 0, err
	}
	return p.Revision, nil
}

func (a *PeriodAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	p, state, err := loadPeriodAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	return a.repo.DeletePeriod(ctx, tx, &p)
}
