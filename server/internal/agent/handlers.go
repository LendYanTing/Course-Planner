package agent

import (
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

// Handlers exposes the agent change-set endpoints (docs/openapi.yaml
// /agent/changes/*). These are the HTTP face of the MCP write workflow.
type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

func (h *Handlers) Preview(w http.ResponseWriter, r *http.Request) {
	var cs ChangeSet
	if err := httpx.DecodeJSON(r, &cs, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	preview, err := h.svc.Preview(r.Context(), httpx.UserID(r.Context()), cs)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(preview))
}

func (h *Handlers) Apply(w http.ResponseWriter, r *http.Request) {
	var body struct {
		ConfirmationID string `json:"confirmationId"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	effects, err := h.svc.Apply(r.Context(), httpx.UserID(r.Context()), body.ConfirmationID)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(map[string]any{
		"applied": true,
		"changes": effects,
	}))
}
