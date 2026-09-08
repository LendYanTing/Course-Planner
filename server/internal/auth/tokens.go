package auth

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// ---- Access tokens (stateless JWT, HS256) --------------------------------

type TokenService struct {
	secret    []byte
	accessTTL time.Duration
}

func NewTokenService(secret string, accessTTL time.Duration) *TokenService {
	return &TokenService{secret: []byte(secret), accessTTL: accessTTL}
}

func (s *TokenService) AccessTTL() time.Duration { return s.accessTTL }

// IssueAccessToken creates a signed access token for userID.
func (s *TokenService) IssueAccessToken(userID string) (string, time.Time, error) {
	exp := time.Now().Add(s.accessTTL)
	tok := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"sub": userID,
		"iat": time.Now().Unix(),
		"exp": exp.Unix(),
		"typ": "access",
	})
	signed, err := tok.SignedString(s.secret)
	return signed, exp, err
}

// VerifyAccessToken validates signature and expiry.
func (s *TokenService) VerifyAccessToken(token string) (string, error) {
	parsed, err := jwt.Parse(token, func(t *jwt.Token) (any, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return s.secret, nil
	}, jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Alg()}))
	if err != nil || !parsed.Valid {
		return "", apperr.Unauthorized("invalid access token")
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return "", apperr.Unauthorized("invalid access token claims")
	}
	sub, _ := claims["sub"].(string)
	typ, _ := claims["typ"].(string)
	if sub == "" || typ != "access" {
		return "", apperr.Unauthorized("invalid access token")
	}
	return sub, nil
}

// ---- Refresh tokens (opaque, hashed at rest, rotatable) ------------------

type RefreshRepo struct {
	pool      *pgxpool.Pool
	refreshTTL time.Duration
}

func NewRefreshRepo(pool *pgxpool.Pool, refreshTTL time.Duration) *RefreshRepo {
	return &RefreshRepo{pool: pool, refreshTTL: refreshTTL}
}

func (r *RefreshRepo) TTL() time.Duration { return r.refreshTTL }

func hashToken(raw string) string {
	sum := sha256.Sum256([]byte(raw))
	return hex.EncodeToString(sum[:])
}

// IssueRefreshToken mints a refresh token for userID, storing only its hash.
// Returns (rawToken, expiresAt).
func (r *RefreshRepo) IssueRefreshToken(ctx context.Context, userID string) (string, time.Time, error) {
	rawBytes := make([]byte, 32)
	if _, err := rand.Read(rawBytes); err != nil {
		return "", time.Time{}, err
	}
	raw := hex.EncodeToString(rawBytes)
	expires := time.Now().Add(r.refreshTTL)
	_, err := r.pool.Exec(ctx, `
		INSERT INTO refresh_tokens (id, user_id, token_hash, expires_at) VALUES ($1, $2, $3, $4)`,
		uuid.NewString(), userID, hashToken(raw), expires)
	if err != nil {
		return "", time.Time{}, err
	}
	return raw, expires, nil
}

// ConsumeRefreshToken atomically rotates: validates the token, revokes it and
// returns the owning user id. Reuse of a revoked token is rejected.
func (r *RefreshRepo) ConsumeRefreshToken(ctx context.Context, raw string) (string, error) {
	if raw == "" {
		return "", apperr.Unauthorized("refresh token required")
	}
	var id uuid.UUID
	err := r.pool.QueryRow(ctx, `
		UPDATE refresh_tokens
		SET revoked_at = now()
		WHERE token_hash = $1
		  AND revoked_at IS NULL
		  AND expires_at > now()
		RETURNING user_id`, hashToken(raw)).Scan(&id)
	if err == pgx.ErrNoRows {
		return "", apperr.Unauthorized("refresh token is invalid, expired or already used")
	}
	if err != nil {
		return "", err
	}
	return id.String(), nil
}

// RevokeRefreshToken invalidates one token (logout).
func (r *RefreshRepo) RevokeRefreshToken(ctx context.Context, raw string) {
	if raw == "" {
		return
	}
	_, _ = r.pool.Exec(ctx, `UPDATE refresh_tokens SET revoked_at = now() WHERE token_hash = $1 AND revoked_at IS NULL`, hashToken(raw))
}
