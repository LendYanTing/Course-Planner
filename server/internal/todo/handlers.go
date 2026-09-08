package todo

import (
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

type Handlers struct {
	svc  *Service
	tzOf func(r *http.Request) *time.Location
}

func NewHandlers(svc *Service) *Handlers {
	return &Handlers{svc: svc, tzOf: requestTimezone}
}

// requestTimezone resolves the user's immutable timezone (set by the auth
// middleware) with a safe fallback.
func requestTimezone(r *http.Request) *time.Location {
	loc, err := timeutil.LoadTimezone(httpx.Timezone(r.Context()))
	if err != nil {
		return time.UTC
	}
	return loc
}

// ---- todos --------------------------------------------------------------------

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Title            string   `json:"title"`
		Type             string   `json:"type"`
		Description      *string  `json:"description"`
		CategoryID       *string  `json:"categoryId"`
		TagIDs           []string `json:"tagIds"`
		Priority         string   `json:"priority"`
		Status           string   `json:"status"`
		EstimatedMinutes *int     `json:"estimatedMinutes"`
		Color            *string  `json:"color"`
		DeadlineAt       *string  `json:"deadlineAt"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	cmd := CreateCmd{
		Title: body.Title, Type: body.Type, Description: body.Description,
		CategoryID: body.CategoryID, TagIDs: body.TagIDs,
		Priority: body.Priority, Status: body.Status,
		EstimatedMinutes: body.EstimatedMinutes, Color: body.Color,
	}
	if body.DeadlineAt != nil && *body.DeadlineAt != "" {
		dl, err := timeutil.ParseInstant(*body.DeadlineAt)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		cmd.DeadlineAt = &dl
	}
	t, err := h.svc.Create(r.Context(), httpx.UserID(r.Context()), cmd)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(t.DTO()))
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	filter := ListFilter{
		Status:     q.Get("status"),
		CategoryID: q.Get("categoryId"),
		Type:       q.Get("type"),
	}
	if tagIDs := q.Get("tagIds"); tagIDs != "" {
		filter.TagIDs = strings.Split(tagIDs, ",")
	}
	list, err := h.svc.List(r.Context(), httpx.UserID(r.Context()), filter)
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

func (h *Handlers) Get(w http.ResponseWriter, r *http.Request) {
	t, err := h.svc.Get(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "todoId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(t.DTO()))
}

func (h *Handlers) Update(w http.ResponseWriter, r *http.Request) {
	var body map[string]json.RawMessage
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	upd, err := decodeTodoUpdate(body)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	t, err := h.svc.Update(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "todoId"), upd, decodeBaseRevision(body))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(t.DTO()))
}

func (h *Handlers) Delete(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.Delete(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "todoId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- blocks ---------------------------------------------------------------------

func (h *Handlers) CreateBlock(w http.ResponseWriter, r *http.Request) {
	var body struct {
		StartAt   string  `json:"startAt"`
		EndAt     string  `json:"endAt"`
		BlockNote *string `json:"blockNote"`
		Status    string  `json:"status"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	start, err := timeutil.ParseInstant(body.StartAt)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	end, err := timeutil.ParseInstant(body.EndAt)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	res, err := h.svc.CreateBlock(r.Context(), httpx.UserID(r.Context()), CreateBlockCmd{
		TodoID: chi.URLParam(r, "todoId"), StartAt: start, EndAt: end,
		BlockNote: body.BlockNote, Status: body.Status,
	}, h.tzOf(r))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	resp := res.Block.DTO()
	resp["conflictState"] = res.ConflictState
	httpx.WriteJSON(w, http.StatusCreated, httpx.Data(resp))
}

func (h *Handlers) ListBlocks(w http.ResponseWriter, r *http.Request) {
	list, err := h.svc.ListBlocks(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "todoId"))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, b := range list {
		out = append(out, b.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(out))
}

func (h *Handlers) UpdateBlock(w http.ResponseWriter, r *http.Request) {
	var body map[string]json.RawMessage
	if err := httpx.DecodeJSON(r, &body, true); err != nil {
		httpx.WriteError(w, err)
		return
	}
	upd, err := decodeBlockUpdate(body)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	res, err := h.svc.UpdateBlock(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "blockId"), upd, decodeBaseRevision(body), h.tzOf(r))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	resp := res.Block.DTO()
	resp["conflictState"] = res.ConflictState
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(resp))
}

func (h *Handlers) DeleteBlock(w http.ResponseWriter, r *http.Request) {
	if err := h.svc.DeleteBlock(r.Context(), httpx.UserID(r.Context()), chi.URLParam(r, "blockId")); err != nil {
		httpx.WriteError(w, err)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// ---- patch decoders ------------------------------------------------------------

func decodeBaseRevision(body map[string]json.RawMessage) int64 {
	var v int64
	if raw, ok := body["baseRevision"]; ok {
		_ = json.Unmarshal(raw, &v)
	}
	return v
}

func decodeStringPtr(body map[string]json.RawMessage, key string) (*string, error) {
	raw, ok := body[key]
	if !ok {
		return nil, nil
	}
	var v *string
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, apperr.Validation(key, "must be a string or null")
	}
	return v, nil
}

func decodeIntPtr(body map[string]json.RawMessage, key string) (*int, error) {
	raw, ok := body[key]
	if !ok {
		return nil, nil
	}
	var v *int
	if err := json.Unmarshal(raw, &v); err != nil {
		return nil, apperr.Validation(key, "must be an integer or null")
	}
	return v, nil
}

func decodeTodoUpdate(body map[string]json.RawMessage) (UpdateCmd, error) {
	upd := UpdateCmd{}
	var err error
	if upd.Title, err = decodeStringPtr(body, "title"); err != nil {
		return upd, err
	}
	if upd.Description, err = decodeStringPtr(body, "description"); err != nil {
		return upd, err
	}
	if upd.CategoryID, err = decodeStringPtr(body, "categoryId"); err != nil {
		return upd, err
	}
	if upd.Priority, err = decodeStringPtr(body, "priority"); err != nil {
		return upd, err
	}
	if upd.Status, err = decodeStringPtr(body, "status"); err != nil {
		return upd, err
	}
	if upd.Color, err = decodeStringPtr(body, "color"); err != nil {
		return upd, err
	}
	if upd.EstimatedMinutes, err = decodeIntPtr(body, "estimatedMinutes"); err != nil {
		return upd, err
	}
	if upd.Type, err = decodeStringPtr(body, "type"); err != nil {
		return upd, err
	}
	if raw, ok := body["tagIds"]; ok {
		upd.HasTagIDs = true
		if string(raw) == "null" {
			upd.TagIDs = []string{}
		} else if err := json.Unmarshal(raw, &upd.TagIDs); err != nil {
			return upd, apperr.Validation("tagIds", "must be an array of ids")
		}
	}
	if raw, ok := body["deadlineAt"]; ok {
		upd.HasDeadline = true
		if string(raw) == "null" {
			upd.DeadlineAt = nil
		} else {
			var s string
			if err := json.Unmarshal(raw, &s); err != nil {
				return upd, apperr.Validation("deadlineAt", "must be an RFC3339 datetime or null")
			}
			dl, err := timeutil.ParseInstant(s)
			if err != nil {
				return upd, err
			}
			upd.DeadlineAt = &dl
		}
	}
	return upd, nil
}

func decodeBlockUpdate(body map[string]json.RawMessage) (UpdateBlockCmd, error) {
	upd := UpdateBlockCmd{}
	var err error
	if upd.BlockNote, err = decodeStringPtr(body, "blockNote"); err != nil {
		return upd, err
	}
	if upd.Status, err = decodeStringPtr(body, "status"); err != nil {
		return upd, err
	}
	if raw, ok := body["startAt"]; ok && string(raw) != "null" {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return upd, apperr.Validation("startAt", "must be an RFC3339 datetime")
		}
		t, err := timeutil.ParseInstant(s)
		if err != nil {
			return upd, err
		}
		upd.StartAt = &t
	}
	if raw, ok := body["endAt"]; ok && string(raw) != "null" {
		var s string
		if err := json.Unmarshal(raw, &s); err != nil {
			return upd, apperr.Validation("endAt", "must be an RFC3339 datetime")
		}
		t, err := timeutil.ParseInstant(s)
		if err != nil {
			return upd, err
		}
		upd.EndAt = &t
	}
	return upd, nil
}
