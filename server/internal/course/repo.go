// Package course owns courses and their recurring meetings
// (docs/domain-model.md §4-5): a Course is the subject, a CourseMeeting is a
// weekly series (weekday + periods + academic week rule) inside a semester.
package course

import (
	"context"
	"encoding/json"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type Course struct {
	ID         string
	UserID     string
	CalendarID string
	Name       string
	Teacher    *string
	Location   *string
	Color      *string
	Notes      *string
	Revision   int64
	CreatedAt  time.Time
	UpdatedAt  time.Time
	DeletedAt  *time.Time
}

func (c Course) Snapshot() map[string]any {
	s := map[string]any{
		"id":         c.ID,
		"calendarId": c.CalendarID,
		"name":       c.Name,
		"teacher":    c.Teacher,
		"location":   c.Location,
		"color":      c.Color,
		"notes":      c.Notes,
		"revision":   c.Revision,
		"createdAt":  c.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":  c.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if c.DeletedAt != nil {
		s["deletedAt"] = c.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

type Meeting struct {
	ID          string
	UserID      string
	CourseID    string
	Weekday     int // 1=Monday..7=Sunday
	PeriodStart int
	PeriodEnd   int
	WeekRule    weekrule.Rule
	Revision    int64
	CreatedAt   time.Time
	UpdatedAt   time.Time
	DeletedAt   *time.Time
}

func (m Meeting) Snapshot() map[string]any {
	s := map[string]any{
		"id":          m.ID,
		"courseId":    m.CourseID,
		"weekday":     m.Weekday,
		"periodStart": m.PeriodStart,
		"periodEnd":   m.PeriodEnd,
		"weekRule":    m.WeekRule,
		"revision":    m.Revision,
		"createdAt":   m.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt":   m.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if m.DeletedAt != nil {
		s["deletedAt"] = m.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (m Meeting) DTO() map[string]any { return m.Snapshot() }

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// ---- courses ---------------------------------------------------------------

func (r *Repo) CreateCourse(ctx context.Context, db sync.DBTX, c *Course) error {
	if c.ID == "" {
		c.ID = uuid.NewString()
	}
	now := time.Now().UTC()
	c.CreatedAt, c.UpdatedAt, c.Revision = now, now, 1
	if _, err := db.Exec(ctx, `
		INSERT INTO courses (id, user_id, calendar_id, name, teacher, location, color, notes, created_at, updated_at, revision)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $9, 1)`,
		c.ID, c.UserID, c.CalendarID, c.Name, c.Teacher, c.Location, c.Color, c.Notes, now); err != nil {
		return err
	}
	_, err := sync.AppendChange(ctx, db, c.UserID, sync.EntityCourse, c.ID, sync.OpCreate, 1, c.Snapshot())
	return err
}

func scanCourse(scanner interface {
	Scan(dest ...any) error
}) (Course, error) {
	var c Course
	var id uuid.UUID
	if err := scanner.Scan(&id, &c.UserID, &c.CalendarID, &c.Name, &c.Teacher, &c.Location, &c.Color, &c.Notes,
		&c.Revision, &c.CreatedAt, &c.UpdatedAt, &c.DeletedAt); err != nil {
		return c, err
	}
	c.ID = id.String()
	return c, nil
}

const courseColumns = `id, user_id, calendar_id, name, teacher, location, color, notes, revision, created_at, updated_at, deleted_at`

func (r *Repo) ListCourses(ctx context.Context, userID string, calendarID string) ([]Course, error) {
	query := `SELECT ` + courseColumns + ` FROM courses WHERE user_id = $1 AND deleted_at IS NULL`
	args := []any{userID}
	if calendarID != "" {
		query += ` AND calendar_id = $2 ORDER BY name`
		args = append(args, calendarID)
	} else {
		query += ` ORDER BY created_at`
	}
	rows, err := r.pool.Query(ctx, query, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Course
	for rows.Next() {
		c, err := scanCourse(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (r *Repo) GetCourse(ctx context.Context, userID, courseID string) (Course, error) {
	if _, err := uuid.Parse(courseID); err != nil {
		return Course{}, apperr.NotFound("course")
	}
	c, err := scanCourse(r.pool.QueryRow(ctx,
		`SELECT `+courseColumns+` FROM courses WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, courseID, userID))
	if err == pgx.ErrNoRows {
		return c, apperr.NotFound("course")
	}
	return c, err
}

func (r *Repo) UpdateCourse(ctx context.Context, db sync.DBTX, c *Course, upd UpdateCourseCmd, baseRevision int64) error {
	if upd.Name != nil {
		c.Name = *upd.Name
	}
	if upd.Teacher != nil {
		c.Teacher = upd.Teacher
	}
	if upd.Location != nil {
		c.Location = upd.Location
	}
	if upd.Color != nil {
		c.Color = upd.Color
	}
	if upd.Notes != nil {
		c.Notes = upd.Notes
	}
	var newRev int64
	err := db.QueryRow(ctx, `
		UPDATE courses
		SET name = $3, teacher = $4, location = $5, color = $6, notes = $7, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND revision = $8
		RETURNING revision, updated_at`,
		c.ID, c.UserID, c.Name, c.Teacher, c.Location, c.Color, c.Notes, baseRevision).Scan(&newRev, &c.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.StaleRevision(sync.EntityCourse, c.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	c.Revision = newRev
	_, err = sync.AppendChange(ctx, db, c.UserID, sync.EntityCourse, c.ID, sync.OpUpdate, newRev, c.Snapshot())
	return err
}

func (r *Repo) DeleteCourse(ctx context.Context, db sync.DBTX, c *Course) error {
	// Tombstone meetings first (each journaled), then their overrides,
	// then the course itself.
	meetings, err := r.ListMeetings(ctx, c.UserID, c.ID)
	if err != nil {
		return err
	}
	for _, m := range meetings {
		if err := r.DeleteMeeting(ctx, db, &m); err != nil {
			return err
		}
	}
	rev, deletedAt, err := tombstone(ctx, db, `UPDATE courses SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, c.ID)
	if err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, c.UserID, sync.EntityCourse, c.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(c.Snapshot(), rev, deletedAt))
	return err
}

// ---- meetings ----------------------------------------------------------------

func (r *Repo) CreateMeeting(ctx context.Context, db sync.DBTX, m *Meeting) error {
	if m.ID == "" {
		m.ID = uuid.NewString()
	}
	now := time.Now().UTC()
	m.CreatedAt, m.UpdatedAt, m.Revision = now, now, 1
	ruleJSON, err := json.Marshal(m.WeekRule)
	if err != nil {
		return err
	}
	if _, err := db.Exec(ctx, `
		INSERT INTO course_meetings (id, user_id, course_id, weekday, period_start, period_end, week_rule, created_at, updated_at, revision)
		VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $8, 1)`,
		m.ID, m.UserID, m.CourseID, m.Weekday, m.PeriodStart, m.PeriodEnd, ruleJSON, now); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, m.UserID, sync.EntityMeeting, m.ID, sync.OpCreate, 1, m.Snapshot())
	return err
}

func (r *Repo) ListMeetings(ctx context.Context, userID, courseID string) ([]Meeting, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, user_id, course_id, weekday, period_start, period_end, week_rule, revision, created_at, updated_at, deleted_at
		FROM course_meetings
		WHERE user_id = $1 AND course_id = $2 AND deleted_at IS NULL
		ORDER BY weekday, period_start`, userID, courseID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Meeting
	for rows.Next() {
		m, err := scanMeeting(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, rows.Err()
}

func scanMeeting(scanner interface {
	Scan(dest ...any) error
}) (Meeting, error) {
	var m Meeting
	var id uuid.UUID
	var ruleJSON []byte
	if err := scanner.Scan(&id, &m.UserID, &m.CourseID, &m.Weekday, &m.PeriodStart, &m.PeriodEnd, &ruleJSON,
		&m.Revision, &m.CreatedAt, &m.UpdatedAt, &m.DeletedAt); err != nil {
		return m, err
	}
	m.ID = id.String()
	rule, err := weekrule.ParseSegments(ruleJSON)
	if err != nil {
		return m, err
	}
	m.WeekRule = rule
	return m, nil
}

func (r *Repo) GetMeeting(ctx context.Context, userID, meetingID string) (Meeting, error) {
	if _, err := uuid.Parse(meetingID); err != nil {
		return Meeting{}, apperr.NotFound("course meeting")
	}
	m, err := scanMeeting(r.pool.QueryRow(ctx, `
		SELECT id, user_id, course_id, weekday, period_start, period_end, week_rule, revision, created_at, updated_at, deleted_at
		FROM course_meetings
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, meetingID, userID))
	if err == pgx.ErrNoRows {
		return m, apperr.NotFound("course meeting")
	}
	return m, err
}

func (r *Repo) UpdateMeeting(ctx context.Context, db sync.DBTX, m *Meeting, upd UpdateMeetingCmd, baseRevision int64) error {
	if upd.Weekday != nil {
		m.Weekday = *upd.Weekday
	}
	if upd.PeriodStart != nil {
		m.PeriodStart = *upd.PeriodStart
	}
	if upd.PeriodEnd != nil {
		m.PeriodEnd = *upd.PeriodEnd
	}
	if upd.WeekRule != nil {
		m.WeekRule = upd.WeekRule
	}
	ruleJSON, err := json.Marshal(m.WeekRule)
	if err != nil {
		return err
	}
	var newRev int64
	err = db.QueryRow(ctx, `
		UPDATE course_meetings
		SET weekday = $3, period_start = $4, period_end = $5, week_rule = $6, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND revision = $7
		RETURNING revision, updated_at`,
		m.ID, m.UserID, m.Weekday, m.PeriodStart, m.PeriodEnd, ruleJSON, baseRevision).Scan(&newRev, &m.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.StaleRevision(sync.EntityMeeting, m.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	m.Revision = newRev
	_, err = sync.AppendChange(ctx, db, m.UserID, sync.EntityMeeting, m.ID, sync.OpUpdate, newRev, m.Snapshot())
	return err
}

// DeleteMeeting tombstones the meeting and its overrides.
func (r *Repo) DeleteMeeting(ctx context.Context, db sync.DBTX, m *Meeting) error {
	rows, err := db.Query(ctx, `
		SELECT id FROM occurrence_overrides
		WHERE series_type = $1 AND series_id = $2 AND deleted_at IS NULL`,
		sync.EntityMeeting, m.ID)
	if err != nil {
		return err
	}
	var overrideIDs []string
	for rows.Next() {
		var id uuid.UUID
		if err := rows.Scan(&id); err != nil {
			rows.Close()
			return err
		}
		overrideIDs = append(overrideIDs, id.String())
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	for _, oid := range overrideIDs {
		rev, deletedAt, err := tombstone(ctx, db, `UPDATE occurrence_overrides SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, oid)
		if err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, m.UserID, sync.EntityOverride, oid, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": oid}, rev, deletedAt)); err != nil {
			return err
		}
	}
	rev, deletedAt, err := tombstone(ctx, db, `UPDATE course_meetings SET deleted_at = now(), revision = revision + 1, updated_at = now() WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, m.ID)
	if err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, m.UserID, sync.EntityMeeting, m.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(m.Snapshot(), rev, deletedAt))
	return err
}

func tombstone(ctx context.Context, db sync.DBTX, sql string, id string) (int64, time.Time, error) {
	var rev int64
	var deletedAt time.Time
	err := db.QueryRow(ctx, sql, id).Scan(&rev, &deletedAt)
	return rev, deletedAt, err
}

// ---- update commands -----------------------------------------------------------

type UpdateCourseCmd struct {
	Name     *string
	Teacher  *string
	Location *string
	Color    *string
	Notes    *string
}

type UpdateMeetingCmd struct {
	Weekday     *int
	PeriodStart *int
	PeriodEnd   *int
	WeekRule    weekrule.Rule
}
