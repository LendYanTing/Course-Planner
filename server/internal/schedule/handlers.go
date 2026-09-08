package schedule

import (
	"encoding/json"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title string          `json:"title"`
		Color *string         `json:"color"`
		Rule  json.RawMessage `json:"rule"`
		Notes *string         `json:"notes"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	rule, err := decodeRule(body.Rule)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	rs, err := h.svc.Create(r.Context(), httpx.UserID(r.Context()), CreateCmd{
		Title: body.Title, Color: body.Color, Rule: rule, Notes: body.Notes,
	})
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(rs.DTO()))
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.List(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, rs := range list {
		out = append(out, rs.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	rs, err := h.svc.Get(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "scheduleId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(rs.DTO()))
}

func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title        *string         `json:"title"`
		Color        *string         `json:"color"`
		Rule         json.RawMessage `json:"rule"`
		Notes        *string         `json:"notes"`
		BaseRevision *int64          `json:"baseRevision"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	cmd := UpdateCmd{Title: body.Title, Color: body.Color, Notes: body.Notes}
	if len(body.Rule) > 0 {
		rule, err := decodeRule(body.Rule)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		cmd.Rule = &rule
	}
	rs, err := h.svc.Update(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "scheduleId"), cmd, derefI64(body.BaseRevision))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(rs.DTO()))
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "scheduleId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// decodeRule parses and shape-validates a rule payload.
func decodeRule(raw json.RawMessage) (Rule, error) {
	var rule Rule
	if len(raw) == 0 {
		return rule, errRuleRequired()
	}
	if err := json.Unmarshal(raw, &rule); err != nil {
		return rule, errRuleInvalid()
	}
	return rule, nil
}

func derefI64(p *int64) int64 {
	if p == nil {
		return 0
	}
	return *p
}
