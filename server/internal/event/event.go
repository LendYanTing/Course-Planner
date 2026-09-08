// Package event materializes the unified CalendarEvent projection
// (docs/domain-model.md §14-15) from courses, recurring schedules, todo
// blocks and deadlines, computing per-event conflict states:
//
//	course vs course            -> hard_conflict on both
//	recurring_schedule vs course -> soft_conflict on the schedule event
//	todo_block vs course         -> soft_conflict on the block event
package event

import (
	"context"
	"sort"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/todo"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	TypeCourse    = "course"
	TypeRecurring = "recurring_schedule"
	TypeTodoBlock = "todo_block"
	TypeDeadline  = "deadline"

	ConflictNone = "none"
	ConflictSoft = "soft_conflict"
	ConflictHard = "hard_conflict"
)

// Event is one entry of GET /calendar/events.
type Event struct {
	ID            string
	Type          string
	Title         string
	StartAt       time.Time
	EndAt         time.Time
	EndAtPresent  bool // false only for deadline point events
	SourceType    string
	SourceID      string
	ConflictState string
	Metadata      map[string]any
}

func (e Event) DTO() map[string]any {
	out := map[string]any{
		"id":            e.ID,
		"type":          e.Type,
		"title":         e.Title,
		"startAt":       e.StartAt.UTC().Format(time.RFC3339),
		"source":        map[string]any{"type": e.SourceType, "id": e.SourceID},
		"conflictState": e.ConflictState,
		"metadata":      e.Metadata,
	}
	if e.EndAtPresent {
		out["endAt"] = e.EndAt.UTC().Format(time.RFC3339)
	} else {
		out["endAt"] = nil
		out["allDay"] = false
	}
	return out
}

// IncludeOptions toggles event sources.
type IncludeOptions struct {
	Courses            bool
	RecurringSchedules bool
	TodoBlocks         bool
	Deadlines          bool
}

// Interval is a UTC busy interval (free-slot computation).
type Interval struct {
	Start, End time.Time
}

type Service struct {
	pool      *pgxpool.Pool
	calRepo   *calendar.Repo
	courseSvc *course.Service
	schedRepo *schedule.Repo
	schedSvc  *schedule.Service
	todoRepo  *todo.Repo
}

func NewService(pool *pgxpool.Pool, calRepo *calendar.Repo, courseSvc *course.Service, schedRepo *schedule.Repo, schedSvc *schedule.Service, todoRepo *todo.Repo) *Service {
	return &Service{pool: pool, calRepo: calRepo, courseSvc: courseSvc, schedRepo: schedRepo, schedSvc: schedSvc, todoRepo: todoRepo}
}

// Events returns the materialized projection for [start,end).
func (s *Service) Events(ctx context.Context, userID string, start, end time.Time, loc *time.Location, opts IncludeOptions) ([]Event, error) {
	courseOccs, err := s.CourseOccurrences(ctx, userID, start, end, loc)
	if err != nil {
		return nil, err
	}
	var rsOccs []schedule.Occurrence
	if opts.RecurringSchedules {
		rsList, err := s.schedRepo.List(ctx, userID)
		if err != nil {
			return nil, err
		}
		resolve := schedule.NewResolver(userID, s.calRepo)
		rsOccs, err = s.schedSvc.Expand(ctx, userID, rsList, resolve, start, end, loc)
		if err != nil {
			return nil, err
		}
	}

	var events []Event

	// Course events with pairwise hard-conflict detection.
	if opts.Courses {
		for i := range courseOccs {
			occ := &courseOccs[i]
			state := ConflictNone
			for j := range courseOccs {
				if i == j {
					continue
				}
				other := &courseOccs[j]
				if other.MeetingID == occ.MeetingID {
					continue // same series never conflicts with itself
				}
				if timeutil.Overlap(occ.Start, occ.End, other.Start, other.End) {
					state = ConflictHard
					break
				}
			}
			events = append(events, Event{
				ID:   "course:" + occ.MeetingID + ":" + occ.DateLocal,
				Type: TypeCourse, Title: deref(occ.Title, "课程"),
				StartAt: occ.Start, EndAt: occ.End, EndAtPresent: true,
				SourceType: "course_meeting", SourceID: occ.MeetingID,
				ConflictState: state,
				Metadata: map[string]any{
					"courseId": occ.CourseID, "meetingId": occ.MeetingID,
					"teacher": occ.Teacher, "location": occ.Location, "color": occ.Color,
					"periodStart": occ.PeriodStart, "periodEnd": occ.PeriodEnd,
					"overridden": occ.Overridden, "week": occ.Week,
					"displayDate": occ.DateLocal,
				},
			})
		}
	}

	// Recurring schedule events (soft conflict vs courses).
	if opts.RecurringSchedules {
		for _, occ := range rsOccs {
			state := ConflictNone
			for _, c := range courseOccs {
				if timeutil.Overlap(occ.Start, occ.End, c.Start, c.End) {
					state = ConflictSoft
					break
				}
			}
			events = append(events, Event{
				ID:   "recurring:" + occ.ScheduleID + ":" + occ.DateLocal,
				Type: TypeRecurring, Title: deref(occ.Title, ""),
				StartAt: occ.Start, EndAt: occ.End, EndAtPresent: true,
				SourceType: "recurring_schedule", SourceID: occ.ScheduleID,
				ConflictState: state,
				Metadata: map[string]any{
					"scheduleId": occ.ScheduleID, "overridden": occ.Overridden,
					"color": occ.Color, "notes": occ.Notes,
					"displayDate": occ.DateLocal,
				},
			})
		}
	}

	// Todo block events (soft conflict vs courses).
	if opts.TodoBlocks {
		blocks, err := s.todoRepo.BlocksInRange(ctx, userID, start, end)
		if err != nil {
			return nil, err
		}
		todosByID := map[string]todo.Todo{}
		for _, b := range blocks {
			t, ok := todosByID[b.TodoID]
			if !ok {
				t, err = s.todoRepo.Get(ctx, userID, b.TodoID)
				if err != nil {
					continue // parent todo deleted; block is orphaned in UI terms
				}
				todosByID[b.TodoID] = t
			}
			state := ConflictNone
			for _, c := range courseOccs {
				if timeutil.Overlap(b.StartAt, b.EndAt, c.Start, c.End) {
					state = ConflictSoft
					break
				}
			}
			events = append(events, Event{
				ID:   "todo_block:" + b.ID,
				Type: TypeTodoBlock, Title: t.Title,
				StartAt: b.StartAt, EndAt: b.EndAt, EndAtPresent: true,
				SourceType: "todo_block", SourceID: b.ID,
				ConflictState: state,
				Metadata: map[string]any{
					"todoId": t.ID, "blockId": b.ID, "blockNote": b.BlockNote,
					"status": b.Status, "color": t.Color,
				},
			})
		}
	}

	// Deadline point events.
	if opts.Deadlines {
		todos, err := s.todoRepo.List(ctx, userID, todo.ListFilter{})
		if err != nil {
			return nil, err
		}
		for _, t := range todos {
			if t.DeadlineAt == nil {
				continue
			}
			if t.DeadlineAt.Before(start) || !t.DeadlineAt.Before(end) {
				continue
			}
			events = append(events, Event{
				ID:   "deadline:" + t.ID,
				Type: TypeDeadline, Title: t.Title,
				StartAt: *t.DeadlineAt, EndAtPresent: false,
				SourceType: "todo", SourceID: t.ID,
				ConflictState: ConflictNone,
				Metadata: map[string]any{
					"todoId": t.ID, "priority": t.Priority,
					"deadlineAt": t.DeadlineAt.UTC().Format(time.RFC3339),
				},
			})
		}
	}

	sort.SliceStable(events, func(i, j int) bool {
		if events[i].StartAt.Equal(events[j].StartAt) {
			return events[i].ID < events[j].ID
		}
		return events[i].StartAt.Before(events[j].StartAt)
	})
	return events, nil
}

// CourseOccurrences loads and expands every course meeting occurrence in
// range. Shared with the free-slot service and the todo-block conflict probe.
func (s *Service) CourseOccurrences(ctx context.Context, userID string, start, end time.Time, loc *time.Location) ([]course.Occurrence, error) {
	cals, err := s.calRepo.ListCalendars(ctx, userID)
	if err != nil {
		return nil, err
	}
	var out []course.Occurrence
	for _, cal := range cals {
		// Cheap relevance check: calendar must intersect the range.
		calStart, err1 := timeutil.LocalMidnightUTC(cal.FirstDay, loc)
		calEnd, err2 := timeutil.AddDays(cal.FirstDay, cal.TotalWeeks*7)
		if err1 != nil || err2 != nil {
			continue
		}
		calEndUTC, err3 := timeutil.LocalMidnightUTC(calEnd, loc)
		if err3 != nil {
			continue
		}
		if calEndUTC.Before(start) || calStart.After(end) {
			continue
		}
		courses, err := s.courseSvc.List(ctx, userID, cal.ID)
		if err != nil {
			return nil, err
		}
		if len(courses) == 0 {
			continue
		}
		meetingsByCourse := map[string][]course.Meeting{}
		coursesByID := map[string]course.Course{}
		var meetings []course.Meeting
		for _, c := range courses {
			coursesByID[c.ID] = c
			ms, err := s.courseSvc.ListMeetings(ctx, userID, c.ID)
			if err != nil {
				return nil, err
			}
			meetingsByCourse[c.ID] = ms
			meetings = append(meetings, ms...)
		}
		if len(meetings) == 0 {
			continue
		}
		periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
		if err != nil {
			return nil, err
		}
		periodTimes, err := course.BuildPeriodTimes(periods)
		if err != nil {
			return nil, err
		}
		occs, err := s.courseSvc.ExpandMeetings(ctx, userID, meetings, coursesByID, cal, periodTimes, start, end, loc)
		if err != nil {
			return nil, err
		}
		out = append(out, occs...)
	}
	return out, nil
}

func deref(p *string, def string) string {
	if p == nil {
		return def
	}
	return *p
}
