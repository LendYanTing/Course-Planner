package importcsv

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// PreviewResult is stored on import_previews and returned to the client.
type PreviewResult struct {
	PreviewID  string         `json:"previewId"`
	ExpiresAt  string         `json:"expiresAt"`
	CalendarID string         `json:"calendarId"`
	Courses    []ParsedCourse `json:"courses"`
	Conflicts  []string       `json:"conflicts"`
}

type Service struct {
	pool    *pgxpool.Pool
	calRepo *calendar.Repo
	repo    *course.Repo
	ttl     time.Duration
}

func NewService(pool *pgxpool.Pool, calRepo *calendar.Repo, courseRepo *course.Repo, ttl time.Duration) *Service {
	return &Service{pool: pool, calRepo: calRepo, repo: courseRepo, ttl: ttl}
}

// Preview parses + validates the CSV against a calendar and stores the
// result for later commit. Returns an apperr error when any row is invalid.
func (s *Service) Preview(ctx context.Context, userID string, calendarID string, data []byte) (PreviewResult, error) {
	cal, err := s.calRepo.GetCalendar(ctx, userID, calendarID)
	if err != nil {
		return PreviewResult{}, err
	}
	periods, err := s.calRepo.ListPeriods(ctx, userID, cal.ID)
	if err != nil {
		return PreviewResult{}, err
	}
	periodSet := map[int]bool{}
	for _, p := range periods {
		periodSet[p.PeriodNo] = true
	}

	rows, err := Parse(data)
	if err != nil {
		return PreviewResult{}, err
	}
	res := Validate(rows, cal.TotalWeeks)
	for _, r := range rows {
		line := atoiOr(r["__line"], 0)
		start := atoiOr(r["periodStart"], 0)
		end := atoiOr(r["periodEnd"], 0)
		if start < 1 {
			continue
		}
		if !periodSet[start] {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "开始节数", Code: "PERIOD_NOT_DEFINED",
				Message: fmt.Sprintf("period %d is not defined in the calendar", start)})
			continue
		}
		if !periodSet[end] {
			res.Errors = append(res.Errors, FieldError{Line: line, Field: "结束节数", Code: "PERIOD_NOT_DEFINED",
				Message: fmt.Sprintf("period %d is not defined in the calendar", end)})
		}
	}

	if len(res.Errors) > 0 {
		details := make([]map[string]any, 0, len(res.Errors))
		for _, fe := range res.Errors {
			details = append(details, map[string]any{
				"line": fe.Line, "field": fe.Field, "code": fe.Code, "message": fe.Message,
			})
		}
		return PreviewResult{}, &apperr.Error{
			Status: 422, Code: apperr.CodeCsvValidationError, Message: "CSV validation failed",
			Details: map[string]any{"errors": details},
		}
	}

	// Batch + existing-course conflict detection (hard conflicts).
	conflicts, err := s.findConflicts(ctx, userID, cal.ID, res.Courses)
	if err != nil {
		return PreviewResult{}, err
	}
	if len(conflicts) > 0 {
		return PreviewResult{}, &apperr.Error{
			Status: 422, Code: apperr.CodeCourseConflict, Message: "course conflicts detected",
			Details: map[string]any{"conflicts": conflicts},
		}
	}

	previewID := uuid.NewString()
	expiresAt := time.Now().Add(s.ttl)
	resultJSON, err := json.Marshal(res)
	if err != nil {
		return PreviewResult{}, err
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO import_previews (id, user_id, calendar_id, result, status, expires_at)
		VALUES ($1,$2,$3,$4,'pending',$5)`, previewID, userID, calendarID, resultJSON, expiresAt); err != nil {
		return PreviewResult{}, err
	}
	return PreviewResult{
		PreviewID: previewID, ExpiresAt: expiresAt.UTC().Format(time.RFC3339),
		CalendarID: calendarID, Courses: res.Courses, Conflicts: conflicts,
	}, nil
}

// Commit imports every course of a preview atomically.
func (s *Service) Commit(ctx context.Context, userID, previewID string) (int, error) {
	var (
		calendarID string
		resultRaw  []byte
		status     string
	)
	if err := s.pool.QueryRow(ctx, `SELECT calendar_id, result, status FROM import_previews
		WHERE id=$1 AND user_id=$2`, previewID, userID).Scan(&calendarID, &resultRaw, &status); err != nil {
		return 0, apperr.NotFound("import preview")
	}
	if status != "pending" {
		return 0, apperr.ConfirmationExpired()
	}
	var res ParseResult
	if err := json.Unmarshal(resultRaw, &res); err != nil {
		return 0, apperr.New(500, apperr.CodeInternal, "stored preview is corrupt")
	}
	if len(res.Errors) > 0 {
		return 0, apperr.New(422, apperr.CodeCsvValidationError, "preview contains validation errors")
	}
	// Re-validate conflicts inside the commit transaction.
	conflicts, err := s.findConflicts(ctx, userID, calendarID, res.Courses)
	if err != nil {
		return 0, err
	}
	if len(conflicts) > 0 {
		return 0, apperr.CourseConflict("courses conflict with existing meetings: " + fmt.Sprint(conflicts))
	}

	count := 0
	err = database.WithTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		for _, pc := range res.Courses {
			rule, err := weekrule.ParseCsv(pc.WeekRule)
			if err != nil {
				return err
			}
			c := course.Course{
				UserID: userID, CalendarID: calendarID, Name: pc.Name,
				Teacher: nilStr(pc.Teacher), Location: nilStr(pc.Location),
			}
			if err := s.repo.CreateCourse(ctx, tx, &c); err != nil {
				return err
			}
			m := course.Meeting{
				UserID: userID, CourseID: c.ID,
				Weekday: pc.Weekday, PeriodStart: pc.PeriodStart, PeriodEnd: pc.PeriodEnd,
				WeekRule: rule,
			}
			if err := s.repo.CreateMeeting(ctx, tx, &m); err != nil {
				return err
			}
			count++
		}
		tag, err := tx.Exec(ctx, `UPDATE import_previews SET status='committed', committed_at=now()
			WHERE id=$1 AND status='pending'`, previewID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.ConfirmationExpired()
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return count, nil
}

// findConflicts checks intra-batch and existing-course hard conflicts.
func (s *Service) findConflicts(ctx context.Context, userID, calendarID string, courses []ParsedCourse) ([]string, error) {
	// Normalize to course.Meeting-like structures with their week rules.
	type cand struct {
		line int
		course.Meeting
	}
	var candidates []cand
	for _, pc := range courses {
		rule, err := weekrule.ParseCsv(pc.WeekRule)
		if err != nil {
			continue // structural errors already reported by Validate
		}
		candidates = append(candidates, cand{line: pc.Line, Meeting: course.Meeting{
			Weekday: pc.Weekday, PeriodStart: pc.PeriodStart, PeriodEnd: pc.PeriodEnd, WeekRule: rule,
		}})
	}
	// Intra-batch.
	var conflicts []string
	for i := range candidates {
		for j := i + 1; j < len(candidates); j++ {
			if candidates[i].Weekday != candidates[j].Weekday {
				continue
			}
			if periodRangeOverlap(candidates[i].PeriodStart, candidates[i].PeriodEnd, candidates[j].PeriodStart, candidates[j].PeriodEnd) &&
				weekRuleOverlap(candidates[i].WeekRule, candidates[j].WeekRule) {
				conflicts = append(conflicts, fmt.Sprintf("line %d conflicts with line %d", candidates[i].line, candidates[j].line))
			}
		}
	}
	// Against existing meetings of the calendar.
	coursesInCal, err := s.repo.ListCourses(ctx, userID, calendarID)
	if err != nil {
		return nil, err
	}
	for _, c := range coursesInCal {
		meetings, err := s.repo.ListMeetings(ctx, userID, c.ID)
		if err != nil {
			return nil, err
		}
		for _, m := range meetings {
			for _, cand := range candidates {
				if cand.Weekday != m.Weekday {
					continue
				}
				if periodRangeOverlap(cand.PeriodStart, cand.PeriodEnd, m.PeriodStart, m.PeriodEnd) &&
					weekRuleOverlap(cand.WeekRule, m.WeekRule) {
					conflicts = append(conflicts, fmt.Sprintf("line %d conflicts with existing course %q", cand.line, c.Name))
				}
			}
		}
	}
	return conflicts, nil
}

func periodRangeOverlap(a1, a2, b1, b2 int) bool { return a1 <= b2 && b1 <= a2 }

func weekRuleOverlap(a, b weekrule.Rule) bool {
	as := a.Weeks(60)
	bs := b.Weeks(60)
	for _, wa := range as {
		for _, wb := range bs {
			if wa == wb {
				return true
			}
		}
	}
	return false
}

func nilStr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}
