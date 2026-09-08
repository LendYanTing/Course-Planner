// Package calendar owns academic calendars (semesters) and their period
// templates (docs/domain-model.md §2-3).
package calendar

import (
	"context"
	"encoding/json"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Calendar struct {
	ID         string
	UserID     string
	Name       string
	FirstDay   string // 'YYYY-MM-DD' local date
	TotalWeeks int
	Revision   int64
	CreatedAt  time.Time
	UpdatedAt  time.Time
	DeletedAt  *time.Time
}

func (c Calendar) Snapshot() map[string]any {
	s := map[string]any{
		"id":         c.ID,
		"name":       c.Name,
		"firstDay":   c.FirstDay,
		"totalWeeks": c.TotalWeeks,
		"revision":   c.Revision,
		"createdAt":  c.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":  c.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if c.DeletedAt != nil {
		s["deletedAt"] = c.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

type Period struct {
	ID         string
	UserID     string
	CalendarID string
	PeriodNo   int
	StartLocal string // 'HH:MM'
	EndLocal   string // 'HH:MM'
	Revision   int64
	CreatedAt  time.Time
	UpdatedAt  time.Time
	DeletedAt  *time.Time
}

func (p Period) Snapshot() map[string]any {
	s := map[string]any{
		"id":         p.ID,
		"calendarId": p.CalendarID,
		"periodNo":   p.PeriodNo,
		"startLocal": p.StartLocal,
		"endLocal":   p.EndLocal,
		"revision":   p.Revision,
		"createdAt":  p.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":  p.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if p.DeletedAt != nil {
		s["deletedAt"] = p.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (p Period) DTO() map[string]any { return p.Snapshot() }

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// ---- calendars -----------------------------------------------------------

func (r *Repo) CreateCalendar(ctx context.Context, db sync.DBTX, c *Calendar) error {
	c.ID = uuid.NewString()
	now := timeutil.Now()
	c.CreatedAt, c.UpdatedAt, c.Revision = now, now, 1
	if _, err := db.Exec(ctx, `
		INSERT INTO academic_calendars (id, user_id, name, first_day, total_weeks, created_at, updated_at, revision)
		VALUES ($1, $2, $3, $4, $5, $6, $6, 1)`,
		c.ID, c.UserID, c.Name, c.FirstDay, c.TotalWeeks, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, db, c.UserID, sync.EntityCalendar, c.ID, sync.OpCreate, 1, c.Snapshot())
	return err
}

func (r *Repo) ListCalendars(ctx context.Context, userID string) ([]Calendar, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, user_id, name, first_day, total_weeks, revision, created_at, updated_at, deleted_at
		FROM academic_calendars
		WHERE user_id = $1 AND deleted_at IS NULL
		ORDER BY first_day ASC, created_at ASC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Calendar
	for rows.Next() {
		var c Calendar
		var id uuid.UUID
		if err := rows.Scan(&id, &c.UserID, &c.Name, &c.FirstDay, &c.TotalWeeks, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt); err != nil {
			return nil, err
		}
		c.ID = id.String()
		out = append(out, c)
	}
	return out, rows.Err()
}

func (r *Repo) GetCalendar(ctx context.Context, userID, calendarID string) (Calendar, error) {
	var c Calendar
	var id uuid.UUID
	if _, err := uuid.Parse(calendarID); err != nil {
		return c, apperr.NotFound("calendar")
	}
	err := r.pool.QueryRow(ctx, `
		SELECT id, user_id, name, first_day, total_weeks, revision, created_at, updated_at, deleted_at
		FROM academic_calendars
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, calendarID, userID).
		Scan(&id, &c.UserID, &c.Name, &c.FirstDay, &c.TotalWeeks, &c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt)
	if err == pgx.ErrNoRows {
		return c, apperr.NotFound("calendar")
	}
	c.ID = id.String()
	return c, err
}

// UpdateCalendar applies a partial update, bumps revision and journals it.
// baseRevision > 0 enables optimistic locking (STALE_REVISION on mismatch).
func (r *Repo) UpdateCalendar(ctx context.Context, db sync.DBTX, c *Calendar, upd UpdateCalendarCmd, baseRevision int64) error {
	if upd.Name != nil {
		c.Name = *upd.Name
	}
	if upd.FirstDay != nil {
		c.FirstDay = *upd.FirstDay
	}
	if upd.TotalWeeks != nil {
		c.TotalWeeks = *upd.TotalWeeks
	}
	var newRev int64
	err := db.QueryRow(ctx, `
		UPDATE academic_calendars
		SET name = $3, first_day = $4, total_weeks = $5, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND revision = $6
		RETURNING revision, updated_at`,
		c.ID, c.UserID, c.Name, c.FirstDay, c.TotalWeeks, baseRevision).Scan(&newRev, &c.UpdatedAt)
	if err == pgx.ErrNoRows {
		// Distinguish stale revision from missing row.
		current, gerr := r.GetCalendar(ctx, c.UserID, c.ID)
		if gerr != nil {
			return gerr
		}
		return apperr.StaleRevision(sync.EntityCalendar, current.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	c.Revision = newRev
	_, err = sync.AppendChange(ctx, db, c.UserID, sync.EntityCalendar, c.ID, sync.OpUpdate, newRev, c.Snapshot())
	return err
}

// DeleteCalendar soft-deletes the calendar and cascades tombstones to all
// child periods, courses and meetings (each journaled individually).
func (r *Repo) DeleteCalendar(ctx context.Context, db sync.DBTX, c *Calendar) error {
	return r.tombstoneCalendar(ctx, db, c)
}

func (r *Repo) tombstoneCalendar(ctx context.Context, db sync.DBTX, c *Calendar) error {
	// Tombstone meetings of every course in this calendar.
	meetingRows, err := db.Query(ctx, `
		SELECT m.id, m.user_id FROM course_meetings m
		JOIN courses co ON co.id = m.course_id
		WHERE co.calendar_id = $1 AND co.deleted_at IS NULL AND m.deleted_at IS NULL`, c.ID)
	if err != nil {
		return err
	}
	var meetings []struct{ ID, UserID string }
	for meetingRows.Next() {
		var id uuid.UUID
		var userID string
		if err := meetingRows.Scan(&id, &userID); err != nil {
			meetingRows.Close()
			return err
		}
		meetings = append(meetings, struct{ ID, UserID string }{id.String(), userID})
	}
	meetingRows.Close()
	if err := meetingRows.Err(); err != nil {
		return err
	}

	// Tombstone overrides that point at these meetings (their series dies too).
	for _, m := range meetings {
		if err := tombstoneOverridesOfSeries(ctx, db, m.UserID, sync.EntityMeeting, m.ID); err != nil {
			return err
		}
		rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE course_meetings SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, m.ID)
		if err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, m.UserID, sync.EntityMeeting, m.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": m.ID}, rev, deletedAt)); err != nil {
			return err
		}
	}

	// Tombstone courses.
	courseRows, err := db.Query(ctx, `
		SELECT id, user_id FROM courses WHERE calendar_id = $1 AND deleted_at IS NULL`, c.ID)
	if err != nil {
		return err
	}
	var courses []struct{ ID, UserID string }
	for courseRows.Next() {
		var id uuid.UUID
		var userID string
		if err := courseRows.Scan(&id, &userID); err != nil {
			courseRows.Close()
			return err
		}
		courses = append(courses, struct{ ID, UserID string }{id.String(), userID})
	}
	courseRows.Close()
	if err := courseRows.Err(); err != nil {
		return err
	}
	for _, co := range courses {
		rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE courses SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, co.ID)
		if err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, co.UserID, sync.EntityCourse, co.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": co.ID}, rev, deletedAt)); err != nil {
			return err
		}
	}

	// Tombstone periods.
	periodRows, err := db.Query(ctx, `
		SELECT id, user_id FROM period_templates WHERE calendar_id = $1 AND deleted_at IS NULL`, c.ID)
	if err != nil {
		return err
	}
	var periods []struct{ ID, UserID string }
	for periodRows.Next() {
		var id uuid.UUID
		var userID string
		if err := periodRows.Scan(&id, &userID); err != nil {
			periodRows.Close()
			return err
		}
		periods = append(periods, struct{ ID, UserID string }{id.String(), userID})
	}
	periodRows.Close()
	if err := periodRows.Err(); err != nil {
		return err
	}
	for _, p := range periods {
		rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE period_templates SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, p.ID)
		if err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, p.UserID, sync.EntityPeriod, p.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": p.ID}, rev, deletedAt)); err != nil {
			return err
		}
	}

	// Finally the calendar itself.
	rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE academic_calendars SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, c.ID)
	if err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, c.UserID, sync.EntityCalendar, c.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(c.Snapshot(), rev, deletedAt))
	return err
}

// ---- periods -------------------------------------------------------------

func (r *Repo) CreatePeriod(ctx context.Context, db sync.DBTX, p *Period) error {
	p.ID = uuid.NewString()
	now := timeutil.Now()
	p.CreatedAt, p.UpdatedAt, p.Revision = now, now, 1
	if _, err := db.Exec(ctx, `
		INSERT INTO period_templates (id, user_id, calendar_id, period_no, start_local, end_local, created_at, updated_at, revision)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $7, 1)`,
		p.ID, p.UserID, p.CalendarID, p.PeriodNo, p.StartLocal, p.EndLocal, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, db, p.UserID, sync.EntityPeriod, p.ID, sync.OpCreate, 1, p.Snapshot())
	return err
}

func (r *Repo) ListPeriods(ctx context.Context, userID, calendarID string) ([]Period, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, user_id, calendar_id, period_no, start_local, end_local, revision, created_at, updated_at, deleted_at
		FROM period_templates
		WHERE user_id = $1 AND calendar_id = $2 AND deleted_at IS NULL
		ORDER BY period_no ASC`, userID, calendarID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Period
	for rows.Next() {
		var p Period
		var id uuid.UUID
		if err := rows.Scan(&id, &p.UserID, &p.CalendarID, &p.PeriodNo, &p.StartLocal, &p.EndLocal, &p.Revision, &p.CreatedAt, &p.UpdatedAt, &p.DeletedAt); err != nil {
			return nil, err
		}
		p.ID = id.String()
		out = append(out, p)
	}
	return out, rows.Err()
}

func (r *Repo) GetPeriod(ctx context.Context, userID, periodID string) (Period, error) {
	var p Period
	var id uuid.UUID
	if _, err := uuid.Parse(periodID); err != nil {
		return p, apperr.NotFound("period")
	}
	err := r.pool.QueryRow(ctx, `
		SELECT id, user_id, calendar_id, period_no, start_local, end_local, revision, created_at, updated_at, deleted_at
		FROM period_templates
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, periodID, userID).
		Scan(&id, &p.UserID, &p.CalendarID, &p.PeriodNo, &p.StartLocal, &p.EndLocal, &p.Revision, &p.CreatedAt, &p.UpdatedAt, &p.DeletedAt)
	if err == pgx.ErrNoRows {
		return p, apperr.NotFound("period")
	}
	p.ID = id.String()
	return p, err
}

func (r *Repo) UpdatePeriod(ctx context.Context, db sync.DBTX, p *Period, upd UpdatePeriodCmd, baseRevision int64) error {
	if upd.PeriodNo != nil {
		p.PeriodNo = *upd.PeriodNo
	}
	if upd.StartLocal != nil {
		p.StartLocal = *upd.StartLocal
	}
	if upd.EndLocal != nil {
		p.EndLocal = *upd.EndLocal
	}
	var newRev int64
	err := db.QueryRow(ctx, `
		UPDATE period_templates
		SET period_no = $3, start_local = $4, end_local = $5, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND revision = $6
		RETURNING revision, updated_at`,
		p.ID, p.UserID, p.PeriodNo, p.StartLocal, p.EndLocal, baseRevision).Scan(&newRev, &p.UpdatedAt)
	if err == pgx.ErrNoRows {
		current, gerr := r.GetPeriod(ctx, p.UserID, p.ID)
		if gerr != nil {
			return gerr
		}
		return apperr.StaleRevision(sync.EntityPeriod, current.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	p.Revision = newRev
	_, err = sync.AppendChange(ctx, db, p.UserID, sync.EntityPeriod, p.ID, sync.OpUpdate, newRev, p.Snapshot())
	return err
}

func (r *Repo) DeletePeriod(ctx context.Context, db sync.DBTX, p *Period) error {
	rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE period_templates SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, p.ID)
	if err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, p.UserID, sync.EntityPeriod, p.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(p.Snapshot(), rev, deletedAt))
	return err
}

// tombstoneRow is a tiny helper returning the new revision + deletion time.
// It returns pgx.ErrNoRows when the row is missing or already deleted —
// callers treat that as idempotent success at a higher level.
func tombstoneRow(ctx context.Context, db sync.DBTX, sql string, id string) (int64, time.Time, error) {
	var rev int64
	var deletedAt time.Time
	err := db.QueryRow(ctx, sql, id).Scan(&rev, &deletedAt)
	return rev, deletedAt, err
}

// tombstoneOverridesOfSeries soft-deletes every override pointing at a series
// (used when the series itself is tombstoned).
func tombstoneOverridesOfSeries(ctx context.Context, db sync.DBTX, userID, seriesType, seriesID string) error {
	rows, err := db.Query(ctx, `
		SELECT id FROM occurrence_overrides
		WHERE series_type = $1 AND series_id = $2 AND deleted_at IS NULL`, seriesType, seriesID)
	if err != nil {
		return err
	}
	var ids []string
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		ids = append(ids, id.String())
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, oid := range ids {
		rev, deletedAt, err := tombstoneRow(ctx, db, `UPDATE occurrence_overrides SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, oid)
		if err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, userID, sync.EntityOverride, oid, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": oid}, rev, deletedAt)); err != nil {
			return err
		}
	}
	return nil
}

// ---- update command types -------------------------------------------------

type UpdateCalendarCmd struct {
	Name       *string
	FirstDay   *string
	TotalWeeks *int
}

type UpdatePeriodCmd struct {
	PeriodNo   *int
	StartLocal *string
	EndLocal   *string
}

// RawJSON is a helper for JSONB round-trips.
func RawJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
