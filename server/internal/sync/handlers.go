package sync

import (
	"net/http"
	"strconv"

	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

// Handlers exposes the sync REST endpoints (docs/api.md §15).
type Handlers struct {
	journal *Journal
	push    *PushService
}

func NewHandlers(journal *Journal, push *PushService) *Handlers {
	return &Handlers{journal: journal, push: push}
}

// State returns the per-user server cursor.
func (h *Handlers) State(w http.ResponseWriter, r *http.Request) {
	cursor, err := h.journal.CurrentCursor(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(State{ServerCursor: cursor}))
}

// Changes returns journal entries after a cursor.
func (h *Handlers) Changes(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	after, err := strconv.ParseInt(q.Get("after"), 10, 64)
	if err != nil || after < 0 {
		httpx.WriteError(w, errBadAfter())
		return
	}
	limit := 500
	if v := q.Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 1000 {
			limit = n
		}
	}
	changes, nextCursor, hasMore, err := h.journal.ChangesSince(r.Context(), httpx.UserID(r.Context()), after, limit)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	if changes == nil {
		changes = []Change{}
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(map[string]any{
		"changes":    changes,
		"nextCursor": nextCursor,
		"hasMore":    hasMore,
	}))
}

// Push applies idempotent client operations with three-way merge.
func (h *Handlers) Push(w http.ResponseWriter, r *http.Request) {
	var req PushRequest
	if err := httpx.DecodeJSON(r, &req, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if len(req.Operations) > 1000 {
		httpx.WriteError(w, errTooManyOperations())
		return
	}
	resp, err := h.push.Push(r.Context(), httpx.UserID(r.Context()), req)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(resp))
}
