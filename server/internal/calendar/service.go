package calendar

import (
	"context"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Service holds the domain rules for calendars and period templates.
// REST handlers, the sync engine and MCP tools all go through it.
type Service struct {
	pool *pgxpool.Pool
	repo *Repo
}

func NewService(pool *pgxpool.Pool, repo *Repo) *Service {
	return &Service{pool: pool, repo: repo}
}

// ---- calendar commands ----------------------------------------------------

type CreateCalendarCmd struct {
	Name       string
	FirstDay   string
	TotalWeeks int
}

func (s *Service) Create(ctx context.Context, userID string, cmd CreateCalendarCmd) (Calendar, error) {
	if err := validateName(cmd.Name); err != nil {
		return Calendar{}, err
	}
	if err := timeutil.ValidateDate(cmd.FirstDay); err != nil {
		return Calendar{}, err
	}
	if cmd.TotalWeeks < 1 || cmd.TotalWeeks > 60 {
		return Calendar{}, apperr.Validation("totalWeeks", "must be between 1 and 60")
	}
	c := Calendar{UserID: userID, Name: cmd.Name, FirstDay: cmd.FirstDay, TotalWeeks: cmd.TotalWeeks}
	err := database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.CreateCalendar(ctx, tx, &c)
	})
	return c, err
}

func (s *Service) List(ctx context.Context, userID string) ([]Calendar, error) {
	return s.repo.ListCalendars(ctx, userID)
}

func (s *Service) Get(ctx context.Context, userID, id string) (Calendar, error) {
	return s.repo.GetCalendar(ctx, userID, id)
}

func (s *Service) Update(ctx context.Context, userID, id string, cmd UpdateCalendarCmd, baseRevision int64) (Calendar, error) {
	c, err := s.repo.GetCalendar(ctx, userID, id)
	if err != nil {
		return c, err
	}
	if cmd.Name != nil {
		if err := validateName(*cmd.Name); err != nil {
			return c, err
		}
	}
	if cmd.FirstDay != nil {
		if err := timeutil.ValidateDate(*cmd.FirstDay); err != nil {
			return c, err
		}
	}
	if cmd.TotalWeeks != nil {
		if *cmd.TotalWeeks < 1 || *cmd.TotalWeeks > 60 {
			return c, apperr.Validation("totalWeeks", "must be between 1 and 60")
		}
	}
	if baseRevision == 0 {
		baseRevision = c.Revision // last-write-wins when client doesn't care
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.UpdateCalendar(ctx, tx, &c, cmd, baseRevision)
	})
	return c, err
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	c, err := s.repo.GetCalendar(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.DeleteCalendar(ctx, tx, &c)
	})
}

// ---- period commands -------------------------------------------------------

type CreatePeriodCmd struct {
	CalendarID string
	PeriodNo   int
	StartLocal string
	EndLocal   string
}

func (s *Service) CreatePeriod(ctx context.Context, userID string, cmd CreatePeriodCmd) (Period, error) {
	if err := validatePeriod(cmd.PeriodNo, cmd.StartLocal, cmd.EndLocal); err != nil {
		return Period{}, err
	}
	calendar, err := s.repo.GetCalendar(ctx, userID, cmd.CalendarID)
	if err != nil {
		return Period{}, err
	}
	p := Period{UserID: userID, CalendarID: calendar.ID, PeriodNo: cmd.PeriodNo, StartLocal: cmd.StartLocal, EndLocal: cmd.EndLocal}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.CreatePeriod(ctx, tx, &p)
	})
	return p, err
}

func (s *Service) ListPeriods(ctx context.Context, userID, calendarID string) ([]Period, error) {
	if _, err := s.repo.GetCalendar(ctx, userID, calendarID); err != nil {
		return nil, err
	}
	return s.repo.ListPeriods(ctx, userID, calendarID)
}

func (s *Service) GetPeriod(ctx context.Context, userID, id string) (Period, error) {
	return s.repo.GetPeriod(ctx, userID, id)
}

func (s *Service) UpdatePeriod(ctx context.Context, userID, id string, cmd UpdatePeriodCmd, baseRevision int64) (Period, error) {
	p, err := s.repo.GetPeriod(ctx, userID, id)
	if err != nil {
		return p, err
	}
	nextNo, nextStart, nextEnd := p.PeriodNo, p.StartLocal, p.EndLocal
	if cmd.PeriodNo != nil {
		nextNo = *cmd.PeriodNo
	}
	if cmd.StartLocal != nil {
		nextStart = *cmd.StartLocal
	}
	if cmd.EndLocal != nil {
		nextEnd = *cmd.EndLocal
	}
	if err := validatePeriod(nextNo, nextStart, nextEnd); err != nil {
		return p, err
	}
	if baseRevision == 0 {
		baseRevision = p.Revision
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.UpdatePeriod(ctx, tx, &p, cmd, baseRevision)
	})
	return p, err
}

func (s *Service) DeletePeriod(ctx context.Context, userID, id string) error {
	p, err := s.repo.GetPeriod(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.DeletePeriod(ctx, tx, &p)
	})
}

// validatePeriod enforces period rules: ordered times, no cross-midnight
// (docs/domain-model.md §3) and a sane period number.
func validatePeriod(no int, start, end string) error {
	if no < 1 || no > 30 {
		return apperr.Validation("periodNo", "must be between 1 and 30")
	}
	if err := timeutil.ValidateHHMM(start); err != nil {
		return apperr.Validation("startLocal", "must look like HH:MM")
	}
	if err := timeutil.ValidateHHMM(end); err != nil {
		return apperr.Validation("endLocal", "must look like HH:MM")
	}
	sm, _ := timeutil.HHMMToMinutes(start)
	em, _ := timeutil.HHMMToMinutes(end)
	if em <= sm {
		return apperr.Validation("endLocal", "period end must be after start")
	}
	// A period ending at 24:00 is not representable ('HH:MM' < 24:00), so
	// same-day validity holds automatically; explicit check kept for clarity.
	if em > 24*60 {
		return apperr.CrossMidnight("period")
	}
	return nil
}

func validateName(name string) error {
	if name == "" || len(name) > 100 {
		return apperr.Validation("name", "must be 1-100 characters")
	}
	return nil
}

// WeekDates returns the civil date of the given academic week numbers for a
// calendar: week w starts at firstDay + (w-1)*7 days.
func WeekDates(c Calendar, weeks []int) map[int]string {
	out := make(map[int]string, len(weeks))
	for _, w := range weeks {
		d, err := timeutil.AddDays(c.FirstDay, (w-1)*7)
		if err != nil {
			continue
		}
		out[w] = d
	}
	return out
}

// LocalDateOfOccurrence computes the civil date of a meeting/schedule
// occurrence in academic week w on ISO weekday wd.
func LocalDateOfOccurrence(c Calendar, w, wd int) string {
	base, err := timeutil.AddDays(c.FirstDay, (w-1)*7)
	if err != nil {
		return ""
	}
	// first_day's own weekday offset: weekday 1 is the first Monday-based day.
	fdWd, err := timeutil.WeekdayOf(c.FirstDay)
	if err != nil {
		return ""
	}
	offset := wd - fdWd
	return mustAddDays(base, offset)
}

func mustAddDays(d string, n int) string {
	out, err := timeutil.AddDays(d, n)
	if err != nil {
		return d
	}
	return out
}
