// Package config loads server configuration from the environment.
// Secrets never live in the repo; see .env.example at the repo root.
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

type Config struct {
	Port               string
	DatabaseURL        string
	JWTSecret          string
	AccessTokenTTL     time.Duration
	RefreshTokenTTL    time.Duration
	CORSAllowedOrigins []string
	ConfirmationTTL    time.Duration
	LogLevel           string
	// TestMode relaxes nothing security-wise; it only keeps startup logs terse.
	TestMode bool
}

// Load builds a Config from environment variables with safe defaults.
func Load() (*Config, error) {
	c := &Config{
		Port:            envOr("PORT", "8080"),
		DatabaseURL:     os.Getenv("DATABASE_URL"),
		JWTSecret:       os.Getenv("JWT_SECRET"),
		AccessTokenTTL:  envDuration("ACCESS_TOKEN_TTL", 15*time.Minute),
		RefreshTokenTTL: envDuration("REFRESH_TOKEN_TTL", 30*24*time.Hour),
		ConfirmationTTL: envDuration("CONFIRMATION_TTL", 10*time.Minute),
		LogLevel:        envOr("LOG_LEVEL", "info"),
		TestMode:        os.Getenv("TEST_MODE") == "1",
	}
	if origins := os.Getenv("CORS_ALLOWED_ORIGINS"); origins != "" {
		for _, o := range strings.Split(origins, ",") {
			if o = strings.TrimSpace(o); o != "" {
				c.CORSAllowedOrigins = append(c.CORSAllowedOrigins, o)
			}
		}
	}
	if c.DatabaseURL == "" {
		return nil, fmt.Errorf("DATABASE_URL is required")
	}
	if len(c.JWTSecret) < 16 {
		return nil, fmt.Errorf("JWT_SECRET must be at least 16 bytes (generate with: openssl rand -hex 32)")
	}
	if c.AccessTokenTTL <= 0 || c.RefreshTokenTTL <= 0 || c.ConfirmationTTL <= 0 {
		return nil, fmt.Errorf("token/confirmation TTLs must be positive")
	}
	return c, nil
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envDuration(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	d, err := time.ParseDuration(v)
	if err != nil {
		n, err2 := strconv.Atoi(v)
		if err2 != nil {
			return def
		}
		return time.Duration(n) * time.Second
	}
	return d
}
