package app

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/carryingon/courseplanner/server/internal/agent"
	"github.com/carryingon/courseplanner/server/internal/auth"
	"github.com/carryingon/courseplanner/server/internal/calendar"
	"github.com/carryingon/courseplanner/server/internal/category"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/freeslot"
	"github.com/carryingon/courseplanner/server/internal/importcsv"
	"github.com/carryingon/courseplanner/server/internal/mcp"
	"github.com/carryingon/courseplanner/server/internal/mcpconnect"
	"github.com/carryingon/courseplanner/server/internal/mcptoken"
	"github.com/carryingon/courseplanner/server/internal/platform/config"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/series"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/carryingon/courseplanner/server/internal/tag"
	"github.com/carryingon/courseplanner/server/internal/todo"
	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
	"github.com/go-chi/cors"
)

// handlers bundles every HTTP handler set for route mounting.
type handlers struct {
	auth      *auth.Service
	authMw    *auth.Middleware
	cal       *calendar.Handlers
	course    *course.Handlers
	schedule  *schedule.Handlers
	todo      *todo.Handlers
	tag       *tag.Handlers
	category  *category.Handlers
	event     *event.Handlers
	freeslot  *freeslot.Handlers
	series    *series.Handlers
	syncH     *sync.Handlers
	agent     *agent.Handlers
	importcsv *importcsv.Handlers
	mcp       *mcp.Server
	mcpTokens *mcptoken.Handlers
	connect   *mcpconnect.Service
}

// build assembles the chi router. Base URL prefix is /api/v1 (docs/api.md).
func (h *handlers) build(cfg *config.Config) http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.Recoverer)
	r.Use(requestLogger)
	r.Use(middleware.Timeout(90 * time.Second))

	if len(cfg.CORSAllowedOrigins) > 0 {
		r.Use(cors.Handler(cors.Options{
			AllowedOrigins:   cfg.CORSAllowedOrigins,
			AllowedMethods:   []string{"GET", "POST", "PATCH", "DELETE", "OPTIONS"},
			AllowedHeaders:   []string{"Content-Type", "Authorization", "Idempotency-Key"},
			AllowCredentials: true,
			MaxAge:           600,
		}))
	}

	r.Get("/healthz", func(w http.ResponseWriter, r *http.Request) {
		httpx.WriteJSON(w, http.StatusOK, map[string]any{"status": "ok", "time": time.Now().UTC().Format(time.RFC3339)})
	})

	// Browser-facing: sign in and receive a long-lived MCP token. Outside
	// /api/v1 on purpose — it renders HTML for people, not JSON for clients
	// (docs/mcp.md §11).
	r.Get("/mcp/connect", h.connect.Page)
	r.Post("/mcp/connect", h.connect.Submit)

	r.Route("/api/v1", func(api chi.Router) {
		// Public.
		api.Route("/auth", func(authR chi.Router) {
			authR.Post("/register", h.auth.Register)
			authR.Post("/login", h.auth.Login)
			authR.Post("/refresh", h.auth.Refresh)
			authR.Post("/logout", h.auth.Logout)
		})
		api.Get("/meta/time", func(w http.ResponseWriter, r *http.Request) {
			httpx.WriteJSON(w, http.StatusOK, httpx.Data(map[string]any{
				"serverTimeUtc": time.Now().UTC().Format(time.RFC3339),
			}))
		})

		// Authenticated.
		api.Group(func(priv chi.Router) {
			priv.Use(h.authMw.Handler)
			// Read-only MCP credentials must not reach write paths.
			priv.Use(auth.RequireWriteScope)

			// MCP streamable HTTP (user-authenticated; read tools need no
			// confirmation, writes gate through preview/apply).
			priv.Handle("/mcp", h.mcp)

			priv.Get("/me", h.auth.Me)

			// Long-lived MCP credentials, managed with a session token only.
			priv.Route("/mcp-tokens", func(mt chi.Router) {
				mt.Get("/", h.mcpTokens.List)
				mt.Post("/", h.mcpTokens.Create)
				mt.Delete("/{tokenId}", h.mcpTokens.Revoke)
			})

			priv.Route("/calendars", func(c chi.Router) {
				c.Get("/", h.cal.List)
				c.Post("/", h.cal.Create)
				c.Route("/{calendarId}", func(cal chi.Router) {
					cal.Get("/", h.cal.Get)
					cal.Patch("/", h.cal.Update)
					cal.Delete("/", h.cal.Delete)
					cal.Route("/periods", func(p chi.Router) {
						p.Get("/", h.cal.ListPeriods)
						p.Post("/", h.cal.CreatePeriod)
						p.Route("/{periodId}", func(pe chi.Router) {
							pe.Patch("/", h.cal.UpdatePeriod)
							pe.Delete("/", h.cal.DeletePeriod)
						})
					})
				})
			})

			priv.Route("/courses", func(c chi.Router) {
				c.Get("/", h.course.List)
				c.Post("/", h.course.Create)
				c.Route("/{courseId}", func(co chi.Router) {
					co.Get("/", h.course.Get)
					co.Patch("/", h.course.Update)
					co.Delete("/", h.course.Delete)
					co.Route("/meetings", func(m chi.Router) {
						m.Get("/", h.course.ListMeetings)
						m.Post("/", h.course.CreateMeeting)
						m.Route("/{meetingId}", func(me chi.Router) {
							me.Patch("/", h.course.UpdateMeeting)
							me.Delete("/", h.course.DeleteMeeting)
						})
					})
				})
			})

			priv.Route("/recurring-schedules", func(rs chi.Router) {
				rs.Get("/", h.schedule.List)
				rs.Post("/", h.schedule.Create)
				rs.Route("/{scheduleId}", func(r chi.Router) {
					r.Get("/", h.schedule.Get)
					r.Patch("/", h.schedule.Update)
					r.Delete("/", h.schedule.Delete)
				})
			})

			priv.Route("/todos", func(t chi.Router) {
				t.Get("/", h.todo.List)
				t.Post("/", h.todo.Create)
				t.Route("/{todoId}", func(te chi.Router) {
					te.Get("/", h.todo.Get)
					te.Patch("/", h.todo.Update)
					te.Delete("/", h.todo.Delete)
					te.Route("/blocks", func(b chi.Router) {
						b.Get("/", h.todo.ListBlocks)
						b.Post("/", h.todo.CreateBlock)
					})
				})
			})
			priv.Route("/todo-blocks", func(b chi.Router) {
				b.Route("/{blockId}", func(be chi.Router) {
					be.Patch("/", h.todo.UpdateBlock)
					be.Delete("/", h.todo.DeleteBlock)
				})
			})

			priv.Route("/tags", func(t chi.Router) {
				t.Get("/", h.tag.List)
				t.Post("/", h.tag.Create)
				t.Route("/{id}", func(te chi.Router) {
					te.Patch("/", h.tag.Update)
					te.Delete("/", h.tag.Delete)
				})
			})
			priv.Route("/todo-categories", func(c chi.Router) {
				c.Get("/", h.category.List)
				c.Post("/", h.category.Create)
				c.Route("/{id}", func(ce chi.Router) {
					ce.Patch("/", h.category.Update)
					ce.Delete("/", h.category.Delete)
				})
			})

			priv.Get("/calendar/events", h.event.Events)
			priv.Get("/free-slots", h.freeslot.FreeSlots)

			priv.Post("/series/{seriesType}/{seriesId}/apply", h.series.Apply)

			priv.Route("/sync", func(s chi.Router) {
				s.Get("/state", h.syncH.State)
				s.Get("/changes", h.syncH.Changes)
				s.Post("/push", h.syncH.Push)
			})

			priv.Route("/agent/changes", func(a chi.Router) {
				a.Post("/preview", h.agent.Preview)
				a.Post("/apply", h.agent.Apply)
			})

			priv.Route("/import/courses", func(i chi.Router) {
				i.Post("/preview", h.importcsv.Preview)
				i.Post("/commit", h.importcsv.Commit)
			})
		})
	})

	return r
}

// requestLogger logs method, path, status and duration at debug level.
func requestLogger(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		ww := middleware.NewWrapResponseWriter(w, r.ProtoMajor)
		next.ServeHTTP(ww, r)
		slog.Debug("http",
			"method", r.Method,
			"path", r.URL.Path,
			"status", ww.Status(),
			"bytes", ww.BytesWritten(),
			"duration_ms", time.Since(start).Milliseconds(),
		)
	})
}
