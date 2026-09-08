// Package schedule owns RecurringSchedule — user-defined recurring
// arrangements that behave like custom courses (docs/domain-model.md §6):
// no deadline, no completion state, defined by a rule covering natural days,
// weekdays or academic weeks with either explicit local times or calendar
// periods.
package schedule

import (
	"context"
	"encoding/json"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/override"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Rule kinds.
const (
	KindDaily          = "daily"
	KindWeekly         = "weekly"
	KindByAcademicWeek = "by_academic_week"
)

// Rule is the JSONB payload stored on recurring_schedules.rule.
//
//	daily:            DateStart..DateEnd, StartLocal..EndLocal every day
//	weekly:           same range but only on ISO Weekdays (1..7)
//	by_academic_week: CalendarID + WeekRule + Weekdays, time from
//	                  PeriodStart..PeriodEnd (calendar template) or
//	                  StartLocal..EndLocal when periods are omitted
type Rule struct {
	Kind        string        `json:"kind"`
	StartLocal  string        `json:"startLocal,omitempty"`
	EndLocal    string        `json:"endLocal,omitempty"`
	Weekdays    []int         `json:"weekdays,omitempty"`
	DateStart   string        `json:"dateStart,omitempty"`
	DateEnd     string        `json:"dateEnd,omitempty"`
	CalendarID  string        `json:"calendarId,omitempty"`
	WeekRule    weekrule.Rule `json:"weekRule,omitempty"`
	PeriodStart int           `json:"periodStart,omitempty"`
	PeriodEnd   int           `json:"periodEnd,omitempty"`
}

func (rule Rule) Snapshot() map[string]any {
	b, _ := json.Marshal(rule)
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	return m
}

// Validate checks the rule against its own shape (calendar/period consistency
// is checked by the service which has repo access).
func (rule Rule) Validate() error {
	switch rule.Kind {
	case KindDaily:
		return rule.validateBase()
	case KindWeekly:
		if err := rule.validateBase(); err != nil {
			return err
		}
		return rule.validateWeekdays()
	case KindByAcademicWeek:
		if rule.CalendarID == "" {
			return apperr.Validation("calendarId", "is required for by_academic_week rules")
		}
		if rule.WeekRule.IsEmpty() {
			return apperr.Validation("weekRule", "at least one week segment is required")
		}
		if err := rule.validateWeekdays(); err != nil {
			return err
		}
		if rule.PeriodStart == 0 && rule.StartLocal == "" {
			return apperr.Validation("periods", "either periodStart/periodEnd or startLocal/endLocal is required")
		}
		if rule.PeriodStart > 0 {
			if rule.PeriodEnd < rule.PeriodStart {
				return apperr.Validation("periodEnd", "must be >= periodStart")
			}
			if rule.StartLocal != "" || rule.EndLocal != "" {
				return apperr.Validation("periods", "cannot mix periods and explicit times")
			}
		} else if rule.PeriodEnd > 0 {
			return apperr.Validation("periodStart", "periodStart is required when periodEnd is set")
		}
		return nil
	default:
		return apperr.Validation("kind", "must be daily, weekly or by_academic_week")
	}
}

// validateBase enforces the shared daily/weekly shape: a bounded date range
// with explicit HH:MM times that do not cross midnight.
func (rule Rule) validateBase() error {
	if err := timeutil.ValidateDate(rule.DateStart); err != nil {
		return apperr.Validation("dateStart", "must look like YYYY-MM-DD")
	}
	if err := timeutil.ValidateDate(rule.DateEnd); err != nil {
		return apperr.Validation("dateEnd", "must look like YYYY-MM-DD")
	}
	if rule.DateEnd < rule.DateStart {
		return apperr.Validation("dateEnd", "must not be before dateStart")
	}
	if err := timeutil.ValidateHHMM(rule.StartLocal); err != nil {
		return apperr.Validation("startLocal", "must look like HH:MM")
	}
	if err := timeutil.ValidateHHMM(rule.EndLocal); err != nil {
		return apperr.Validation("endLocal", "must look like HH:MM")
	}
	sm, _ := timeutil.HHMMToMinutes(rule.StartLocal)
	em, _ := timeutil.HHMMToMinutes(rule.EndLocal)
	if em <= sm {
		return apperr.CrossMidnight("recurring schedule time")
	}
	return nil
}

func (rule Rule) validateWeekdays() error {
	if len(rule.Weekdays) == 0 {
		return apperr.Validation("weekdays", "at least one weekday is required")
	}
	seen := map[int]bool{}
	for _, wd := range rule.Weekdays {
		if wd < 1 || wd > 7 {
			return apperr.Validation("weekdays", "must be 1-7")
		}
		if seen[wd] {
			return apperr.Validation("weekdays", "duplicate weekday")
		}
		seen[wd] = true
	}
	return nil
}

type RecurringSchedule struct {
	ID        string
	UserID    string
	Title     string
	Color     *string
	Rule      Rule
	Notes     *string
	Revision  int64
	CreatedAt time.Time
	UpdatedAt time.Time
	DeletedAt *time.Time
}

func (rs RecurringSchedule) Snapshot() map[string]any {
	s := map[string]any{
		"id":        rs.ID,
		"title":     rs.Title,
		"color":     rs.Color,
		"rule":      rs.Rule.Snapshot(),
		"notes":     rs.Notes,
		"revision":  rs.Revision,
		"createdAt": rs.CreatedAt.UTC().Format(time.RFC3339),
		"updatedAt": rs.UpdatedAt.UTC().Format(time.RFC3339),
	}
	if rs.DeletedAt != nil {
		s["deletedAt"] = rs.DeletedAt.UTC().Format(time.RFC3339)
	}
	return s
}

func (rs RecurringSchedule) DTO() map[string]any { return rs.Snapshot() }

// ---- repository ---------------------------------------------------------------

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

const rsColumns = `id, user_id, title, color, rule, notes, revision, created_at, updated_at, deleted_at`

func scanRS(scanner interface {
	Scan(dest ...any) error
}) (RecurringSchedule, error) {
	var rs RecurringSchedule
	var id uuid.UUID
	var ruleJSON []byte
	if err := scanner.Scan(&id, &rs.UserID, &rs.Title, &rs.Color, &ruleJSON, &rs.Notes, &rs.Revision, &rs.CreatedAt, &rs.UpdatedAt, &rs.DeletedAt); err != nil {
		return rs, err
	}
	rs.ID = id.String()
	if err := json.Unmarshal(ruleJSON, &rs.Rule); err != nil {
		return rs, apperr.New(500, apperr.CodeInternal, "stored rule is corrupt")
	}
	return rs, nil
}

func (r *Repo) Create(ctx context.Context, db sync.DBTX, rs *RecurringSchedule) error {
	if rs.ID == "" {
		rs.ID = uuid.NewString()
	}
	now := time.Now().UTC()
	rs.CreatedAt, rs.UpdatedAt, rs.Revision = now, now, 1
	ruleJSON, err := json.Marshal(rs.Rule)
	if err != nil {
		return err
	}
	if _, err := db.Exec(ctx, `
		INSERT INTO recurring_schedules (id, user_id, title, color, rule, notes, created_at, updated_at, revision)
		VALUES ($1,$2,$3,$4,$5,$6,$7,$7,1)`,
		rs.ID, rs.UserID, rs.Title, rs.Color, ruleJSON, rs.Notes, now); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, rs.UserID, sync.EntityRecurring, rs.ID, sync.OpCreate, 1, rs.Snapshot())
	return err
}

func (r *Repo) List(ctx context.Context, userID string) ([]RecurringSchedule, error) {
	rows, err := r.pool.Query(ctx, `SELECT `+rsColumns+` FROM recurring_schedules
		WHERE user_id = $1 AND deleted_at IS NULL ORDER BY created_at`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []RecurringSchedule
	for rows.Next() {
		rs, err := scanRS(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, rs)
	}
	return out, rows.Err()
}

func (r *Repo) Get(ctx context.Context, userID, id string) (RecurringSchedule, error) {
	if _, err := uuid.Parse(id); err != nil {
		return RecurringSchedule{}, apperr.NotFound("recurring schedule")
	}
	rs, err := scanRS(r.pool.QueryRow(ctx, `SELECT `+rsColumns+` FROM recurring_schedules
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL`, id, userID))
	if err == pgx.ErrNoRows {
		return rs, apperr.NotFound("recurring schedule")
	}
	return rs, err
}

func (r *Repo) Update(ctx context.Context, db sync.DBTX, rs *RecurringSchedule, upd UpdateCmd, baseRevision int64) error {
	if upd.Title != nil {
		rs.Title = *upd.Title
	}
	if upd.Color != nil {
		rs.Color = upd.Color
	}
	if upd.Notes != nil {
		rs.Notes = upd.Notes
	}
	if upd.Rule != nil {
		rs.Rule = *upd.Rule
	}
	ruleJSON, err := json.Marshal(rs.Rule)
	if err != nil {
		return err
	}
	var newRev int64
	err = db.QueryRow(ctx, `
		UPDATE recurring_schedules
		SET title = $3, color = $4, rule = $5, notes = $6, updated_at = now(), revision = revision + 1
		WHERE id = $1 AND user_id = $2 AND deleted_at IS NULL AND revision = $7
		RETURNING revision, updated_at`,
		rs.ID, rs.UserID, rs.Title, rs.Color, ruleJSON, rs.Notes, baseRevision).Scan(&newRev, &rs.UpdatedAt)
	if err == pgx.ErrNoRows {
		return apperr.StaleRevision(sync.EntityRecurring, rs.Revision, baseRevision)
	}
	if err != nil {
		return err
	}
	rs.Revision = newRev
	_, err = sync.AppendChange(ctx, db, rs.UserID, sync.EntityRecurring, rs.ID, sync.OpUpdate, newRev, rs.Snapshot())
	return err
}

func (r *Repo) Delete(ctx context.Context, db sync.DBTX, rs *RecurringSchedule) error {
	rows, err := db.Query(ctx, `SELECT id FROM occurrence_overrides
		WHERE series_type = $1 AND series_id = $2 AND deleted_at IS NULL`, override.SeriesRecurring, rs.ID)
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
		var rev int64
		var deletedAt time.Time
		if err := db.QueryRow(ctx, `UPDATE occurrence_overrides SET deleted_at = now(), revision = revision + 1, updated_at = now()
			WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, oid).Scan(&rev, &deletedAt); err != nil {
			return err
		}
		if _, err := sync.AppendChange(ctx, db, rs.UserID, sync.EntityOverride, oid, sync.OpDelete, rev, sync.TombstoneSnapshot(map[string]any{"id": oid}, rev, deletedAt)); err != nil {
			return err
		}
	}
	var rev int64
	var deletedAt time.Time
	if err := db.QueryRow(ctx, `UPDATE recurring_schedules SET deleted_at = now(), revision = revision + 1, updated_at = now()
		WHERE id = $1 AND deleted_at IS NULL RETURNING revision, deleted_at`, rs.ID).Scan(&rev, &deletedAt); err != nil {
		return err
	}
	_, err = sync.AppendChange(ctx, db, rs.UserID, sync.EntityRecurring, rs.ID, sync.OpDelete, rev, sync.TombstoneSnapshot(rs.Snapshot(), rev, deletedAt))
	return err
}

// ---- service -----------------------------------------------------------------

type Service struct {
	pool     *pgxpool.Pool
	repo     *Repo
	calRepo  *calendar.Repo
	overRepo *override.Repo
}

func NewService(pool *pgxpool.Pool, repo *Repo, calRepo *calendar.Repo, overRepo *override.Repo) *Service {
	return &Service{pool: pool, repo: repo, calRepo: calRepo, overRepo: overRepo}
}

type CreateCmd struct {
	Title string
	Color *string
	Rule  Rule
	Notes *string
}

// ValidateRule is the exported rule validation used by series editing and
// the agent change-set preview.
func (s *Service) ValidateRule(ctx context.Context, userID string, rule Rule) error {
	_, err := s.validateRuleShape(ctx, userID, rule)
	return err
}

// validateRuleShape cross-checks a rule against calendars/period templates.
func (s *Service) validateRuleShape(ctx context.Context, userID string, rule Rule) (Rule, error) {
	if err := rule.Validate(); err != nil {
		return rule, err
	}
	if rule.Kind == KindByAcademicWeek {
		cal, err := s.calRepo.GetCalendar(ctx, userID, rule.CalendarID)
		if err != nil {
			return rule, err
		}
		for _, seg := range rule.WeekRule {
			if seg.End > cal.TotalWeeks {
				return rule, apperr.Validation("weekRule", "week range exceeds calendar total weeks")
			}
		}
		if rule.PeriodStart > 0 {
			periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
			if err != nil {
				return rule, err
			}
			found := func(no int) bool {
				for _, p := range periods {
					if p.PeriodNo == no {
						return true
					}
				}
				return false
			}
			if !found(rule.PeriodStart) || !found(rule.PeriodEnd) {
				return rule, apperr.Validation("periods", "period is not defined in the calendar template")
			}
		}
	}
	return rule, nil
}

func (s *Service) Create(ctx context.Context, userID string, cmd CreateCmd) (RecurringSchedule, error) {
	if cmd.Title == "" || len(cmd.Title) > 100 {
		return RecurringSchedule{}, apperr.Validation("title", "must be 1-100 characters")
	}
	rule, err := s.validateRuleShape(ctx, userID, cmd.Rule)
	if err != nil {
		return RecurringSchedule{}, err
	}
	rs := RecurringSchedule{UserID: userID, Title: cmd.Title, Color: cmd.Color, Rule: rule, Notes: cmd.Notes}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Create(ctx, tx, &rs)
	})
	return rs, err
}

func (s *Service) List(ctx context.Context, userID string) ([]RecurringSchedule, error) {
	return s.repo.List(ctx, userID)
}

func (s *Service) Get(ctx context.Context, userID, id string) (RecurringSchedule, error) {
	return s.repo.Get(ctx, userID, id)
}

type UpdateCmd struct {
	Title *string
	Color *string
	Rule  *Rule
	Notes *string
}

func (s *Service) Update(ctx context.Context, userID, id string, upd UpdateCmd, baseRevision int64) (RecurringSchedule, error) {
	rs, err := s.repo.Get(ctx, userID, id)
	if err != nil {
		return rs, err
	}
	if upd.Title != nil && (*upd.Title == "" || len(*upd.Title) > 100) {
		return rs, apperr.Validation("title", "must be 1-100 characters")
	}
	if upd.Rule != nil {
		rule, err := s.validateRuleShape(ctx, userID, *upd.Rule)
		if err != nil {
			return rs, err
		}
		upd.Rule = &rule
	}
	if baseRevision == 0 {
		baseRevision = rs.Revision
	}
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Update(ctx, tx, &rs, upd, baseRevision)
	})
	return rs, err
}

func (s *Service) Delete(ctx context.Context, userID, id string) error {
	rs, err := s.repo.Get(ctx, userID, id)
	if err != nil {
		return err
	}
	return database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.repo.Delete(ctx, tx, &rs)
	})
}

// ---- occurrence expansion -------------------------------------------------------

// Occurrence is one materialized instance of a recurring schedule.
type Occurrence struct {
	ScheduleID          string
	DateLocal           string
	Start, End          time.Time
	Cancelled           bool
	Title, Color, Notes *string
	Overridden          bool
}

// CalendarCtx bundles a calendar with its resolved period minute-times so
// expansion does not re-query per occurrence.
type CalendarCtx struct {
	Calendar    calendar.Calendar
	PeriodTimes map[int][2]int
}

// Resolver loads (and caches) calendar contexts for expansion; build one per
// request via NewResolver.
type Resolver func(ctx context.Context, calendarID string) (*CalendarCtx, error)

// NewResolver builds a resolver bound to the acting user, caching each
// calendar's period times for the lifetime of the request.
func NewResolver(userID string, calRepo *calendar.Repo) Resolver {
	cache := map[string]*CalendarCtx{}
	return func(ctx context.Context, calendarID string) (*CalendarCtx, error) {
		if c, ok := cache[calendarID]; ok {
			return c, nil
		}
		cal, err := calRepo.GetCalendar(ctx, userID, calendarID)
		if err != nil {
			return nil, err
		}
		periods, err := calRepo.ListPeriods(ctx, userID, cal.ID)
		if err != nil {
			return nil, err
		}
		times := map[int][2]int{}
		for _, p := range periods {
			sm, _ := timeutil.HHMMToMinutes(p.StartLocal)
			em, _ := timeutil.HHMMToMinutes(p.EndLocal)
			times[p.PeriodNo] = [2]int{sm, em}
		}
		cc := &CalendarCtx{Calendar: cal, PeriodTimes: times}
		cache[calendarID] = cc
		return cc, nil
	}
}

// Expand materializes occurrences in [start,end] UTC applying overrides.
func (s *Service) Expand(ctx context.Context, userID string, schedules []RecurringSchedule, resolve Resolver, start, end time.Time, loc *time.Location) ([]Occurrence, error) {
	ids := make([]string, 0, len(schedules))
	for _, rs := range schedules {
		ids = append(ids, rs.ID)
	}
	overridesBySeries, err := s.overRepo.OfSeriesSet(ctx, userID, override.SeriesRecurring, ids)
	if err != nil {
		return nil, err
	}
	var out []Occurrence
	for _, rs := range schedules {
		overByDate := make(map[string]override.Override)
		for _, o := range overridesBySeries[rs.ID] {
			overByDate[o.OccurrenceDateLocal] = o
		}
		occs, err := s.expandOne(ctx, rs, overByDate, resolve, start, end, loc)
		if err != nil {
			return nil, err
		}
		out = append(out, occs...)
	}
	return out, nil
}

func (s *Service) expandOne(ctx context.Context, rs RecurringSchedule, overByDate map[string]override.Override, resolve Resolver, start, end time.Time, loc *time.Location) ([]Occurrence, error) {
	rule := rs.Rule

	type candidate struct {
		date       string
		start, end time.Time
	}
	var candidates []candidate

	switch rule.Kind {
	case KindDaily, KindWeekly:
		all, err := timeutil.DateRangeInLoc(rule.DateStart, rule.DateEnd, 366)
		if err != nil {
			return nil, err
		}
		for _, d := range all {
			if rule.Kind == KindWeekly {
				wd, err := timeutil.WeekdayOf(d)
				if err != nil {
					return nil, err
				}
				if !intIn(rule.Weekdays, wd) {
					continue
				}
			}
			occStart, err1 := timeutil.Localize(d, rule.StartLocal, loc)
			occEnd, err2 := timeutil.Localize(d, rule.EndLocal, loc)
			if err1 != nil || err2 != nil {
				continue
			}
			candidates = append(candidates, candidate{d, occStart, occEnd})
		}
	case KindByAcademicWeek:
		cc, err := resolve(ctx, rule.CalendarID)
		if err != nil {
			return nil, err
		}
		usePeriods := rule.PeriodStart > 0
		for _, wd := range rule.Weekdays {
			for _, week := range rule.WeekRule.Weeks(cc.Calendar.TotalWeeks) {
				d := calendar.LocalDateOfOccurrence(cc.Calendar, week, wd)
				if d == "" {
					continue
				}
				var occStart, occEnd time.Time
				var err1, err2 error
				if usePeriods {
					sm, ok1 := cc.PeriodTimes[rule.PeriodStart]
					em, ok2 := cc.PeriodTimes[rule.PeriodEnd]
					if !ok1 || !ok2 {
						continue
					}
					occStart, err1 = timeutil.LocalizeMinute(d, sm[0], loc)
					occEnd, err2 = timeutil.LocalizeMinute(d, em[1], loc)
				} else {
					occStart, err1 = timeutil.Localize(d, rule.StartLocal, loc)
					occEnd, err2 = timeutil.Localize(d, rule.EndLocal, loc)
				}
				if err1 != nil || err2 != nil {
					continue
				}
				candidates = append(candidates, candidate{d, occStart, occEnd})
			}
		}
	}

	var out []Occurrence
	for _, cand := range candidates {
		occ := Occurrence{
			ScheduleID: rs.ID, DateLocal: cand.date, Start: cand.start, End: cand.end,
			Title: strPtr(rs.Title), Color: rs.Color, Notes: rs.Notes,
		}
		if ov, ok := overByDate[cand.date]; ok {
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
				if v, ok := ov.Metadata["title"].(string); ok {
					occ.Title = strPtr(v)
				}
				if v, ok := ov.Metadata["color"].(string); ok {
					occ.Color = strPtr(v)
				}
				if v, ok := ov.Metadata["notes"].(string); ok {
					occ.Notes = strPtr(v)
				}
			}
		}
		if occ.Cancelled {
			continue
		}
		if occ.End.Before(start) || occ.Start.After(end) {
			continue
		}
		out = append(out, occ)
	}
	return out, nil
}

func intIn(list []int, v int) bool {
	for _, x := range list {
		if x == v {
			return true
		}
	}
	return false
}

func strPtr(s string) *string { return &s }
