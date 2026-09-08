package course

import (
	"context"
	"encoding/json"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// CourseAdapter plugs courses into the sync push engine.
type CourseAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewCourseAdapter(pool *pgxpool.Pool, repo *Repo) *CourseAdapter {
	return &CourseAdapter{repo: repo, pool: pool}
}

func loadCourseAny(repo *Repo, ctx context.Context, userID, id string) (Course, sync.EntityState, error) {
	if _, err := parseUUID(id); err != nil {
		return Course{}, sync.StateMissing, apperr.NotFound("course")
	}
	c, err := scanCourse(repo.pool.QueryRow(ctx, `SELECT `+courseColumns+` FROM courses WHERE id=$1 AND user_id=$2`, id, userID))
	if err != nil {
		return c, sync.StateMissing, nil
	}
	if c.DeletedAt != nil {
		return c, sync.StateDeleted, nil
	}
	return c, sync.StateLive, nil
}

func (a *CourseAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	c, state, err := loadCourseAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return c.Snapshot(), c.Revision, state, nil
}

func (a *CourseAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	name, err := mapString(fields, "name")
	if err != nil {
		return err
	}
	calendarID, err := mapString(fields, "calendarId")
	if err != nil {
		return err
	}
	if len(name) > 100 {
		return apperr.Validation("name", "must be 1-100 characters")
	}
	if _, err := loadCalendarAnyPool(ctx, a.pool, userID, calendarID); err != nil {
		return apperr.Validation("calendarId", "calendar does not exist")
	}
	c := Course{ID: entityID, UserID: userID, CalendarID: calendarID, Name: name,
		Teacher: mapStringPtr(fields, "teacher"), Location: mapStringPtr(fields, "location"),
		Color: mapStringPtr(fields, "color"), Notes: mapStringPtr(fields, "notes")}
	return a.repo.CreateCourse(ctx, tx, &c)
}

func (a *CourseAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd := UpdateCourseCmd{}
	if has, v := mapStringOpt(fields, "name"); has {
		upd.Name = v
	}
	if has, v := mapStringOpt(fields, "teacher"); has {
		upd.Teacher = v
	}
	if has, v := mapStringOpt(fields, "location"); has {
		upd.Location = v
	}
	if has, v := mapStringOpt(fields, "color"); has {
		upd.Color = v
	}
	if has, v := mapStringOpt(fields, "notes"); has {
		upd.Notes = v
	}
	if upd.Name != nil && (*upd.Name == "" || len(*upd.Name) > 100) {
		return 0, apperr.Validation("name", "must be 1-100 characters")
	}
	c, state, err := loadCourseAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	if err := a.repo.UpdateCourse(ctx, tx, &c, upd, baseRevision); err != nil {
		return 0, err
	}
	return c.Revision, nil
}

func (a *CourseAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	c, state, err := loadCourseAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	return a.repo.DeleteCourse(ctx, tx, &c)
}

// MeetingAdapter plugs course meetings into the sync push engine.
type MeetingAdapter struct {
	repo *Repo
	pool *pgxpool.Pool
}

func NewMeetingAdapter(pool *pgxpool.Pool, repo *Repo) *MeetingAdapter {
	return &MeetingAdapter{repo: repo, pool: pool}
}

func loadMeetingAny(repo *Repo, ctx context.Context, userID, id string) (Meeting, sync.EntityState, error) {
	if _, err := parseUUID(id); err != nil {
		return Meeting{}, sync.StateMissing, apperr.NotFound("course meeting")
	}
	m, err := scanMeeting(repo.pool.QueryRow(ctx, `SELECT id, user_id, course_id, weekday, period_start, period_end, week_rule, revision, created_at, updated_at, deleted_at
		FROM course_meetings WHERE id=$1 AND user_id=$2`, id, userID))
	if err != nil {
		return m, sync.StateMissing, nil
	}
	if m.DeletedAt != nil {
		return m, sync.StateDeleted, nil
	}
	return m, sync.StateLive, nil
}

func (a *MeetingAdapter) Load(ctx context.Context, userID, entityID string) (map[string]any, int64, sync.EntityState, error) {
	m, state, err := loadMeetingAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return nil, 0, state, err
	}
	return m.Snapshot(), m.Revision, state, nil
}

func (a *MeetingAdapter) Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error {
	courseID, err := mapString(fields, "courseId")
	if err != nil {
		return err
	}
	if _, state, err := loadCourseAny(a.repo, ctx, userID, courseID); err != nil || state != sync.StateLive {
		return apperr.Validation("courseId", "course does not exist")
	}
	m := Meeting{ID: entityID, UserID: userID, CourseID: courseID}
	m.Weekday, err = mapInt(fields, "weekday")
	if err != nil {
		return err
	}
	m.PeriodStart, err = mapInt(fields, "periodStart")
	if err != nil {
		return err
	}
	m.PeriodEnd, err = mapInt(fields, "periodEnd")
	if err != nil {
		return err
	}
	m.WeekRule, err = mapWeekRule(fields)
	if err != nil {
		return err
	}
	if m.Weekday < 1 || m.Weekday > 7 {
		return apperr.Validation("weekday", "must be 1-7")
	}
	if m.PeriodStart < 1 || m.PeriodEnd < m.PeriodStart {
		return apperr.Validation("period", "periodStart must be <= periodEnd and >= 1")
	}
	if m.WeekRule.IsEmpty() {
		return apperr.Validation("weekRule", "at least one week segment is required")
	}
	return a.repo.CreateMeeting(ctx, tx, &m)
}

func (a *MeetingAdapter) ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (int64, error) {
	upd := UpdateMeetingCmd{}
	if v, err := mapIntOpt(fields, "weekday"); err != nil {
		return 0, err
	} else if v != nil {
		upd.Weekday = v
	}
	if v, err := mapIntOpt(fields, "periodStart"); err != nil {
		return 0, err
	} else if v != nil {
		upd.PeriodStart = v
	}
	if v, err := mapIntOpt(fields, "periodEnd"); err != nil {
		return 0, err
	} else if v != nil {
		upd.PeriodEnd = v
	}
	if raw, ok := fields["weekRule"]; ok {
		jsonBytes, err := json.Marshal(raw)
		if err != nil {
			return 0, apperr.Validation("weekRule", "invalid week rule")
		}
		rule, err := weekrule.ParseSegments(jsonBytes)
		if err != nil {
			return 0, err
		}
		upd.WeekRule = rule
	}
	m, state, err := loadMeetingAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return 0, err
	}
	if state != sync.StateLive {
		return 0, apperr.New(409, apperr.CodeSyncConflict, "entity is deleted")
	}
	next := m
	if upd.Weekday != nil {
		next.Weekday = *upd.Weekday
	}
	if upd.PeriodStart != nil {
		next.PeriodStart = *upd.PeriodStart
	}
	if upd.PeriodEnd != nil {
		next.PeriodEnd = *upd.PeriodEnd
	}
	if upd.WeekRule != nil {
		next.WeekRule = upd.WeekRule
	}
	if next.Weekday < 1 || next.Weekday > 7 {
		return 0, apperr.Validation("weekday", "must be 1-7")
	}
	if next.PeriodStart < 1 || next.PeriodEnd < next.PeriodStart {
		return 0, apperr.Validation("period", "periodStart must be <= periodEnd and >= 1")
	}
	if next.WeekRule.IsEmpty() {
		return 0, apperr.Validation("weekRule", "at least one week segment is required")
	}
	if err := a.repo.UpdateMeeting(ctx, tx, &next, upd, baseRevision); err != nil {
		return 0, err
	}
	return next.Revision, nil
}

func (a *MeetingAdapter) Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error {
	m, state, err := loadMeetingAny(a.repo, ctx, userID, entityID)
	if err != nil {
		return err
	}
	if state != sync.StateLive {
		return nil
	}
	return a.repo.DeleteMeeting(ctx, tx, &m)
}

// ---- shared map helpers ---------------------------------------------------------

func mapString(f map[string]any, key string) (string, error) {
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

func mapStringPtr(f map[string]any, key string) *string {
	if v, ok := f[key]; ok && v != nil {
		if s, ok := v.(string); ok {
			return &s
		}
	}
	return nil
}

func mapStringOpt(f map[string]any, key string) (bool, *string) {
	if v, ok := f[key]; ok {
		if v == nil {
			return true, nil
		}
		if s, ok := v.(string); ok {
			return true, &s
		}
		return true, nil
	}
	return false, nil
}

func mapInt(f map[string]any, key string) (int, error) {
	v, ok := f[key]
	if !ok || v == nil {
		return 0, apperr.Validation(key, "is required")
	}
	if n, ok := v.(float64); ok {
		return int(n), nil
	}
	return 0, apperr.Validation(key, "must be an integer")
}

func mapIntOpt(f map[string]any, key string) (*int, error) {
	v, ok := f[key]
	if !ok || v == nil {
		return nil, nil
	}
	if n, ok := v.(float64); ok {
		i := int(n)
		return &i, nil
	}
	return nil, apperr.Validation(key, "must be an integer")
}

func mapWeekRule(f map[string]any) (weekrule.Rule, error) {
	v, ok := f["weekRule"]
	if !ok || v == nil {
		return nil, apperr.Validation("weekRule", "is required")
	}
	jsonBytes, err := json.Marshal(v)
	if err != nil {
		return nil, apperr.Validation("weekRule", "invalid week rule")
	}
	return weekrule.ParseSegments(jsonBytes)
}

func loadCalendarAnyPool(ctx context.Context, pool *pgxpool.Pool, userID, calendarID string) (bool, error) {
	var exists bool
	err := pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM academic_calendars WHERE id=$1 AND user_id=$2 AND deleted_at IS NULL)`, calendarID, userID).Scan(&exists)
	return exists, err
}

func parseUUID(s string) (uuidValue, error) {
	return uuidParse(s)
}
