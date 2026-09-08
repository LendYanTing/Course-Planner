package importcsv

import (
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

// Preview handles POST /import/courses/preview (Content-Type: text/csv).
func (h *Handlers) Preview(w http.ResponseWriter, r *http.Request) {
	if ct := r.Header.Get("Content-Type"); ct != "" && ct != "text/csv" && ct != "text/plain" {
		httpx.WriteError(w, apperr.InvalidRequest("Content-Type must be text/csv"))
		return
	}
	body, err := httpx.ReadBody(r)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	calendarID := r.URL.Query().Get("calendarId")
	if calendarID == "" {
		httpx.WriteError(w, apperr.Validation("calendarId", "query parameter is required"))
		return
	}
	result, err := h.svc.Preview(r.Context(), httpx.UserID(r.Context()), calendarID, body)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(result))
}

// Commit handles POST /import/courses/commit.
func (h *Handlers) Commit(w http.ResponseWriter, r *http.Request) {
	var body struct {
		PreviewID string `json:"previewId"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	count, err := h.svc.Commit(r.Context(), httpx.UserID(r.Context()), body.PreviewID)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(map[string]any{
		"committed": true,
		"courses":   count,
	}))
}
