package auth

import (
	"net/http"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/mcptoken"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/user"
)

// Middleware verifies Bearer credentials and enriches the request context with
// the authenticated user (id + immutable timezone), loaded fresh from the
// database so the timezone is always authoritative.
//
// Two credential kinds are accepted (docs/mcp.md §10): a short-lived session
// access token (JWT) and a long-lived `cpmcp_` MCP token. They are
// distinguished by prefix and recorded as distinct credential kinds so the
// write guard and the credential endpoints can tell them apart.
type Middleware struct {
	tokens    *TokenService
	users     *user.Repo
	mcpTokens *mcptoken.Repo
}

func NewMiddleware(tokens *TokenService, users *user.Repo, mcpTokens *mcptoken.Repo) *Middleware {
	return &Middleware{tokens: tokens, users: users, mcpTokens: mcpTokens}
}

func (m *Middleware) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			httpx.WriteError(w, apperr.Unauthorized("missing bearer token"))
			return
		}
		presented := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))

		var (
			userID string
			kind   string
			credID string
			scopes []string
		)
		if mcptoken.LookLike(presented) {
			if m.mcpTokens == nil {
				httpx.WriteError(w, apperr.Unauthorized("MCP tokens are not enabled on this server"))
				return
			}
			cred, err := m.mcpTokens.Verify(r.Context(), presented)
			if err != nil {
				httpx.WriteError(w, err)
				return
			}
			userID, kind, credID, scopes = cred.UserID, httpx.CredentialMCP, cred.TokenID, cred.Scopes
		} else {
			id, err := m.tokens.VerifyAccessToken(presented)
			if err != nil {
				httpx.WriteError(w, err)
				return
			}
			userID, kind, scopes = id, httpx.CredentialSession, []string{httpx.ScopeRead, httpx.ScopeWrite}
		}

		u, err := m.users.ByID(r.Context(), userID)
		if err != nil {
			httpx.WriteError(w, apperr.Unauthorized("user no longer exists"))
			return
		}
		ctx := httpx.WithAuth(r.Context(), u.ID, u.Timezone)
		ctx = httpx.WithCredential(ctx, kind, credID, scopes)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// RequireWriteScope rejects write requests carrying a read-only credential.
//
// The MCP endpoint is exempt: every MCP call is a POST, and read-only tools
// must keep working. Tool-level enforcement happens inside internal/mcp, so a
// read-only token can still run get_* and search_* there but nothing else.
func RequireWriteScope(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if httpx.HasScope(r.Context(), httpx.ScopeWrite) || !isWriteMethod(r.Method) || isMCPPath(r.URL.Path) {
			next.ServeHTTP(w, r)
			return
		}
		httpx.WriteError(w, apperr.Forbidden("this credential is read-only"))
	})
}

func isWriteMethod(method string) bool {
	switch method {
	case http.MethodGet, http.MethodHead, http.MethodOptions:
		return false
	default:
		return true
	}
}

func isMCPPath(path string) bool {
	return strings.HasSuffix(strings.TrimRight(path, "/"), "/mcp")
}
