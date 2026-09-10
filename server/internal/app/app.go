// Package app wires every module into a ready-to-serve chi router:
// repositories -> domain services -> HTTP handlers + MCP server, sharing the
// same PostgreSQL pool and the same sync journal (docs/architecture.md §3).
package app

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/carryingon/courseplanner/server/internal/agent"
	"github.com/carryingon/courseplanner/server/internal/auth"
	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/category"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/freeslot"
	"github.com/carryingon/courseplanner/server/internal/importcsv"
	"github.com/carryingon/courseplanner/server/internal/mcp"
	"github.com/carryingon/courseplanner/server/internal/mcpconnect"
	"github.com/carryingon/courseplanner/server/internal/mcptoken"
	"github.com/carryingon/courseplanner/server/internal/override"
	"github.com/carryingon/courseplanner/server/internal/platform/config"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/series"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/carryingon/courseplanner/server/internal/tag"
	"github.com/carryingon/courseplanner/server/internal/todo"
	"github.com/carryingon/courseplanner/server/internal/user"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Server holds every dependency and the root router.
type Server struct {
	Cfg  *config.Config
	Pool *pgxpool.Pool
	// Service handles (exposed for tests).
	AuthService *auth.Service
	CalendarSvc *calendar.Service
	CourseSvc   *course.Service
	ScheduleSvc *schedule.Service
	TodoSvc     *todo.Service
	TagSvc      *tag.Service
	CategorySvc *category.Service
	EventSvc    *event.Service
	FreeSlotSvc *freeslot.Service
	SeriesSvc   *series.Service
	AgentSvc    *agent.Service
	ImportSvc   *importcsv.Service
	PushService *sync.PushService
	Journal     *sync.Journal
	McpTokens   *mcptoken.Repo
	Router      http.Handler
}

// New builds the whole application. It connects to PostgreSQL and applies
// migrations before wiring anything.
func New(ctx context.Context, cfg *config.Config) (*Server, error) {
	pool, err := database.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return nil, fmt.Errorf("database: %w", err)
	}
	if err := database.Migrate(ctx, pool); err != nil {
		pool.Close()
		return nil, fmt.Errorf("migrate: %w", err)
	}

	// ---- repositories -------------------------------------------------------
	userRepo := user.NewRepo(pool)
	calRepo := calendar.NewRepo(pool)
	courseRepo := course.NewRepo(pool)
	schedRepo := schedule.NewRepo(pool)
	overRepo := override.NewRepo(pool)
	todoRepo := todo.NewRepo(pool)

	// ---- services -------------------------------------------------------------
	calSvc := calendar.NewService(pool, calRepo)
	courseSvc := course.NewService(pool, courseRepo, calRepo, overRepo)
	schedSvc := schedule.NewService(pool, schedRepo, calRepo, overRepo)

	eventSvc := event.NewService(pool, calRepo, courseSvc, schedRepo, schedSvc, todoRepo)

	todoSvc := todo.NewService(pool, todoRepo)
	todoSvc.SetConflicter(func(ctx context.Context, userID string, start, end time.Time) (bool, error) {
		var tz string
		if err := pool.QueryRow(ctx, `SELECT timezone FROM users WHERE id=$1`, userID).Scan(&tz); err != nil {
			return false, nil
		}
		loc, err := timeutil.LoadTimezone(tz)
		if err != nil {
			loc = time.UTC
		}
		occs, err := eventSvc.CourseOccurrences(ctx, userID, start.Add(-48*time.Hour), end.Add(48*time.Hour), loc)
		if err != nil {
			return false, err
		}
		for _, o := range occs {
			if timeutil.Overlap(start, end, o.Start, o.End) {
				return true, nil
			}
		}
		return false, nil
	})

	authSvc := auth.NewService(pool, userRepo,
		auth.NewTokenService(cfg.JWTSecret, cfg.AccessTokenTTL),
		auth.NewRefreshRepo(pool, cfg.RefreshTokenTTL),
		cfg.CookieSecure())
	mcpTokenRepo := mcptoken.NewRepo(pool)
	authMw := auth.NewMiddleware(auth.NewTokenService(cfg.JWTSecret, cfg.AccessTokenTTL), userRepo, mcpTokenRepo)

	syncJournal := sync.NewJournal(pool)
	pushSvc := sync.NewPushService(pool, syncJournal)

	// Register sync adapters (shared by push and agent change sets).
	tzResolver := func(ctx context.Context, userID string) *time.Location {
		var tz string
		if err := pool.QueryRow(ctx, `SELECT timezone FROM users WHERE id=$1`, userID).Scan(&tz); err != nil {
			return time.UTC
		}
		loc, err := timeutil.LoadTimezone(tz)
		if err != nil {
			return time.UTC
		}
		return loc
	}
	pushSvc.Register(sync.EntityTodo, todo.NewTodoAdapter(pool, todoRepo))
	pushSvc.Register(sync.EntityTodoBlock, todo.NewBlockAdapter(pool, todoRepo, tzResolver))
	pushSvc.Register(sync.EntityTag, tag.NewTagAdapter(pool, tag.NewService(pool)))
	pushSvc.Register(sync.EntityCategory, category.NewCategoryAdapter(pool))
	pushSvc.Register(sync.EntityCalendar, calendar.NewCalendarAdapter(pool, calRepo))
	pushSvc.Register(sync.EntityPeriod, calendar.NewPeriodAdapter(pool, calRepo))
	pushSvc.Register(sync.EntityCourse, course.NewCourseAdapter(pool, courseRepo))
	pushSvc.Register(sync.EntityMeeting, course.NewMeetingAdapter(pool, courseRepo))
	pushSvc.Register(sync.EntityRecurring, schedule.NewRecurringAdapter(pool, schedRepo))

	seriesSvc := series.NewService(pool, calRepo, courseRepo, courseSvc, schedRepo, schedSvc, overRepo, eventSvc)

	agentSvc := agent.NewService(pool, pushSvc, eventSvc, cfg.ConfirmationTTL)
	importSvc := importcsv.NewService(pool, calRepo, courseRepo, cfg.ConfirmationTTL)
	freeSlotSvc := freeslot.NewService(pool, eventSvc, schedSvc, schedRepo, calRepo, todoRepo)

	// ---- MCP tools -------------------------------------------------------------
	toolDeps := mcp.Deps{
		Agent: agentSvc, Event: eventSvc, FreeSlot: freeSlotSvc,
		Todo: todoSvc, Courses: courseSvc, Schedule: schedSvc,
	}
	mcpServer := mcp.NewServer(mcp.BuildTools(toolDeps))

	s := &Server{
		Cfg: cfg, Pool: pool,
		AuthService: authSvc, CalendarSvc: calSvc, CourseSvc: courseSvc,
		ScheduleSvc: schedSvc, TodoSvc: todoSvc, TagSvc: tag.NewService(pool),
		CategorySvc: category.NewService(pool), EventSvc: eventSvc,
		FreeSlotSvc: freeSlotSvc, SeriesSvc: seriesSvc, AgentSvc: agentSvc,
		ImportSvc: importSvc, PushService: pushSvc, Journal: syncJournal,
		McpTokens: mcpTokenRepo,
	}

	handlers := &handlers{
		auth: authSvc, authMw: authMw,
		cal:       calendar.NewHandlers(calSvc),
		course:    course.NewHandlers(courseSvc),
		schedule:  schedule.NewHandlers(schedSvc),
		todo:      todo.NewHandlers(todoSvc),
		tag:       tag.NewHandlers(tag.NewService(pool)),
		category:  category.NewHandlers(category.NewService(pool)),
		event:     event.NewHandlers(eventSvc),
		freeslot:  freeslot.NewHandlers(freeSlotSvc),
		series:    series.NewHandlers(seriesSvc),
		syncH:     sync.NewHandlers(syncJournal, pushSvc),
		agent:     agent.NewHandlers(agentSvc),
		importcsv: importcsv.NewHandlers(importSvc),
		mcp:       mcpServer,
		mcpTokens: mcptoken.NewHandlers(mcpTokenRepo, userRepo),
		connect:   mcpconnect.NewService(userRepo, mcpTokenRepo),
	}
	s.Router = handlers.build(cfg)

	slog.Info("server wired", "modules", "auth user calendar course schedule todo tag category event freeslot series sync agent importcsv mcp mcptoken mcpconnect")
	return s, nil
}

func (s *Server) Close() {
	if s.Pool != nil {
		s.Pool.Close()
	}
}
