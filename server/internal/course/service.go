package course

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/override"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Service contains course domain rules: CRUD, meeting validation, hard
// conflict detection (course vs course) and occurrence expansion.
type Service struct {
	pool     *pgxpool.Pool
	repo     *Repo
	calRepo  *calendar.Repo
	overRepo *override.Repo
}

func NewService(pool *pgxpool.Pool, repo *Repo, calRepo *calendar.Repo, overRepo *override.Repo) *Service {
	return &Service{pool: pool, repo: repo, calRepo: calRepo, overRepo: overRepo}
}

// ---- courses ---------------------------------------------------------------

type CreateCourseCmd struct {
	CalendarID string
	Name       string
	Teacher    *string
	Location   *string
	Color      *string
	Notes      *string
	Meetings   []CreateMeetingCmd
}

func (s *Service) Create(ctx context.Context, userID string, cmd CreateCourseCmd) (Course, []Meeting, error) {
	if cmd.Name == "" || len(cmd.Name) > 100 {
		return Course{}, nil, apperr.Validation("name", "must be 1-100 characters")
	}
	cal, err := s.calRepo.GetCalendar(ctx, userID, cmd.CalendarID)
	if err != nil {
		return Course{}, nil, err
	}
	periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
	if err != nil {
		return Course{}, nil, err
	}
	if err := validateMeetings(cmd.Meetings, periods, cal.TotalWeeks); err != nil {
		return Course{}, nil, err
	}
	// New course meetings must not hard-conflict with meetings of other
	// courses already in this calendar.
	if len(cmd.Meetings) > 0 {
		existing, err := s.repoMeetingsForCalendar(ctx, userID, cal.ID)
		if err != nil {
			return Course{}, nil, err
		}
		for i := range cmd.Meetings {
			proposed := Meeting{
				Weekday: cmd.Meetings[i].Weekday, PeriodStart: cmd.Meetings[i].PeriodStart,
				PeriodEnd: cmd.Meetings[i].PeriodEnd, WeekRule: cmd.Meetings[i].WeekRule,
			}
			if clash := findHardConflict(proposed, nil, existing); clash != "" {
				return Course{}, nil, apperr.CourseConflict("course meeting overlaps an existing course meeting: " + clash)
			}
		}
	}
	c := Course{
		UserID: userID, CalendarID: cal.ID, Name: cmd.Name,
		Teacher: cmd.Teacher, Location: cmd.Location, Color: cmd.Color, Notes: cmd.Notes,
	}
	var meetings []Meeting
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		if err := s.repo.CreateCourse(ctx, tx, &c); err != nil {
			return err
		}
		for _, mc := range cmd.Meetings {
			m := Meeting{
				UserID: userID, CourseID: c.ID,
				Weekday: mc.Weekday, PeriodStart: mc.PeriodStart, PeriodEnd: mc.PeriodEnd,
				WeekRule: mc.WeekRule,
			}
			if err := s.repo.CreateMeeting(ctx, tx, &m); err != nil {
				return err
			}
			meetings = append(meetings, m)
		}
		return nil
	})
	if err != nil {
		return Course{}, nil, err
	}
	return c, meetings, nil
}

func (s *Service) List(ctx context.Context, userID, calendarID string) ([]Course, error) {
	return s.repo.ListCourses(ctx, userID, calendarID)
}

func (s *Service) Get(ctx context.Context, userID, id string) (Course, []Meeting, error) {
	c, err := s.repo.GetCourse(ctx, userID, id)
	if err != nil {
		return c, nil, err
	}
	meetings, err := s.repo.ListMeetings(ctx, userID, c.ID)
	return c, meetings, err
}

func (s *Service) Update(ctx context.Context, userID, id string, upd UpdateCourseCmd, baseRevision int64) (Course, error) {
	c, err := s.repo.GetCourse(ctx, userID, id)
	if err != nil {
		return c, err
	}
	if upd.Name != nil && (*upd.Name == "" || len(*upd.Name) > 100) {
		return c, apperr.Validation("name", "must be 1-100 characters")
	}
	if baseRevision == 0 {
		baseRevision = c.Revision
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.UpdateCourse(ctx, tx, &c, upd, baseRevision)
	})
	return c, err
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	c, err := s.repo.GetCourse(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.DeleteCourse(ctx, tx, &c)
	})
}

// ---- meetings ---------------------------------------------------------------

type CreateMeetingCmd struct {
	Weekday     int
	PeriodStart int
	PeriodEnd   int
	WeekRule    weekrule.Rule
}

// CreateMeeting adds a series to a course, rejecting hard conflicts with
// other course meetings in the same calendar (docs/domain-model.md §15).
func (s *Service) CreateMeeting(ctx context.Context, userID, courseID string, cmd CreateMeetingCmd) (Meeting, error) {
	c, err := s.repo.GetCourse(ctx, userID, courseID)
	if err != nil {
		return Meeting{}, err
	}
	cal, err := s.calRepo.GetCalendar(ctx, userID, c.CalendarID)
	if err != nil {
		return Meeting{}, err
	}
	periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
	if err != nil {
		return Meeting{}, err
	}
	if err := validateMeetings([]CreateMeetingCmd{cmd}, periods, cal.TotalWeeks); err != nil {
		return Meeting{}, err
	}
	existing, err := s.repoMeetingsForCalendar(ctx, userID, cal.ID)
	if err != nil {
		return Meeting{}, err
	}
	proposed := Meeting{Weekday: cmd.Weekday, PeriodStart: cmd.PeriodStart, PeriodEnd: cmd.PeriodEnd, WeekRule: cmd.WeekRule}
	if clash := findHardConflict(proposed, nil, existing); clash != "" {
		return Meeting{}, apperr.CourseConflict("this meeting overlaps an existing course meeting: " + clash)
	}
	m := Meeting{
		UserID: userID, CourseID: c.ID,
		Weekday: cmd.Weekday, PeriodStart: cmd.PeriodStart, PeriodEnd: cmd.PeriodEnd, WeekRule: cmd.WeekRule,
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.CreateMeeting(ctx, tx, &m)
	})
	return m, err
}

func (s *Service) ListMeetings(ctx context.Context, userID, courseID string) ([]Meeting, error) {
	if _, err := s.repo.GetCourse(ctx, userID, courseID); err != nil {
		return nil, err
	}
	return s.repo.ListMeetings(ctx, userID, courseID)
}

func (s *Service) UpdateMeeting(ctx context.Context, userID, meetingID string, upd UpdateMeetingCmd, baseRevision int64) (Meeting, error) {
	m, err := s.repo.GetMeeting(ctx, userID, meetingID)
	if err != nil {
		return m, err
	}
	c, err := s.repo.GetCourse(ctx, userID, m.CourseID)
	if err != nil {
		return m, err
	}
	cal, err := s.calRepo.GetCalendar(ctx, userID, c.CalendarID)
	if err != nil {
		return m, err
	}
	periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
	if err != nil {
		return m, err
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
	if err := validateMeetings([]CreateMeetingCmd{{
		Weekday: next.Weekday, PeriodStart: next.PeriodStart, PeriodEnd: next.PeriodEnd, WeekRule: next.WeekRule,
	}}, periods, cal.TotalWeeks); err != nil {
		return m, err
	}
	existing, err := s.repoMeetingsForCalendar(ctx, userID, cal.ID)
	if err != nil {
		return m, err
	}
	if clash := findHardConflict(next, &m.ID, existing); clash != "" {
		return m, apperr.CourseConflict("this meeting overlaps an existing course meeting: " + clash)
	}
	if baseRevision == 0 {
		baseRevision = m.Revision
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.UpdateMeeting(ctx, tx, &next, upd, baseRevision)
	})
	return next, err
}

func (s *Service) DeleteMeeting(ctx context.Context, userID, meetingID string) error {
	m, err := s.repo.GetMeeting(ctx, userID, meetingID)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.DeleteMeeting(ctx, tx, &m)
	})
}

// repoMeetingsForCalendar loads every live meeting of every live course in a
// calendar (for conflict detection).
func (s *Service) repoMeetingsForCalendar(ctx context.Context, userID, calendarID string) ([]Meeting, error) {
	courses, err := s.repo.ListCourses(ctx, userID, calendarID)
	if err != nil {
		return nil, err
	}
	var out []Meeting
	for _, c := range courses {
		ms, err := s.repo.ListMeetings(ctx, userID, c.ID)
		if err != nil {
			return nil, err
		}
		out = append(out, ms...)
	}
	return out, nil
}

// validateMeetings checks one or more proposed meetings against a calendar's
// period template and week bounds, and checks the batch internally.
func validateMeetings(cmds []CreateMeetingCmd, periods []calendar.Period, totalWeeks int) error {
	if len(cmds) == 0 {
		return nil
	}
	byNo := make(map[int]calendar.Period, len(periods))
	for _, p := range periods {
		byNo[p.PeriodNo] = p
	}
	for i, cmd := range cmds {
		if cmd.Weekday < 1 || cmd.Weekday > 7 {
			return apperr.Validation("weekday", "must be 1-7")
		}
		if cmd.PeriodStart < 1 || cmd.PeriodEnd < cmd.PeriodStart {
			return apperr.Validation("period", "periodStart must be <= periodEnd and >= 1")
		}
		if _, ok := byNo[cmd.PeriodStart]; !ok {
			return apperr.Validation("periodStart", "period is not defined in this calendar's template")
		}
		if _, ok := byNo[cmd.PeriodEnd]; !ok {
			return apperr.Validation("periodEnd", "period is not defined in this calendar's template")
		}
		if cmd.WeekRule.IsEmpty() {
			return apperr.Validation("weekRule", "at least one week segment is required")
		}
		for _, seg := range cmd.WeekRule {
			if seg.End > totalWeeks {
				return apperr.Validation("weekRule", "week range exceeds calendar total weeks")
			}
		}
		// Batch-internal conflicts.
		for j := 0; j < i; j++ {
			other := cmds[j]
			if other.Weekday != cmd.Weekday {
				continue
			}
			if periodOverlap(cmd.PeriodStart, cmd.PeriodEnd, other.PeriodStart, other.PeriodEnd) &&
				weekOverlap(cmd.WeekRule, other.WeekRule) {
				return apperr.CourseConflict("meetings in the request overlap each other")
			}
		}
	}
	return nil
}

// findHardConflict returns a description when proposed overlaps any existing
// meeting; excludeID lets update checks skip the meeting being changed.
func findHardConflict(proposed Meeting, excludeID *string, existing []Meeting) string {
	for _, ex := range existing {
		if excludeID != nil && ex.ID == *excludeID {
			continue
		}
		if ex.Weekday != proposed.Weekday {
			continue
		}
		if !periodOverlap(proposed.PeriodStart, proposed.PeriodEnd, ex.PeriodStart, ex.PeriodEnd) {
			continue
		}
		if !weekOverlap(proposed.WeekRule, ex.WeekRule) {
			continue
		}
		return ex.ID
	}
	return ""
}

// FindHardConflictOf is the exported conflict probe used by series editing
// (the proposed meeting is brand-new so nothing is excluded).
func FindHardConflictOf(proposed Meeting, existing []Meeting) string {
	return findHardConflict(proposed, nil, existing)
}

func periodOverlap(a1, a2, b1, b2 int) bool {
	return a1 <= b2 && b1 <= a2
}

func weekOverlap(a, b weekrule.Rule) bool {
	// Cheap bound check on segment intervals before week-set comparison.
	for _, sa := range a {
		for _, sb := range b {
			if sa.Start <= sb.End && sb.Start <= sa.End {
				// Potential overlap: compare concrete weeks (max 60).
				for _, wa := range a.Weeks(60) {
					for _, wb := range b.Weeks(60) {
						if wa == wb {
							return true
						}
					}
				}
				return false
			}
		}
	}
	return false
}

// ---- occurrence expansion ----------------------------------------------------

// Occurrence is one materialized instance of a course meeting, after
// overrides have been applied.
type Occurrence struct {
	MeetingID  string
	CourseID   string
	DateLocal  string
	Week       int
	Start, End time.Time // UTC
	Cancelled  bool
	// Display metadata after overrides.
	Title, Teacher, Location, Color *string
	PeriodStart, PeriodEnd          int
	Overridden                      bool
}

// PeriodTimes maps period numbers of a calendar to local minute-of-day.
type PeriodTimes map[int][2]int

// PeriodTimes builds start/end minutes for each period of the calendar.
func BuildPeriodTimes(periods []calendar.Period) (PeriodTimes, error) {
	out := PeriodTimes{}
	for _, p := range periods {
		sm, err := timeutil.HHMMToMinutes(p.StartLocal)
		if err != nil {
			return nil, err
		}
		em, err := timeutil.HHMMToMinutes(p.EndLocal)
		if err != nil {
			return nil, err
		}
		out[p.PeriodNo] = [2]int{sm, em}
	}
	return out, nil
}

// ExpandMeetings materializes every occurrence of the given meetings in
// [start,end] UTC, applying overrides (move/update/cancel) per date.
func (s *Service) ExpandMeetings(ctx context.Context, userID string, meetings []Meeting, coursesByID map[string]Course, cal calendar.Calendar, periodTimes PeriodTimes, start, end time.Time, loc *time.Location) ([]Occurrence, error) {
	overridesBySeries, err := s.overRepo.OfSeriesSet(ctx, userID, override.SeriesCourseMeeting, meetingIDs(meetings))
	if err != nil {
		return nil, err
	}
	var out []Occurrence
	for _, m := range meetings {
		c := coursesByID[m.CourseID]
		overByDate := make(map[string]override.Override)
		for _, o := range overridesBySeries[m.ID] {
			overByDate[o.OccurrenceDateLocal] = o
		}
		for _, week := range m.WeekRule.Weeks(cal.TotalWeeks) {
			date := calendar.LocalDateOfOccurrence(cal, week, m.Weekday)
			if date == "" {
				continue
			}
			startMinutes, ok := periodTimes[m.PeriodStart]
			if !ok {
				continue
			}
			endMinutes, ok := periodTimes[m.PeriodEnd]
			if !ok {
				continue
			}
			occStart, err := timeutil.LocalizeMinute(date, startMinutes[0], loc)
			if err != nil {
				continue
			}
			occEnd, err := timeutil.LocalizeMinute(date, endMinutes[1], loc)
			if err != nil {
				continue
			}
			occ := Occurrence{
				MeetingID: m.ID, CourseID: m.CourseID, DateLocal: date, Week: week,
				Start: occStart, End: occEnd,
				PeriodStart: m.PeriodStart, PeriodEnd: m.PeriodEnd,
				Title: strPtr(c.Name), Teacher: c.Teacher, Location: c.Location, Color: c.Color,
			}
			if ov, ok := overByDate[date]; ok {
				occ.Overridden = true
				switch ov.Action {
				case override.ActionCancel:
					occ.Cancelled = true
				case override.ActionMove:
					if ov.ReplacementStartAt != nil && ov.ReplacementEndAt != nil {
						occ.Start = *ov.ReplacementStartAt
						occ.End = *ov.ReplacementEndAt
					}
				}
				if ov.Metadata != nil {
					applyOverridePatch(&occ, ov.Metadata)
				}
			}
			if occ.Cancelled {
				continue
			}
			if occ.End.Before(start) || occ.Start.After(end) || !occ.End.After(occ.Start) {
				continue
			}
			out = append(out, occ)
		}
	}
	return out, nil
}

func applyOverridePatch(occ *Occurrence, meta map[string]any) {
	if v, ok := meta["title"].(string); ok {
		occ.Title = strPtr(v)
	}
	if v, ok := meta["teacher"].(string); ok {
		occ.Teacher = strPtr(v)
	}
	if v, ok := meta["location"].(string); ok {
		occ.Location = strPtr(v)
	}
	if v, ok := meta["color"].(string); ok {
		occ.Color = strPtr(v)
	}
}

func meetingIDs(meetings []Meeting) []string {
	ids := make([]string, 0, len(meetings))
	for _, m := range meetings {
		ids = append(ids, m.ID)
	}
	return ids
}

func strPtr(s string) *string { return &s }
