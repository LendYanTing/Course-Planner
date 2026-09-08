package course

import (
	"encoding/json"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		CalendarID string  `json:"calendarId"`
		Name       string  `json:"name"`
		Teacher    *string `json:"teacher"`
		Location   *string `json:"location"`
		Color      *string `json:"color"`
		Notes      *string `json:"notes"`
		Meetings   []struct {
			Weekday     int             `json:"weekday"`
			PeriodStart int             `json:"periodStart"`
			PeriodEnd   int             `json:"periodEnd"`
			WeekRule    json.RawMessage `json:"weekRule"`
		} `json:"meetings"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	cmd := CreateCourseCmd{
		CalendarID: body.CalendarID, Name: body.Name,
		Teacher: body.Teacher, Location: body.Location, Color: body.Color, Notes: body.Notes,
	}
	for _, m := range body.Meetings {
		rule, err := weekrule.ParseSegments(m.WeekRule)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		cmd.Meetings = append(cmd.Meetings, CreateMeetingCmd{
			Weekday: m.Weekday, PeriodStart: m.PeriodStart, PeriodEnd: m.PeriodEnd, WeekRule: rule,
		})
	}
	c, meetings, err := h.svc.Create(r.Context(), httpx.UserID(r.Context()), cmd)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	resp := c.Snapshot()
	if len(meetings) > 0 {
		ms := make([]map[string]any, 0, len(meetings))
		for _, m := range meetings {
			ms = append(ms, m.DTO())
		}
		resp["meetings"] = ms
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(resp))
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.List(r.Context(), httpx.UserID(r.Context()), r.URL.Query().Get("calendarId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, c := range list {
		out = append(out, c.Snapshot())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	c, meetings, err := h.svc.Get(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "courseId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	resp := c.Snapshot()
	ms := make([]map[string]any, 0, len(meetings))
	for _, m := range meetings {
		ms = append(ms, m.DTO())
	}
	resp["meetings"] = ms
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(resp))
}

func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name         *string `json:"name"`
		Teacher      *string `json:"teacher"`
		Location     *string `json:"location"`
		Color        *string `json:"color"`
		Notes        *string `json:"notes"`
		BaseRevision *int64  `json:"baseRevision"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	c, err := h.svc.Update(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "courseId"), UpdateCourseCmd{
		Name: body.Name, Teacher: body.Teacher, Location: body.Location, Color: body.Color, Notes: body.Notes,
	}, derefI64(body.BaseRevision))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(c.Snapshot()))
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "courseId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- meetings ----------------------------------------------------------------

func (h *Handlers) CreateMeeting(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Weekday     int             `json:"weekday"`
		PeriodStart int             `json:"periodStart"`
		PeriodEnd   int             `json:"periodEnd"`
		WeekRule    json.RawMessage `json:"weekRule"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	rule, err := weekrule.ParseSegments(body.WeekRule)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	m, err := h.svc.CreateMeeting(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "courseId"), CreateMeetingCmd{
		Weekday: body.Weekday, PeriodStart: body.PeriodStart, PeriodEnd: body.PeriodEnd, WeekRule: rule,
	})
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(m.DTO()))
}

func (h *Handlers) ListMeetings(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.ListMeetings(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "courseId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, m := range list {
		out = append(out, m.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

// UpdateMeeting powers PATCH /courses/{courseId}/meetings/{meetingId}.
// NOTE: editing a single occurrence uses the series endpoint
// (POST /series/...), not this handler (docs/api.md §7).
func (h *Handlers) UpdateMeeting(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Weekday      *int            `json:"weekday"`
		PeriodStart  *int            `json:"periodStart"`
		PeriodEnd    *int            `json:"periodEnd"`
		WeekRule     json.RawMessage `json:"weekRule"`
		BaseRevision *int64          `json:"baseRevision"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	cmd := UpdateMeetingCmd{Weekday: body.Weekday, PeriodStart: body.PeriodStart, PeriodEnd: body.PeriodEnd}
	if len(body.WeekRule) > 0 {
		rule, err := weekrule.ParseSegments(body.WeekRule)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		cmd.WeekRule = rule
	}
	m, err := h.svc.UpdateMeeting(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "meetingId"), cmd, derefI64(body.BaseRevision))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(m.DTO()))
}

func (h *Handlers) DeleteMeeting(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeleteMeeting(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "meetingId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func derefI64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// ---- helpers reused by other modules ------------------------------------------

// ParseWeekRuleRequest is exported for handlers in other packages that need
// identical week-rule validation.
func ParseWeekRuleRequest(raw json.RawMessage) (weekrule.Rule, error) {
	if len(raw) == 0 {
		return nil, apperr.Validation("weekRule", "week rule is required")
	}
	return weekrule.ParseSegments(raw)
}
