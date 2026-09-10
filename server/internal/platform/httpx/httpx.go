// Package httpx holds shared HTTP plumbing: the response envelope from
// docs/api.md §2, error mapping, body decoding and the authenticated-user
// request context.
package httpx

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
)

const (
	maxBodyBytes = 4 << 20 // 4 MiB; CSV uploads included
	userIDKey    = contextKey("userID")
	timezoneKey  = contextKey("timezone")

	credentialKindKey = contextKey("credentialKind")
	credentialIDKey   = contextKey("credentialID")
	scopesKey         = contextKey("scopes")
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
		slog.Error("unhandled error", "error", err)
	} else if ae.Status >= 500 {
		slog.Error("request failed", "code", ae.Code, "message", ae.Message, "error", err)
	} else {
		slog.Debug("request rejected", "code", ae.Code, "message", ae.Message)
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

// Credential kinds. The distinction matters for authorization: a long-lived
// MCP credential may be read-only and may never manage credentials.
const (
	CredentialSession = "session"
	CredentialMCP     = "mcp_token"
)

// Scope names, mirroring mcptoken.Scope* without importing it.
const (
	ScopeRead  = "read"
	ScopeWrite = "write"
)

// WithCredential records how the request authenticated: which kind of token,
// its id (for auditing) and the scopes it carries. Only the auth middleware
// may call this.
func WithCredential(ctx context.Context, kind, credentialID string, scopes []string) context.Context {
	ctx = context.WithValue(ctx, credentialKindKey, kind)
	ctx = context.WithValue(ctx, credentialIDKey, credentialID)
	return context.WithValue(ctx, scopesKey, scopes)
}

// CredentialKind returns CredentialSession or CredentialMCP.
func CredentialKind(ctx context.Context) string {
	if v, ok := ctx.Value(credentialKindKey).(string); ok {
		return v
	}
	return ""
}

// CredentialID returns the MCP token id, or "" for a session token.
func CredentialID(ctx context.Context) string {
	if v, ok := ctx.Value(credentialIDKey).(string); ok {
		return v
	}
	return ""
}

// Scopes returns the granted scopes of the presented credential.
func Scopes(ctx context.Context) []string {
	if v, ok := ctx.Value(scopesKey).([]string); ok {
		return v
	}
	return nil
}

// HasScope reports whether the presented credential carries a scope.
func HasScope(ctx context.Context, scope string) bool {
	for _, s := range Scopes(ctx) {
		if s == scope {
			return true
		}
	}
	return false
}
