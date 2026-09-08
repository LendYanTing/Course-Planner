package auth

import (
	"net/http"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/user"
)

// Middleware verifies Bearer access tokens and enriches the request context
// with the authenticated user (id + immutable timezone), loaded fresh from
// the database so the timezone is always authoritative.
type Middleware struct {
	tokens *TokenService
	users  *user.Repo
}

func NewMiddleware(tokens *TokenService, users *user.Repo) *Middleware {
	return &Middleware{tokens: tokens, users: users}
}

func (m *Middleware) Handler(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		header := r.Header.Get("Authorization")
		if !strings.HasPrefix(header, "Bearer ") {
			httpx.WriteError(w, apperr.Unauthorized("missing bearer token"))
			return
		}
		token := strings.TrimSpace(strings.TrimPrefix(header, "Bearer "))
		userID, err := m.tokens.VerifyAccessToken(token)
		if err != nil {
			httpx.WriteError(w, err)
			return
		}
		u, err := m.users.ByID(r.Context(), userID)
		if err != nil {
			httpx.WriteError(w, apperr.Unauthorized("user no longer exists"))
			return
		}
		ctx := httpx.WithAuth(r.Context(), u.ID, u.Timezone)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
