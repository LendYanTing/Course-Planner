// Package series implements occurrence-scoped edits on recurring series
// (docs/domain-model.md §13, docs/api.md §10):
//
//	THIS              -> create/update an OccurrenceOverride for the date
//	THIS_AND_FUTURE   -> split the series at the occurrence (old history is
//	                     never mutated; a new series takes over from the
//	                     occurrence onward), then apply changes to the tail
//	ALL               -> edit or delete the whole series definition
//
// Series types: course_meeting and recurring_schedule.
package series

import (
	"context"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/override"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Scopes.
const (
	ScopeThis          = "THIS"
	ScopeThisAndFuture = "THIS_AND_FUTURE"
	ScopeAll           = "ALL"
)

// Operation types.
const (
	OpMove   = "MOVE"
	OpUpdate = "UPDATE"
	OpCancel = "CANCEL"
	OpDelete = "DELETE"
)

type Request struct {
	SeriesType          string
	SeriesID            string
	Scope               string
	OccurrenceDateLocal string
	Operation           Operation
}

type Operation struct {
	Type        string
	StartAt     *time.Time // THIS + MOVE replacement window (UTC)
	EndAt       *time.Time
	StartLocal  *string // series-level time patch (split/ALL)
	EndLocal    *string
	PeriodStart *int // course-like period patch
	PeriodEnd   *int
	Weekday     *int // course_meeting weekday patch (split/ALL)
	WeekRule    weekrule.Rule
	HasWeekRule bool
	Patch       map[string]any // metadata patch (title/teacher/location/color/notes)
	Force       bool
}

type Result struct {
	Kind        string // "override" | "split" | "series_update" | "series_delete"
	Override    *override.Override
	OldSeriesID string
	NewSeriesID string
	Details     map[string]any
}

type Service struct {
	pool       *pgxpool.Pool
	calRepo    *calendar.Repo
	courseRepo *course.Repo
	courseSvc  *course.Service
	schedRepo  *schedule.Repo
	schedSvc   *schedule.Service
	overRepo   *override.Repo
	eventSvc   *event.Service
}

func NewService(pool *pgxpool.Pool, calRepo *calendar.Repo, courseRepo *course.Repo, courseSvc *course.Service, schedRepo *schedule.Repo, schedSvc *schedule.Service, overRepo *override.Repo, eventSvc *event.Service) *Service {
	return &Service{pool: pool, calRepo: calRepo, courseRepo: courseRepo, courseSvc: courseSvc,
		schedRepo: schedRepo, schedSvc: schedSvc, overRepo: overRepo, eventSvc: eventSvc}
}

// Apply validates and executes one series operation atomically.
func (s *Service) Apply(ctx context.Context, userID string, req Request, loc *time.Location) (Result, error) {
	switch req.Scope {
	case ScopeThis, ScopeThisAndFuture:
		if err := timeutil.ValidateDate(req.OccurrenceDateLocal); err != nil {
			return Result{}, err
		}
	case ScopeAll:
		// ALL edits the whole series; no occurrence date is involved.
	default:
		return Result{}, apperr.Validation("scope", "must be THIS, THIS_AND_FUTURE or ALL")
	}
	if req.SeriesType != override.SeriesCourseMeeting && req.SeriesType != override.SeriesRecurring {
		return Result{}, apperr.Validation("seriesType", "must be course_meeting or recurring_schedule")
	}
	switch req.Operation.Type {
	case OpMove, OpUpdate, OpCancel, OpDelete:
	default:
		return Result{}, apperr.Validation("operation.type", "must be MOVE, UPDATE, CANCEL or DELETE")
	}

	if req.SeriesType == override.SeriesCourseMeeting {
		return s.applyCourseMeeting(ctx, userID, req, loc)
	}
	return s.applyRecurring(ctx, userID, req, loc)
}

// ---- course meetings --------------------------------------------------------

func (s *Service) applyCourseMeeting(ctx context.Context, userID string, req Request, loc *time.Location) (Result, error) {
	m, err := s.courseRepo.GetMeeting(ctx, userID, req.SeriesID)
	if err != nil {
		return Result{}, err
	}
	c, err := s.courseRepo.GetCourse(ctx, userID, m.CourseID)
	if err != nil {
		return Result{}, err
	}
	cal, err := s.calRepo.GetCalendar(ctx, userID, c.CalendarID)
	if err != nil {
		return Result{}, err
	}
	week := 0
	if req.Scope != ScopeAll {
		week, err = weekOfDate(cal, req.OccurrenceDateLocal)
		if err != nil {
			return Result{}, err
		}
		if week > cal.TotalWeeks {
			return Result{}, apperr.Validation("occurrenceDateLocal", "date is outside the calendar range")
		}
		// The occurrence must actually belong to this series on that date.
		if wd, _ := timeutil.WeekdayOf(req.OccurrenceDateLocal); wd != m.Weekday || !m.WeekRule.MatchesWeek(week) {
			return Result{}, apperr.Validation("occurrenceDateLocal", "no occurrence of this series on that date")
		}
	}

	switch req.Scope {
	case ScopeThis:
		return s.courseThis(ctx, userID, m, c, cal, req, loc)
	case ScopeThisAndFuture:
		return s.courseSplit(ctx, userID, m, c, cal, week, req)
	default: // ALL
		return s.courseAll(ctx, userID, m, cal, req)
	}
}

func (s *Service) courseThis(ctx context.Context, userID string, m course.Meeting, c course.Course, cal calendar.Calendar, req Request, loc *time.Location) (Result, error) {
	switch req.Operation.Type {
	case OpMove:
		if req.Operation.StartAt == nil || req.Operation.EndAt == nil {
			return Result{}, apperr.Validation("operation.startAt", "MOVE requires startAt and endAt")
		}
		if err := timeutil.CheckSameLocalDay(*req.Operation.StartAt, *req.Operation.EndAt, loc, "moved occurrence"); err != nil {
			return Result{}, err
		}
		// Hard conflict against other course occurrences that day (force overrides).
		if !req.Operation.Force {
			conflict, err := s.courseConflictAt(ctx, userID, *req.Operation.StartAt, *req.Operation.EndAt, loc, m.ID)
			if err != nil {
				return Result{}, err
			}
			if conflict {
				return Result{}, apperr.CourseConflict("the moved occurrence overlaps another course; pass force=true to override")
			}
		}
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesCourseMeeting, SeriesID: m.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionMove,
			ReplacementStartAt:  req.Operation.StartAt, ReplacementEndAt: req.Operation.EndAt,
			Metadata: patchMetadata(req.Operation.Patch),
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil

	case OpUpdate:
		if len(req.Operation.Patch) == 0 {
			return Result{}, apperr.Validation("operation.patch", "UPDATE requires a patch")
		}
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesCourseMeeting, SeriesID: m.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionUpdate,
			Metadata:            patchMetadata(req.Operation.Patch),
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil

	default: // CANCEL / DELETE -> cancel override
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesCourseMeeting, SeriesID: m.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionCancel,
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil
	}
}

// courseConflictAt reports whether [start,end) overlaps any course occurrence
// other than those of excludeMeetingID.
func (s *Service) courseConflictAt(ctx context.Context, userID string, start, end time.Time, loc *time.Location, excludeMeetingID string) (bool, error) {
	dayStart := start.Add(-24 * time.Hour)
	dayEnd := end.Add(24 * time.Hour)
	occs, err := s.eventSvc.CourseOccurrences(ctx, userID, dayStart, dayEnd, nil2UTC(loc))
	if err != nil {
		return false, err
	}
	for _, o := range occs {
		if o.MeetingID == excludeMeetingID {
			continue
		}
		if timeutil.Overlap(start, end, o.Start, o.End) {
			return true, nil
		}
	}
	return false, nil
}

func nil2UTC(loc *time.Location) *time.Location {
	if loc == nil {
		return time.UTC
	}
	return loc
}

func (s *Service) courseSplit(ctx context.Context, userID string, m course.Meeting, c course.Course, cal calendar.Calendar, week int, req Request) (Result, error) {
	switch req.Operation.Type {
	case OpMove, OpUpdate:
		oldRule := m.WeekRule.RestrictBefore(week)
		tailRule := m.WeekRule.RestrictFrom(week)
		if req.Operation.HasWeekRule {
			// Replace the tail's week rule entirely.
			tailRule = req.Operation.WeekRule.RestrictFrom(1)
			if req.Operation.WeekRule.IsEmpty() {
				tailRule = nil
			}
		}

		var newMeeting *course.Meeting
		if len(tailRule) > 0 {
			clone := m
			clone.ID = "" // new identity
			clone.WeekRule = tailRule
			if req.Operation.Weekday != nil {
				clone.Weekday = *req.Operation.Weekday
			}
			if req.Operation.PeriodStart != nil {
				clone.PeriodStart = *req.Operation.PeriodStart
			}
			if req.Operation.PeriodEnd != nil {
				clone.PeriodEnd = *req.Operation.PeriodEnd
			}
			if clone.PeriodEnd < clone.PeriodStart {
				return Result{}, apperr.Validation("operation.periodEnd", "must be >= periodStart")
			}
			periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
			if err != nil {
				return Result{}, err
			}
			found := func(no int) bool {
				for _, p := range periods {
					if p.PeriodNo == no {
						return true
					}
				}
				return false
			}
			if !found(clone.PeriodStart) || !found(clone.PeriodEnd) {
				return Result{}, apperr.Validation("operation.periods", "period is not defined in the calendar template")
			}
			if !req.Operation.Force {
				existing, err := s.allMeetingsExcept(ctx, userID, cal.ID, m.ID)
				if err != nil {
					return Result{}, err
				}
				if clash := course.FindHardConflictOf(clone, existing); clash != "" {
					return Result{}, apperr.CourseConflict("the tail series overlaps an existing course meeting: " + clash)
				}
			}
			newMeeting = &clone
		}

		err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			// 1. Truncate the old series (or delete it when nothing remains).
			if len(oldRule) == 0 {
				if err := s.courseRepo.DeleteMeeting(ctx, tx, &m); err != nil {
					return err
				}
			} else {
				m.WeekRule = oldRule
				upd := course.UpdateMeetingCmd{WeekRule: oldRule}
				if err := s.courseRepo.UpdateMeeting(ctx, tx, &m, upd, m.Revision); err != nil {
					return err
				}
			}
			// 2. Create the tail series.
			if newMeeting != nil {
				if err := s.courseRepo.CreateMeeting(ctx, tx, newMeeting); err != nil {
					return err
				}
				// 3. Move future overrides to the tail.
				return s.moveOverrides(ctx, tx, userID, override.SeriesCourseMeeting, m.ID, newMeeting.ID, req.OccurrenceDateLocal)
			}
			// No tail: future overrides die with the truncated series.
			return s.tombstoneOverridesFrom(ctx, tx, userID, override.SeriesCourseMeeting, m.ID, req.OccurrenceDateLocal)
		})
		if err != nil {
			return Result{}, err
		}
		res := Result{Kind: "split", OldSeriesID: m.ID}
		if newMeeting != nil {
			res.NewSeriesID = newMeeting.ID
		}
		return res, nil

	default: // CANCEL / DELETE: truncate, no tail.
		oldRule := m.WeekRule.RestrictBefore(week)
		err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			if len(oldRule) == 0 {
				if err := s.courseRepo.DeleteMeeting(ctx, tx, &m); err != nil {
					return err
				}
			} else {
				m.WeekRule = oldRule
				upd := course.UpdateMeetingCmd{WeekRule: oldRule}
				if err := s.courseRepo.UpdateMeeting(ctx, tx, &m, upd, m.Revision); err != nil {
					return err
				}
			}
			return s.tombstoneOverridesFrom(ctx, tx, userID, override.SeriesCourseMeeting, m.ID, req.OccurrenceDateLocal)
		})
		if err != nil {
			return Result{}, err
		}
		return Result{Kind: "split", OldSeriesID: m.ID}, nil
	}
}

func (s *Service) courseAll(ctx context.Context, userID string, m course.Meeting, cal calendar.Calendar, req Request) (Result, error) {
	switch req.Operation.Type {
	case OpMove, OpUpdate:
		upd := course.UpdateMeetingCmd{}
		if req.Operation.Weekday != nil {
			upd.Weekday = req.Operation.Weekday
		}
		if req.Operation.PeriodStart != nil {
			upd.PeriodStart = req.Operation.PeriodStart
		}
		if req.Operation.PeriodEnd != nil {
			upd.PeriodEnd = req.Operation.PeriodEnd
		}
		if req.Operation.HasWeekRule {
			upd.WeekRule = req.Operation.WeekRule
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
		if next.PeriodEnd < next.PeriodStart {
			return Result{}, apperr.Validation("operation.periodEnd", "must be >= periodStart")
		}
		for _, seg := range next.WeekRule {
			if seg.End > cal.TotalWeeks {
				return Result{}, apperr.Validation("operation.weekRule", "week range exceeds calendar total weeks")
			}
		}
		if !req.Operation.Force {
			existing, err := s.allMeetingsExcept(ctx, userID, cal.ID, m.ID)
			if err != nil {
				return Result{}, err
			}
			if clash := course.FindHardConflictOf(next, existing); clash != "" {
				return Result{}, apperr.CourseConflict("the updated series overlaps an existing course meeting: " + clash)
			}
		}
		err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.courseRepo.UpdateMeeting(ctx, tx, &next, upd, m.Revision)
		})
		if err != nil {
			return Result{}, err
		}
		return Result{Kind: "series_update", OldSeriesID: m.ID}, nil

	default: // CANCEL / DELETE
		err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.courseRepo.DeleteMeeting(ctx, tx, &m)
		})
		if err != nil {
			return Result{}, err
		}
		return Result{Kind: "series_delete", OldSeriesID: m.ID}, nil
	}
}

func (s *Service) allMeetingsExcept(ctx context.Context, userID, calendarID, excludeMeetingID string) ([]course.Meeting, error) {
	courses, err := s.courseRepo.ListCourses(ctx, userID, calendarID)
	if err != nil {
		return nil, err
	}
	var out []course.Meeting
	for _, c := range courses {
		ms, err := s.courseRepo.ListMeetings(ctx, userID, c.ID)
		if err != nil {
			return nil, err
		}
		for _, m := range ms {
			if m.ID != excludeMeetingID {
				out = append(out, m)
			}
		}
	}
	return out, nil
}

// ---- recurring schedules ------------------------------------------------------

func (s *Service) applyRecurring(ctx context.Context, userID string, req Request, loc *time.Location) (Result, error) {
	rs, err := s.schedRepo.Get(ctx, userID, req.SeriesID)
	if err != nil {
		return Result{}, err
	}
	if err := occurrenceExistsInRule(rs.Rule, req.OccurrenceDateLocal); err != nil {
		return Result{}, err
	}
	switch req.Scope {
	case ScopeThis:
		return s.recurringThis(ctx, userID, rs, req, loc)
	case ScopeThisAndFuture:
		return s.recurringSplit(ctx, userID, rs, req)
	default:
		return s.recurringAll(ctx, userID, rs, req)
	}
}

func occurrenceExistsInRule(rule schedule.Rule, date string) error {
	switch rule.Kind {
	case schedule.KindDaily, schedule.KindWeekly:
		if date < rule.DateStart || date > rule.DateEnd {
			return apperr.Validation("occurrenceDateLocal", "date is outside the schedule range")
		}
		if rule.Kind == schedule.KindWeekly {
			wd, err := timeutil.WeekdayOf(date)
			if err != nil {
				return err
			}
			found := false
			for _, w := range rule.Weekdays {
				if w == wd {
					found = true
					break
				}
			}
			if !found {
				return apperr.Validation("occurrenceDateLocal", "no occurrence of this series on that date")
			}
		}
		return nil
	case schedule.KindByAcademicWeek:
		wd, err := timeutil.WeekdayOf(date)
		if err != nil {
			return err
		}
		found := false
		for _, w := range rule.Weekdays {
			if w == wd {
				found = true
				break
			}
		}
		if !found {
			return apperr.Validation("occurrenceDateLocal", "no occurrence of this series on that date")
		}
		return nil
	default:
		return apperr.Validation("occurrenceDateLocal", "schedule rule is invalid")
	}
}

func (s *Service) recurringThis(ctx context.Context, userID string, rs schedule.RecurringSchedule, req Request, loc *time.Location) (Result, error) {
	switch req.Operation.Type {
	case OpMove:
		if req.Operation.StartAt == nil || req.Operation.EndAt == nil {
			return Result{}, apperr.Validation("operation.startAt", "MOVE requires startAt and endAt")
		}
		if err := timeutil.CheckSameLocalDay(*req.Operation.StartAt, *req.Operation.EndAt, loc, "moved occurrence"); err != nil {
			return Result{}, err
		}
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesRecurring, SeriesID: rs.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionMove,
			ReplacementStartAt:  req.Operation.StartAt, ReplacementEndAt: req.Operation.EndAt,
			Metadata: patchMetadata(req.Operation.Patch),
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil
	case OpUpdate:
		if len(req.Operation.Patch) == 0 {
			return Result{}, apperr.Validation("operation.patch", "UPDATE requires a patch")
		}
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesRecurring, SeriesID: rs.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionUpdate,
			Metadata:            patchMetadata(req.Operation.Patch),
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil
	default:
		ov := override.Override{
			UserID: userID, SeriesType: override.SeriesRecurring, SeriesID: rs.ID,
			OccurrenceDateLocal: req.OccurrenceDateLocal,
			Action:              override.ActionCancel,
		}
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.overRepo.Upsert(ctx, tx, &ov)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "override", Override: &ov}, nil
	}
}

func (s *Service) recurringSplit(ctx context.Context, userID string, rs schedule.RecurringSchedule, req Request) (Result, error) {
	date := req.OccurrenceDateLocal
	switch req.Operation.Type {
	case OpMove, OpUpdate:
		oldRule, tailRule, err := s.splitRuleWithCal(ctx, userID, rs.Rule, date)
		if err != nil {
			return Result{}, err
		}
		var newRS *schedule.RecurringSchedule
		if !ruleIsEmpty(tailRule) {
			clone := rs
			clone.ID = ""
			clone.Rule = tailRule
			if req.Operation.StartLocal != nil {
				clone.Rule.StartLocal = *req.Operation.StartLocal
			}
			if req.Operation.EndLocal != nil {
				clone.Rule.EndLocal = *req.Operation.EndLocal
			}
			if req.Operation.PeriodStart != nil {
				clone.Rule.PeriodStart = *req.Operation.PeriodStart
			}
			if req.Operation.PeriodEnd != nil {
				clone.Rule.PeriodEnd = *req.Operation.PeriodEnd
			}
			if v, ok := req.Operation.Patch["title"].(string); ok {
				clone.Title = v
			}
			if v, ok := req.Operation.Patch["color"].(string); ok {
				clone.Color = &v
			}
			if v, ok := req.Operation.Patch["notes"].(string); ok {
				clone.Notes = &v
			}
			if err := s.schedSvc.ValidateRule(ctx, userID, clone.Rule); err != nil {
				return Result{}, err
			}
			newRS = &clone
		}
		err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			if ruleIsEmpty(oldRule) {
				if err := s.schedRepo.Delete(ctx, tx, &rs); err != nil {
					return err
				}
			} else {
				old := rs
				old.Rule = oldRule
				upd := schedule.UpdateCmd{Rule: &oldRule}
				if err := s.schedRepo.Update(ctx, tx, &old, upd, rs.Revision); err != nil {
					return err
				}
			}
			if newRS != nil {
				if err := s.schedRepo.Create(ctx, tx, newRS); err != nil {
					return err
				}
				return s.moveOverrides(ctx, tx, userID, override.SeriesRecurring, rs.ID, newRS.ID, date)
			}
			return s.tombstoneOverridesFrom(ctx, tx, userID, override.SeriesRecurring, rs.ID, date)
		})
		if err != nil {
			return Result{}, err
		}
		res := Result{Kind: "split", OldSeriesID: rs.ID}
		if newRS != nil {
			res.NewSeriesID = newRS.ID
		}
		return res, nil
	default: // CANCEL / DELETE
		oldRule, _, err := s.splitRuleWithCal(ctx, userID, rs.Rule, date)
		if err != nil {
			return Result{}, err
		}
		err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			if ruleIsEmpty(oldRule) {
				if err := s.schedRepo.Delete(ctx, tx, &rs); err != nil {
					return err
				}
			} else {
				old := rs
				old.Rule = oldRule
				upd := schedule.UpdateCmd{Rule: &oldRule}
				if err := s.schedRepo.Update(ctx, tx, &old, upd, rs.Revision); err != nil {
					return err
				}
			}
			return s.tombstoneOverridesFrom(ctx, tx, userID, override.SeriesRecurring, rs.ID, date)
		})
		if err != nil {
			return Result{}, err
		}
		return Result{Kind: "split", OldSeriesID: rs.ID}, nil
	}
}

func (s *Service) recurringAll(ctx context.Context, userID string, rs schedule.RecurringSchedule, req Request) (Result, error) {
	switch req.Operation.Type {
	case OpMove, OpUpdate:
		upd := schedule.UpdateCmd{}
		if v, ok := req.Operation.Patch["title"].(string); ok {
			upd.Title = &v
		}
		if v, ok := req.Operation.Patch["color"].(string); ok {
			upd.Color = &v
		}
		if v, ok := req.Operation.Patch["notes"].(string); ok {
			upd.Notes = &v
		}
		if req.Operation.StartLocal != nil || req.Operation.EndLocal != nil || req.Operation.PeriodStart != nil || req.Operation.PeriodEnd != nil {
			rule := rs.Rule
			if req.Operation.StartLocal != nil {
				rule.StartLocal = *req.Operation.StartLocal
			}
			if req.Operation.EndLocal != nil {
				rule.EndLocal = *req.Operation.EndLocal
			}
			if req.Operation.PeriodStart != nil {
				rule.PeriodStart = *req.Operation.PeriodStart
			}
			if req.Operation.PeriodEnd != nil {
				rule.PeriodEnd = *req.Operation.PeriodEnd
			}
			if err := s.schedSvc.ValidateRule(ctx, userID, rule); err != nil {
				return Result{}, err
			}
			upd.Rule = &rule
		}
		if upd.Title == nil && upd.Color == nil && upd.Notes == nil && upd.Rule == nil {
			return Result{}, apperr.Validation("operation", "nothing to update")
		}
		next, err := s.schedSvc.Update(ctx, userID, rs.ID, upd, rs.Revision)
		if err != nil {
			return Result{}, err
		}
		_ = next
		return Result{Kind: "series_update", OldSeriesID: rs.ID}, nil
	default:
		if err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return s.schedRepo.Delete(ctx, tx, &rs)
		}); err != nil {
			return Result{}, err
		}
		return Result{Kind: "series_delete", OldSeriesID: rs.ID}, nil
	}
}

// ---- helpers -----------------------------------------------------------------

// weekOfDate computes the 1-based academic week of a local date.
func weekOfDate(cal calendar.Calendar, date string) (int, error) {
	diff, err := timeutil.DiffDays(cal.FirstDay, date)
	if err != nil {
		return 0, err
	}
	if diff < 0 {
		return 0, apperr.Validation("occurrenceDateLocal", "date is before the calendar start")
	}
	return diff/7 + 1, nil
}

func patchMetadata(patch map[string]any) map[string]any {
	if len(patch) == 0 {
		return nil
	}
	out := map[string]any{}
	for _, key := range []string{"title", "teacher", "location", "color", "notes"} {
		if v, ok := patch[key]; ok {
			if s, ok := v.(string); ok {
				out[key] = s
			}
		}
	}
	return out
}

// splitRuleWithCal splits any rule kind at date, loading the calendar for
// by_academic_week rules so the week number can be derived.
func (s *Service) splitRuleWithCal(ctx context.Context, userID string, rule schedule.Rule, date string) (old schedule.Rule, tail schedule.Rule, err error) {
	if rule.Kind == schedule.KindByAcademicWeek {
		cal, err := s.calRepo.GetCalendar(ctx, userID, rule.CalendarID)
		if err != nil {
			return old, tail, err
		}
		week, err := weekOfDate(cal, date)
		if err != nil {
			return old, tail, err
		}
		if week > cal.TotalWeeks {
			return old, tail, apperr.Validation("occurrenceDateLocal", "date is outside the calendar range")
		}
		old = rule
		old.WeekRule = rule.WeekRule.RestrictBefore(week)
		tail = rule
		tail.WeekRule = rule.WeekRule.RestrictFrom(week)
		return old, tail, nil
	}
	return splitRule(rule, date)
}

// splitRule splits a daily/weekly rule at date: the old series keeps dates
// strictly before the occurrence, the tail covers the occurrence onward.
func splitRule(rule schedule.Rule, date string) (old schedule.Rule, tail schedule.Rule, err error) {
	previous, err := timeutil.AddDays(date, -1)
	if err != nil {
		return old, tail, err
	}
	switch rule.Kind {
	case schedule.KindDaily, schedule.KindWeekly:
		old = rule
		old.DateEnd = previous
		if old.DateEnd < old.DateStart {
			old = schedule.Rule{}
		}
		tail = rule
		tail.DateStart = date
		if tail.DateEnd < tail.DateStart {
			tail = schedule.Rule{}
		}
		return old, tail, nil
	case schedule.KindByAcademicWeek:
		// Handled by splitRuleWithCal; unreachable here.
		return schedule.Rule{}, schedule.Rule{}, apperr.Validation("kind", "by_academic_week split requires a calendar")
	default:
		return old, tail, apperr.Validation("kind", "unsupported rule kind")
	}
}

func ruleIsEmpty(r schedule.Rule) bool {
	return r.Kind == "" && r.DateStart == "" && len(r.WeekRule) == 0
}

// moveOverrides repoints overrides with occurrence date >= from from one
// series to another inside the same transaction.
func (s *Service) moveOverrides(ctx context.Context, tx pgx.Tx, userID, seriesType, fromSeriesID, toSeriesID, from string) error {
	ovs, err := s.overRepo.BySeries(ctx, userID, seriesType, fromSeriesID)
	if err != nil {
		return err
	}
	for _, ov := range ovs {
		if ov.OccurrenceDateLocal < from {
			continue
		}
		var newRev int64
		var updatedAt time.Time
		if err := tx.QueryRow(ctx, `
			UPDATE occurrence_overrides SET series_id = $2, updated_at = now(), revision = revision + 1
			WHERE id = $1 RETURNING revision, updated_at`, ov.ID, toSeriesID).Scan(&newRev, &updatedAt); err != nil {
			return err
		}
		ov.SeriesID = toSeriesID
		ov.Revision = newRev
		ov.UpdatedAt = updatedAt
		if _, err := sync.AppendChange(ctx, tx, userID, sync.EntityOverride, ov.ID, sync.OpUpdate, newRev, ov.Snapshot()); err != nil {
			return err
		}
	}
	return nil
}

// tombstoneOverridesFrom soft-deletes overrides with date >= from.
func (s *Service) tombstoneOverridesFrom(ctx context.Context, tx pgx.Tx, userID, seriesType, seriesID, from string) error {
	ovs, err := s.overRepo.BySeries(ctx, userID, seriesType, seriesID)
	if err != nil {
		return err
	}
	for _, ov := range ovs {
		if ov.OccurrenceDateLocal < from {
			continue
		}
		var newRev int64
		var deletedAt time.Time
		if err := tx.QueryRow(ctx, `
			UPDATE occurrence_overrides SET deleted_at = now(), revision = revision + 1, updated_at = now()
			WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, ov.ID).Scan(&newRev, &deletedAt); err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, tx, userID, sync.EntityOverride, ov.ID, sync.OpDelete, newRev,
			sync.TombstoneSnapshot(ov.Snapshot(), newRev, deletedAt)); err != nil {
			return err
		}
	}
	return nil
}
