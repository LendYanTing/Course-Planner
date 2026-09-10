// Package mcptoken issues, verifies and revokes the long-lived credentials an
// MCP client attaches to every call (docs/mcp.md §10, docs/security.md §11).
//
// Tokens are opaque, prefixed with `cpmcp_` and stored as a SHA-256 hash, so a
// database dump never yields a usable credential. They are revocable one by
// one and may be scoped read-only.
package mcptoken

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Prefix marks a long-lived MCP credential. It is deliberately not a JWT so
// the auth middleware can route a token to the right verifier on sight.
const Prefix = "cpmcp_"

// Scopes. Every token carries read; write is opt-in.
const (
	ScopeRead  = "read"
	ScopeWrite = "write"
)

// displayPrefixLen is how many random characters are kept for identification
// in listings. The remainder is never recoverable.
const displayPrefixLen = 8

// lastUsedTouch throttles the informational last_used_at write: an agent may
// call tools hundreds of times a minute.
const lastUsedTouch = 60 * time.Second

// Token is one stored credential (never carries the secret).
type Token struct {
	ID          string
	UserID      string
	Name        string
	TokenPrefix string
	Scopes      []string
	CreatedAt   time.Time
	LastUsedAt  *time.Time
	ExpiresAt   *time.Time
	RevokedAt   *time.Time
}

// DTO is the API shape (docs/api.md §18).
func (t Token) DTO() map[string]any {
	return map[string]any{
		"id":          t.ID,
		"name":        t.Name,
		"tokenPrefix": t.TokenPrefix,
		"scopes":      t.Scopes,
		"createdAt":   t.CreatedAt.UTC().Format(time.RFC3339),
		"lastUsedAt":  rfc3339OrNil(t.LastUsedAt),
		"expiresAt":   rfc3339OrNil(t.ExpiresAt),
		"revokedAt":   rfc3339OrNil(t.RevokedAt),
	}
}

// CanWrite reports whether the token may reach write paths.
func (t Token) CanWrite() bool { return hasScope(t.Scopes, ScopeWrite) }

// Credential is what the auth middleware needs after a successful verify.
type Credential struct {
	TokenID string
	UserID  string
	Scopes  []string
}

// LookLike reports whether a bearer token is an MCP credential rather than a
// session JWT. Anything too long to be one of ours is rejected outright so a
// hostile header cannot be hashed and matched.
func LookLike(raw string) bool {
	return strings.HasPrefix(raw, Prefix) && len(raw) <= 128
}

// NormalizeScopes validates a requested scope set. Read is always implied —
// a write-only credential would be useless, since discovering what to write
// requires reading first — so an empty request, ["read"] and ["write"] all
// resolve to a usable set.
func NormalizeScopes(requested []string) ([]string, error) {
	if len(requested) == 0 {
		return []string{ScopeRead, ScopeWrite}, nil
	}
	wantWrite := false
	for _, s := range requested {
		switch strings.TrimSpace(s) {
		case ScopeWrite:
			wantWrite = true
		case ScopeRead, "":
		default:
			return nil, apperr.Validation("scopes", "only \"read\" and \"write\" are supported")
		}
	}
	out := []string{ScopeRead}
	if wantWrite {
		out = append(out, ScopeWrite)
	}
	return out, nil
}

// ValidateName checks the human label shown in token listings.
func ValidateName(name string) error {
	if strings.TrimSpace(name) == "" || len(name) > 64 {
		return apperr.Validation("name", "must be 1-64 characters")
	}
	return nil
}

type Repo struct {
	pool *pgxpool.Pool
}

func NewRepo(pool *pgxpool.Pool) *Repo { return &Repo{pool: pool} }

// Create mints a token, stores only its hash and returns (record, secret).
// expiresInDays <= 0 means the token never expires.
func (r *Repo) Create(ctx context.Context, userID, name string, scopes []string, expiresInDays int) (Token, string, error) {
	if err := ValidateName(name); err != nil {
		return Token{}, "", err
	}
	normalized, err := NormalizeScopes(scopes)
	if err != nil {
		return Token{}, "", err
	}
	if expiresInDays < 0 || expiresInDays > 3650 {
		return Token{}, "", apperr.Validation("expiresInDays", "must be between 0 and 3650")
	}

	rawBytes := make([]byte, 32)
	if _, err := rand.Read(rawBytes); err != nil {
		return Token{}, "", err
	}
	raw := Prefix + base64.RawURLEncoding.EncodeToString(rawBytes)
	prefix := raw[:len(Prefix)+displayPrefixLen]

	t := Token{
		ID:          uuid.NewString(),
		UserID:      userID,
		Name:        name,
		TokenPrefix: prefix,
		Scopes:      normalized,
	}
	var expires any
	if expiresInDays > 0 {
		exp := time.Now().Add(time.Duration(expiresInDays) * 24 * time.Hour)
		expires = exp
		t.ExpiresAt = &exp
	}
	err = r.pool.QueryRow(ctx, `
		INSERT INTO mcp_tokens (id, user_id, name, token_prefix, token_hash, scopes, expires_at)
		VALUES ($1, $2, $3, $4, $5, $6, $7)
		RETURNING created_at`,
		t.ID, userID, name, prefix, Hash(raw), normalized, expires).Scan(&t.CreatedAt)
	if err != nil {
		return Token{}, "", err
	}
	return t, raw, nil
}

// Verify resolves a presented secret to its credential. Revoked and expired
// tokens are rejected with the same generic error so a probe cannot tell them
// apart. last_used_at is refreshed at most once per minute.
func (r *Repo) Verify(ctx context.Context, raw string) (Credential, error) {
	if !LookLike(raw) {
		return Credential{}, apperr.Unauthorized("invalid MCP token")
	}
	var cred Credential
	var id, userID uuid.UUID
	err := r.pool.QueryRow(ctx, `
		SELECT id, user_id, scopes FROM mcp_tokens
		WHERE token_hash = $1
		  AND revoked_at IS NULL
		  AND (expires_at IS NULL OR expires_at > now())`, Hash(raw)).
		Scan(&id, &userID, &cred.Scopes)
	if err == pgx.ErrNoRows {
		return Credential{}, apperr.Unauthorized("invalid MCP token")
	}
	if err != nil {
		return Credential{}, err
	}
	cred.TokenID = id.String()
	cred.UserID = userID.String()

	_, _ = r.pool.Exec(ctx, `
		UPDATE mcp_tokens SET last_used_at = now()
		WHERE id = $1 AND (last_used_at IS NULL OR last_used_at < now() - $2::interval)`,
		cred.TokenID, lastUsedTouch.String())
	return cred, nil
}

// List returns the user's tokens, newest first, revoked ones included so the
// list doubles as an audit trail.
func (r *Repo) List(ctx context.Context, userID string) ([]Token, error) {
	rows, err := r.pool.Query(ctx, `
		SELECT id, user_id, name, token_prefix, scopes, created_at, last_used_at, expires_at, revoked_at
		FROM mcp_tokens WHERE user_id = $1 ORDER BY created_at DESC`, userID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	out := make([]Token, 0)
	for rows.Next() {
		var t Token
		var id, uid uuid.UUID
		if err := rows.Scan(&id, &uid, &t.Name, &t.TokenPrefix, &t.Scopes,
			&t.CreatedAt, &t.LastUsedAt, &t.ExpiresAt, &t.RevokedAt); err != nil {
			return nil, err
		}
		t.ID, t.UserID = id.String(), uid.String()
		out = append(out, t)
	}
	return out, rows.Err()
}

// Revoke invalidates one token immediately. Revoking an already revoked token
// is reported as not found: the secret is gone either way.
func (r *Repo) Revoke(ctx context.Context, userID, tokenID string) error {
	if _, err := uuid.Parse(tokenID); err != nil {
		return apperr.NotFound("mcp token")
	}
	tag, err := r.pool.Exec(ctx, `
		UPDATE mcp_tokens SET revoked_at = now()
		WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL`, tokenID, userID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return apperr.NotFound("mcp token")
	}
	return nil
}

// Hash is the at-rest representation of a token secret.
func Hash(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

func hasScope(scopes []string, want string) bool {
	for _, s := range scopes {
		if s == want {
			return true
		}
	}
	return false
}

func rfc3339OrNil(t *time.Time) any {
	if t == nil {
		return nil
	}
	return t.UTC().Format(time.RFC3339)
}
