package tag

import (
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name  string  `json:"name"`
		Color *string `json:"color"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	t, err := h.svc.Create(r.Context(), httpx.UserID(r.Context()), "", body.Name, body.Color)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(t.DTO()))
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.List(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, t := range list {
		out = append(out, t.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Name  *string `json:"name"`
		Color *string `json:"color"`
	}
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	t, err := h.svc.Update(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "id"), body.Name, body.Color)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(t.DTO()))
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "id")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}
