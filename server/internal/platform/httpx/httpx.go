// Package httpx holds shared HTTP plumbing: the response envelope from
// docs/api.md §2, error mapping, body decoding and the authenticated-user
// request context.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
)

const (
	maxBodyBytes = 4 << 20 // 4 MiB; CSV uploads included
	userIDKey    = contextKey("userID")
	timezoneKey  = contextKey("timezone")
)

type contextKey string

// ErrorBody matches docs/api.md §2 error envelope.
type ErrorBody struct {
	Error ErrorDetail `json:"error"`
}

type ErrorDetail struct {
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

// WriteJSON writes a 2xx JSON payload (the caller passes the full envelope).
func WriteJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	if v != nil {
		_ = json.NewEncoder(w).Encode(v)
	}
}

// Data wraps a payload into {"data": ...}.
func Data(v any) map[string]any { return map[string]any{"data": v} }

// DataList wraps a list payload into {"data": [...]}.
func DataList(v any) map[string]any { return Data(v) }

// WriteError maps any error to the HTTP error envelope.
func WriteError(w http.ResponseWriter, err error) {
	var ae *apperr.Error
	if !errors.As(err, &ae) {
		ae = &apperr.Error{Status: http.StatusInternalServerError, Code: apperr.CodeInternal, Message: "internal server error"}
	}
	body := ErrorBody{Error: ErrorDetail{Code: ae.Code, Message: ae.Message, Details: ae.Details}}
	WriteJSON(w, ae.Status, body)
}

// DecodeJSON decodes the request body into dst with a size limit. Empty bodies
// are rejected with INVALID_REQUEST unless allowEmpty.
func DecodeJSON(r *http.Request, dst any, allowEmpty bool) error {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		return apperr.InvalidRequest("cannot read request body")
	}
	if len(body) > maxBodyBytes {
		return apperr.InvalidRequest("request body too large")
	}
	if len(body) == 0 {
		if allowEmpty {
			return nil
		}
		return apperr.InvalidRequest("request body is required")
	}
	if err := json.Unmarshal(body, dst); err != nil {
		return apperr.InvalidRequest("invalid JSON body: " + err.Error())
	}
	return nil
}

// ReadBody reads the raw body (CSV upload support) with the same size limit.
func ReadBody(r *http.Request) ([]byte, error) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes+1))
	if err != nil {
		return nil, apperr.InvalidRequest("cannot read request body")
	}
	if len(body) > maxBodyBytes {
		return nil, apperr.InvalidRequest("request body too large")
	}
	return body, nil
}

// WithAuth attaches the authenticated user (id + immutable timezone) to the
// request context. Only the auth middleware may call this.
func WithAuth(ctx context.Context, userID string, timezone string) context.Context {
	ctx = context.WithValue(ctx, userIDKey, userID)
	return context.WithValue(ctx, timezoneKey, timezone)
}

// UserID returns the authenticated user id from the context.
func UserID(ctx context.Context) string {
	if v, ok := ctx.Value(userIDKey).(string); ok {
		return v
	}
	return ""
}

// Timezone returns the authenticated user's timezone from the context.
func Timezone(ctx context.Context) string {
	if v, ok := ctx.Value(timezoneKey).(string); ok {
		return v
	}
	return ""
}
