package mcptoken

import (
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/user"
	"github.com/go-chi/chi/v5"
)

// Handlers exposes credential management over REST (docs/api.md §18). These
// endpoints are session-only: a token must not be able to mint or revoke
// credentials, otherwise a leaked read-only token could bootstrap a writable
// one.
type Handlers struct {
	tokens *Repo
	users  *user.Repo
}

func NewHandlers(tokens *Repo, users *user.Repo) *Handlers {
	return &Handlers{tokens: tokens, users: users}
}

type createRequest struct {
	Name          string   `json:"name"`
	Scopes        []string `json:"scopes"`
	ExpiresInDays int      `json:"expiresInDays"`
}

func (h *Handlers) List(w http.ResponseWriter, r *http.Request) {
	list, err := h.tokens.List(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	out := make([]map[string]any, 0, len(list))
	for _, t := range list {
		out = append(out, t.DTO())
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.DataList(out))
}

func (h *Handlers) Create(w http.ResponseWriter, r *http.Request) {
	if err := h.requireSession(r); err != nil {
		httpx.WriteError(w, err)
		return
	}
	var req createRequest
	if err := httpx.DecodeJSON(r, &req, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	userID := httpx.UserID(r.Context())
	token, secret, err := h.tokens.Create(r.Context(), userID, req.Name, req.Scopes, req.ExpiresInDays)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	h.users.RecordAuthEvent(r.Context(), userID, "", "mcp_token_created", token.TokenPrefix)
	body := token.DTO()
	body["token"] = secret
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(body))
}

func (h *Handlers) Revoke(w http.ResponseWriter, r *http.Request) {
	if err := h.requireSession(r); err != nil {
		httpx.WriteError(w, err)
		return
	}
	tokenID := chi.URLParam(r, "tokenId")
	if err := h.tokens.Revoke(r.Context(), httpx.UserID(r.Context()), tokenID); err != nil {
		httpx.WriteError(w, err)
		return
	}
	h.users.RecordAuthEvent(r.Context(), httpx.UserID(r.Context()), "", "mcp_token_revoked", tokenID)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handlers) requireSession(r *http.Request) error {
	if httpx.CredentialKind(r.Context()) == httpx.CredentialSession {
		return nil
	}
	userID := httpx.UserID(r.Context())
	h.users.RecordAuthEvent(r.Context(), userID, "", "denied", "mcp credential attempted to manage mcp credentials")
	return apperr.Forbidden("MCP credentials cannot manage MCP credentials; sign in for a session token")
}
