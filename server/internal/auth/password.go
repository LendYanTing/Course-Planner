// Package auth implements registration, login, token issuance/rotation and
// the HTTP auth middleware. Passwords use Argon2id (docs/security.md §1);
// access tokens are short-lived HS256 JWTs, refresh tokens are opaque,
// hashed-at-rest and revocable.
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"golang.org/x/crypto/argon2"
)

// argon2 parameters. Deliberately modest defaults; tune per deployment.
const (
	argonMemory  = 64 * 1024 // 64 MiB
	argonTime    = 1
	argonThreads = 4
	argonKeyLen  = 32
	argonSaltLen = 16
)

// HashPassword produces a PHC-format Argon2id hash.
func HashPassword(password string) (string, error) {
	salt := make([]byte, argonSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return "", err
	}
	key := argon2.IDKey([]byte(password), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s",
		argon2.Version, argonMemory, argonTime, argonThreads,
		base64.RawStdEncoding.EncodeToString(salt),
		base64.RawStdEncoding.EncodeToString(key)), nil
}

// VerifyPassword checks a password against a PHC-format Argon2id hash with
// constant-time comparison.
func VerifyPassword(password, encoded string) (bool, error) {
	parts := strings.Split(encoded, "$")
	if len(parts) != 6 || parts[1] != "argon2id" {
		return false, errors.New("malformed password hash")
	}
	var version int
	if _, err := fmt.Sscanf(parts[2], "v=%d", &version); err != nil {
		return false, err
	}
	var m, t, p int
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &m, &t, &p); err != nil {
		return false, err
	}
	salt, err := base64.RawStdEncoding.DecodeString(parts[4])
	if err != nil {
		return false, err
	}
	want, err := base64.RawStdEncoding.DecodeString(parts[5])
	if err != nil {
		return false, err
	}
	got := argon2.IDKey([]byte(password), salt, uint32(t), uint32(m), uint8(p), uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1, nil
}

// ValidatePasswordPolicy enforces the minimum length from docs/openapi.yaml.
func ValidatePasswordPolicy(password string) error {
	if len(password) < 8 {
		return apperr.Validation("password", "must be at least 8 characters")
	}
	if len(password) > 512 {
		return apperr.Validation("password", "must be at most 512 characters")
	}
	return nil
}

// ValidateUsername enforces a conservative username charset.
func ValidateUsername(username string) error {
	if len(username) < 3 || len(username) > 32 {
		return apperr.Validation("username", "must be 3-32 characters")
	}
	for _, c := range username {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9', c == '-', c == '_':
		default:
			return apperr.Validation("username", "only letters, digits, '-' and '_' are allowed")
		}
	}
	return nil
}
