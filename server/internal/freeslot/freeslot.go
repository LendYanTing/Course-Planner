// Package freeslot computes free time slots within a UTC range
// (docs/api.md §12): busy = courses ∪ recurring schedules ∪ todo blocks,
// then remaining gaps are filtered by duration and aligned to a grid.
// Soft-conflict sources (todo blocks) are treated as busy by default — the
// Agent must not fabricate slots that overlap real occupations.
package freeslot

import (
	"context"
	"sort"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/todo"
	"github.com/jackc/pgx/v5/pgxpool"
)

const (
	AlignPeriod   = "period"
	Align5Minutes = "5_minutes"
	AlignFree     = "free"
)

type Slot struct {
	StartAt, EndAt time.Time
}

func (s Slot) DTO() map[string]any {
	return map[string]any{
		"startAt": s.StartAt.UTC().Format(time.RFC3339),
		"endAt":   s.EndAt.UTC().Format(time.RFC3339),
	}
}

type Options struct {
	Start, End         time.Time
	DurationMinutes    int
	Alignment          string
	ConsiderCourses    bool
	ConsiderRecurring  bool
	ConsiderTodoBlocks bool
}

type Service struct {
	pool      *pgxpool.Pool
	eventSvc  *event.Service
	schedSvc  *schedule.Service
	schedRepo *schedule.Repo
	calRepo   *calendar.Repo
	todoRepo  *todo.Repo
}

func NewService(pool *pgxpool.Pool, eventSvc *event.Service, schedSvc *schedule.Service, schedRepo *schedule.Repo, calRepo *calendar.Repo, todoRepo *todo.Repo) *Service {
	return &Service{pool: pool, eventSvc: eventSvc, schedSvc: schedSvc, schedRepo: schedRepo, calRepo: calRepo, todoRepo: todoRepo}
}

// Compute returns free slots ordered by start.
func (s *Service) Compute(ctx context.Context, userID string, opts Options, loc *time.Location) ([]Slot, error) {
	if !opts.End.After(opts.Start) {
		return nil, apperr.Validation("end", "must be after start")
	}
	if opts.DurationMinutes < 1 {
		return nil, apperr.Validation("durationMinutes", "must be >= 1")
	}
	if opts.Alignment == "" {
		opts.Alignment = AlignPeriod
	}
	switch opts.Alignment {
	case AlignPeriod, Align5Minutes, AlignFree:
	default:
		return nil, apperr.Validation("alignment", "must be period, 5_minutes or free")
	}

	var busy []event.Interval
	if opts.ConsiderCourses {
		courseOccs, err := s.eventSvc.CourseOccurrences(ctx, userID, opts.Start, opts.End, loc)
		if err != nil {
			return nil, err
		}
		for _, c := range courseOccs {
			busy = append(busy, event.Interval{Start: c.Start, End: c.End})
		}
	}
	if opts.ConsiderRecurring {
		rsList, err := s.schedRepo.List(ctx, userID)
		if err != nil {
			return nil, err
		}
		resolve := schedule.NewResolver(userID, s.calRepo)
		rsOccs, err := s.schedSvc.Expand(ctx, userID, rsList, resolve, opts.Start, opts.End, loc)
		if err != nil {
			return nil, err
		}
		for _, occ := range rsOccs {
			busy = append(busy, event.Interval{Start: occ.Start, End: occ.End})
		}
	}
	if opts.ConsiderTodoBlocks {
		blocks, err := s.todoRepo.BlocksInRange(ctx, userID, opts.Start, opts.End)
		if err != nil {
			return nil, err
		}
		for _, b := range blocks {
			busy = append(busy, event.Interval{Start: b.StartAt, End: b.EndAt})
		}
	}

	merged := mergeIntervals(busy)
	duration := time.Duration(opts.DurationMinutes) * time.Minute
	var out []Slot
	cursor := opts.Start
	for _, b := range merged {
		if gap := b.Start.Sub(cursor); gap >= duration {
			out = append(out, alignSlot(cursor, b.Start, duration, opts.Alignment, loc)...)
		}
		if b.End.After(cursor) {
			cursor = b.End
		}
	}
	if gap := opts.End.Sub(cursor); gap >= duration {
		out = append(out, alignSlot(cursor, opts.End, duration, opts.Alignment, loc)...)
	}
	return out, nil
}

// alignSlot snaps slot boundaries to the requested grid. Period alignment
// falls back to a 5-minute grid when no period template can bound the slot.
func alignSlot(start, end time.Time, duration time.Duration, alignment string, loc *time.Location) []Slot {
	switch alignment {
	case AlignFree:
		return []Slot{{StartAt: start, EndAt: end}}
	default: // period + 5_minutes: snap start to next 5-minute local boundary
		st := start.In(loc)
		rem := (st.Minute() % 5)
		var alignedStart time.Time
		if rem == 0 && st.Second() == 0 && st.Nanosecond() == 0 {
			alignedStart = st
		} else {
			add := time.Duration(5-rem)*time.Minute - time.Duration(st.Second())*time.Second - time.Duration(st.Nanosecond())*time.Nanosecond
			alignedStart = st.Add(add)
		}
		if !alignedStart.Before(end) || end.Sub(alignedStart) < duration {
			return nil
		}
		return []Slot{{StartAt: alignedStart.UTC(), EndAt: end.UTC()}}
	}
}

func mergeIntervals(intervals []event.Interval) []event.Interval {
	if len(intervals) == 0 {
		return nil
	}
	sort.Slice(intervals, func(i, j int) bool {
		if intervals[i].Start.Equal(intervals[j].Start) {
			return intervals[i].End.Before(intervals[j].End)
		}
		return intervals[i].Start.Before(intervals[j].Start)
	})
	var out []event.Interval
	cur := intervals[0]
	for _, iv := range intervals[1:] {
		if !iv.Start.After(cur.End) {
			if iv.End.After(cur.End) {
				cur.End = iv.End
			}
			continue
		}
		out = append(out, cur)
		cur = iv
	}
	out = append(out, cur)
	return out
}
