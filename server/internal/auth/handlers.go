package auth

import (
	"context"
	"net/http"
	"strings"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
	"github.com/carryingon/courseplanner/server/internal/user"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

const RefreshCookie = "cp_refresh_token"

// Service implements the auth flows. It is shared by REST handlers and any
// future programmatic entry points.
type Service struct {
	pool         *pgxpool.Pool
	users        *user.Repo
	tokens       *TokenService
	refresh      *RefreshRepo
	cookieSecure bool
}

func NewService(pool *pgxpool.Pool, users *user.Repo, tokens *TokenService, refresh *RefreshRepo, cookieSecure bool) *Service {
	return &Service{pool: pool, users: users, tokens: tokens, refresh: refresh, cookieSecure: cookieSecure}
}

type registerRequest struct {
	Username string  `json:"username"`
	Email    *string `json:"email"`
	Password string  `json:"password"`
	Timezone string  `json:"timezone"`
}

type loginRequest struct {
	Username string `json:"username"`
	Password string `json:"password"`
}

type refreshRequest struct {
	RefreshToken string `json:"refreshToken"`
}

type logoutRequest struct {
	RefreshToken string `json:"refreshToken"`
}

// Register creates the account. The timezone is validated and then locked
// forever (docs/datetime.md §2).
func (s *Service) Register(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if err := httpx.DecodeJSON(r, &req, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if err := ValidateUsername(req.Username); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if err := ValidatePasswordPolicy(req.Password); err != nil {
		httpx.WriteError(w, err)
		return
	}
	if req.Email != nil && *req.Email != "" {
		if !strings.Contains(*req.Email, "@") || len(*req.Email) > 254 {
			httpx.WriteError(w, apperr.Validation("email", "must be a valid email address"))
			return
		}
	} else {
		req.Email = nil
	}
	loc, err := timeutil.LoadTimezone(req.Timezone)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	_ = loc // validated only; the string is stored as-is

	if existing, err := s.users.ByUsername(r.Context(), req.Username); err == nil && existing.ID != "" {
		httpx.WriteError(w, apperr.New(http.StatusConflict, apperr.CodeValidationError, "username already taken").
			WithDetail("fields", map[string]string{"username": "already taken"}))
		return
	} else if _, ok := apperr.From(err); !ok && err != nil {
		httpx.WriteError(w, err)
		return
	}

	hash, err := HashPassword(req.Password)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	u := user.User{
		ID:           uuid.NewString(),
		Username:     req.Username,
		Email:        req.Email,
		PasswordHash: hash,
		Timezone:     req.Timezone,
	}
	if err := database.WithTx(r.Context(), s.pool, func(ctx context.Context, tx pgx.Tx) error {
		return s.users.Create(ctx, tx, &u)
	}); err != nil {
		if strings.Contains(err.Error(), "duplicate key") {
			httpx.WriteError(w, apperr.Validation("username", "already taken"))
			return
		}
		httpx.WriteError(w, err)
		return
	}
	s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "login_success", "register")

	s.writeSession(w, r, u, http.StatusCreated)
}

// Login verifies credentials and issues a session.
func (s *Service) Login(w http.ResponseWriter, r *http.Request) {
	var req loginRequest
	if err := httpx.DecodeJSON(r, &req, false); err != nil {
		httpx.WriteError(w, err)
		return
	}
	u, err := s.users.ByUsername(r.Context(), req.Username)
	if err != nil {
		// Do not reveal whether the username exists.
		s.users.RecordAuthEvent(r.Context(), "", req.Username, "login_failure", "unknown username")
		httpx.WriteError(w, apperr.Unauthorized("invalid username or password"))
		return
	}
	ok, err := VerifyPassword(req.Password, u.PasswordHash)
	if err != nil || !ok {
		s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "login_failure", "bad password")
		httpx.WriteError(w, apperr.Unauthorized("invalid username or password"))
		return
	}
	s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "login_success", "")
	s.writeSession(w, r, u, http.StatusOK)
}

// Refresh rotates the refresh token (from body or HttpOnly cookie).
func (s *Service) Refresh(w http.ResponseWriter, r *http.Request) {
	var req refreshRequest
	_ = httpx.DecodeJSON(r, &req, true)
	raw := req.RefreshToken
	if raw == "" {
		if c, err := r.Cookie(RefreshCookie); err == nil {
			raw = c.Value
		}
	}
	userID, err := s.refresh.ConsumeRefreshToken(r.Context(), raw)
	if err != nil {
		s.users.RecordAuthEvent(r.Context(), userID, "", "refresh", "rejected")
		httpx.WriteError(w, err)
		return
	}
	u, err := s.users.ByID(r.Context(), userID)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	s.users.RecordAuthEvent(r.Context(), u.ID, u.Username, "refresh", "")
	s.writeSession(w, r, u, http.StatusOK)
}

// Logout revokes the presented refresh token.
func (s *Service) Logout(w http.ResponseWriter, r *http.Request) {
	var req logoutRequest
	_ = httpx.DecodeJSON(r, &req, true)
	raw := req.RefreshToken
	if raw == "" {
		if c, err := r.Cookie(RefreshCookie); err == nil {
			raw = c.Value
		}
	}
	s.refresh.RevokeRefreshToken(r.Context(), raw)
	// Clear the cookie regardless.
	http.SetCookie(w, &http.Cookie{Name: RefreshCookie, Value: "", MaxAge: -1, Path: "/api/v1", HttpOnly: true, Secure: s.cookieSecure, SameSite: http.SameSiteLaxMode})
	w.WriteHeader(http.StatusNoContent)
}

// Me returns the authenticated profile.
func (s *Service) Me(w http.ResponseWriter, r *http.Request) {
	u, err := s.users.ByID(r.Context(), httpx.UserID(r.Context()))
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	httpx.WriteJSON(w, http.StatusOK, httpx.Data(u.DTO()))
}

// writeSession issues access + refresh tokens and responds with both the
// JSON body (for native clients) and an HttpOnly cookie (for web).
func (s *Service) writeSession(w http.ResponseWriter, r *http.Request, u user.User, status int) {
	access, exp, err := s.tokens.IssueAccessToken(u.ID)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	refreshRaw, refreshExp, err := s.refresh.IssueRefreshToken(r.Context(), u.ID)
	if err != nil {
		httpx.WriteError(w, err)
		return
	}
	http.SetCookie(w, &http.Cookie{
		Name:     RefreshCookie,
		Value:    refreshRaw,
		Path:     "/api/v1/auth",
		Expires:  refreshExp,
		HttpOnly: true,
		Secure:   s.cookieSecure,
		SameSite: http.SameSiteLaxMode,
	})
	body := u.DTO()
	body["accessToken"] = access
	body["expiresIn"] = int(time.Until(exp).Seconds())
	body["refreshToken"] = refreshRaw
	httpx.WriteJSON(w, status, httpx.Data(body))
}

func ErrUnauthorized() error {
	return apperr.Unauthorized("authentication required")
}
