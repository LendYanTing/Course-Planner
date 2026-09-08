package event

import (
	"net/http"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

// Events serves GET /calendar/events.
func (h *Handlers) Events(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	startStr := q.Get("start")
	endStr := q.Get("end")
	if startStr == "" || endStr == "" {
		httpx.WriteError(w, apperr.Validation("range", "start and end query parameters are required (UTC RFC3339)"))
		return
	}
	start, err := timeutil.ParseInstant(startStr)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	end, err := timeutil.ParseInstant(endStr)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	if !end.After(start) {
		httpx.WriteError(w, apperr.Validation("end", "must be after start"))
		return
	}
	if end.Sub(start) > 62*24*time.Hour {
		httpx.WriteError(w, apperr.Validation("range", "must not exceed 62 days"))
		return
	}
	loc, err := timeutil.LoadTimezone(httpx.Timezone(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	opts := IncludeOptions{
		Courses:            q.Get("includeCourses") != "false",
		RecurringSchedules: q.Get("includeRecurringSchedules") != "false",
		TodoBlocks:         q.Get("includeTodoBlocks") != "false",
		Deadlines:          q.Get("includeDeadlines") != "false",
	}
	events, err := h.svc.Events(r.Context(), httpx.UserID(r.Context()), start, end, loc, opts)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(events))
	for _, e := range events {
		out = append(out, e.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}
