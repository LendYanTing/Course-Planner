package calendar

import (
	"encoding/json"
	"net/http"
	"strconv"

	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

// Handlers wires the calendar service onto chi routes.
type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name       string `json:"name"`
		FirstDay   string `json:"firstDay"`
		TotalWeeks int    `json:"totalWeeks"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	c, err := h.svc.Create(r.Context(), httpx.UserID(r.Context()), CreateCalendarCmd{
		Name: body.Name, FirstDay: body.FirstDay, TotalWeeks: body.TotalWeeks,
	})
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(c.Snapshot()))
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.List(r.Context(), httpx.UserID(r.Context()))
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
	c, err := h.svc.Get(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "calendarId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(c.Snapshot()))
}

func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name         *string `json:"name"`
		FirstDay     *string `json:"firstDay"`
		TotalWeeks   *int    `json:"totalWeeks"`
		BaseRevision *int64  `json:"baseRevision"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	c, err := h.svc.Update(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "calendarId"), UpdateCalendarCmd{
		Name: body.Name, FirstDay: body.FirstDay, TotalWeeks: body.TotalWeeks,
	}, derefInt64(body.BaseRevision))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(c.Snapshot()))
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "calendarId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- periods ---------------------------------------------------------------

func (h *Handlers) CreatePeriod(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PeriodNo   int    `json:"periodNo"`
		StartLocal string `json:"startLocal"`
		EndLocal   string `json:"endLocal"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	p, err := h.svc.CreatePeriod(r.Context(), httpx.UserID(r.Context()), CreatePeriodCmd{
		CalendarID: chi.URLParam(r, "calendarId"),
		PeriodNo:   body.PeriodNo, StartLocal: body.StartLocal, EndLocal: body.EndLocal,
	})
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(p.DTO()))
}

func (h *Handlers) ListPeriods(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.ListPeriods(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "calendarId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, p := range list {
		out = append(out, p.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

func (h *Handlers) UpdatePeriod(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PeriodNo     *int    `json:"periodNo"`
		StartLocal   *string `json:"startLocal"`
		EndLocal     *string `json:"endLocal"`
		BaseRevision *int64  `json:"baseRevision"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	p, err := h.svc.UpdatePeriod(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "periodId"), UpdatePeriodCmd{
		PeriodNo: body.PeriodNo, StartLocal: body.StartLocal, EndLocal: body.EndLocal,
	}, derefInt64(body.BaseRevision))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(p.DTO()))
}

func (h *Handlers) DeletePeriod(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeletePeriod(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "periodId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func derefInt64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}

// Pagination cursor parsing shared by list endpoints.
func QueryInt(r *http.Request, key string, def int) int {
	v := r.URL.Query().Get(key)
	if v == "" {
		return def
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return def
	}
	return n
}

// PatchFields is retained for tests that want raw JSON patches.
func PatchFields(raw json.RawMessage) map[string]any {
	var m map[string]any
	_ = json.Unmarshal(raw, &m)
	return m
}
