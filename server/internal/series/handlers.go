package series

import (
	"encoding/json"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/common/weekrule"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/go-chi/chi/v5"
)

type Handlers struct{ svc *Service }

func NewHandlers(svc *Service) *Handlers { return &Handlers{svc: svc} }

// Apply serves POST /series/{seriesType}/{seriesId}/apply.
func (h *Handlers) Apply(w http.ResponseWriter, r *http.Request) {
	seriesType := chi.URLParam(r, "seriesType")
	seriesID := chi.URLParam(r, "seriesId")

	var body struct {
		Scope               string          `json:"scope"`
		OccurrenceDateLocal string          `json:"occurrenceDateLocal"`
		Operation           json.RawMessage `json:"operation"`
	}
	if err := httpx.DecodeJSON(r, &body, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	req := Request{
		SeriesType:          seriesType,
		SeriesID:            seriesID,
		Scope:               body.Scope,
		OccurrenceDateLocal: body.OccurrenceDateLocal,
	}
	op, err := decodeOperation(body.Operation)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	req.Operation = op

	loc, err := timeutil.LoadTimezone(httpx.Timezone(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	result, err := h.svc.Apply(r.Context(), httpx.UserID(r.Context()), req, loc)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	resp := map[string]any{
		"kind":        result.Kind,
		"oldSeriesId": result.OldSeriesID,
		"newSeriesId": result.NewSeriesID,
	}
	if result.Override != nil {
		resp["override"] = result.Override.Snapshot()
	} else {
		resp["override"] = nil
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(resp))
}

func decodeOperation(raw json.RawMessage) (Operation, error) {
	var wire struct {
		Type        string          `json:"type"`
		StartAt     *string         `json:"startAt"`
		EndAt       *string         `json:"endAt"`
		StartLocal  *string         `json:"startLocal"`
		EndLocal    *string         `json:"endLocal"`
		PeriodStart *int            `json:"periodStart"`
		PeriodEnd   *int            `json:"periodEnd"`
		Weekday     *int            `json:"weekday"`
		WeekRule    json.RawMessage `json:"weekRule"`
		Patch       map[string]any  `json:"patch"`
		Force       bool            `json:"force"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil {
		return Operation{}, apperr.InvalidRequest("invalid operation object")
	}
	op := Operation{
		Type:        wire.Type,
		StartLocal:  wire.StartLocal,
		EndLocal:    wire.EndLocal,
		PeriodStart: wire.PeriodStart,
		PeriodEnd:   wire.PeriodEnd,
		Weekday:     wire.Weekday,
		Patch:       wire.Patch,
		Force:       wire.Force,
	}
	if len(wire.WeekRule) > 0 {
		rule, err := weekrule.ParseSegments(wire.WeekRule)
		if err != nil {
			return op, err
		}
		op.WeekRule = rule
		op.HasWeekRule = true
	}
	if wire.StartAt != nil {
		t, err2 := timeutil.ParseInstant(*wire.StartAt)
		if err2 != nil {
			return op, err2
		}
		op.StartAt = &t
	}
	if wire.EndAt != nil {
		t, err2 := timeutil.ParseInstant(*wire.EndAt)
		if err2 != nil {
			return op, err2
		}
		op.EndAt = &t
	}
	return op, nil
}
