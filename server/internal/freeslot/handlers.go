package freeslot

import (
	"net/http"
	"strconv"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

// FreeSlots serves GET /free-slots.
func (h *Handlers) FreeSlots(w http.ResponseWriter, r *http.Request) {
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
	duration := 60
	if v := q.Get("durationMinutes"); v != "" {
		duration, err = strconv.Atoi(v)
		if err != nil {
			httpx.WriteError(w, apperr.Validation("durationMinutes", "must be an integer"))
			return
		}
	}
	loc, err := timeutil.LoadTimezone(httpx.Timezone(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	slots, err := h.svc.Compute(r.Context(), httpx.UserID(r.Context()), Options{
		Start: start, End: end, DurationMinutes: duration,
		Alignment:          q.Get("alignment"),
		ConsiderCourses:    q.Get("considerCourses") != "false",
		ConsiderRecurring:  q.Get("considerRecurringSchedules") != "false",
		ConsiderTodoBlocks: q.Get("considerTodoBlocks") != "false",
	}, loc)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(slots))
	for _, s := range slots {
		out = append(out, s.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}
