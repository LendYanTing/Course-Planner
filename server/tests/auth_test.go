package tests

import (
	"testing"
)

func TestAuthRegisterLoginRefreshLogout(t *testing.T) {
	// register
	resp, data := do(t, "POST", "/auth/register", "", map[string]any{
		"username": uniqueName("alice"), "password": "password123", "timezone": "Asia/Shanghai",
	})
	expectStatus(t, resp, 201)
	d := dataOf(t, data)
	if d["timezone"] != "Asia/Shanghai" {
		t.Fatalf("timezone mismatch: %v", d["timezone"])
	}
	access := d["accessToken"].(string)
	refresh := d["refreshToken"].(string)
	if access == "" || refresh == "" {
		t.Fatal("missing tokens")
	}

	// me
	resp, data = do(t, "GET", "/me", access, nil)
	expectStatus(t, resp, 200)
	if dataOf(t, data)["username"] == "" {
		t.Fatal("me returned no username")
	}

	// login
	resp, data = do(t, "POST", "/auth/login", "", map[string]any{
		"username": d["username"].(string), "password": "password123",
	})
	expectStatus(t, resp, 200)
	access2 := dataOf(t, data)["accessToken"].(string)

	// wrong password
	resp, _ = do(t, "POST", "/auth/login", "", map[string]any{
		"username": d["username"].(string), "password": "wrong-password",
	})
	expectStatus(t, resp, 401)

	// refresh rotates the token
	resp, data = do(t, "POST", "/auth/refresh", "", map[string]any{"refreshToken": refresh})
	expectStatus(t, resp, 200)
	refresh2 := dataOf(t, data)["refreshToken"].(string)
	if refresh2 == "" {
		t.Fatal("no new refresh token")
	}

	// old refresh token must be dead (rotation)
	resp, _ = do(t, "POST", "/auth/refresh", "", map[string]any{"refreshToken": refresh})
	expectStatus(t, resp, 401)

	// logout invalidates the current token
	resp, _ = do(t, "POST", "/auth/logout", "", map[string]any{"refreshToken": refresh2})
	expectStatus(t, resp, 204)
	resp, _ = do(t, "POST", "/auth/refresh", "", map[string]any{"refreshToken": refresh2})
	expectStatus(t, resp, 401)

	// unauthorized request
	resp, _ = do(t, "GET", "/me", "bogus-token", nil)
	expectStatus(t, resp, 401)
	resp, _ = do(t, "GET", "/me", "", nil)
	expectStatus(t, resp, 401)
	_ = access2
}

func TestAuthValidation(t *testing.T) {
	cases := []struct {
		name string
		body map[string]any
		code string
	}{
		{"short password", map[string]any{"username": "x1user", "password": "short", "timezone": "Asia/Shanghai"}, "VALIDATION_ERROR"},
		{"invalid timezone", map[string]any{"username": "tzuser", "password": "password123", "timezone": "Not/AZone"}, "INVALID_TIMEZONE"},
		{"invalid username charset", map[string]any{"username": "bad name!", "password": "password123", "timezone": "Asia/Shanghai"}, "VALIDATION_ERROR"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			resp, data := do(t, "POST", "/auth/register", "", c.body)
			if got := errCode(t, data); got != c.code {
				t.Fatalf("code = %s, want %s", got, c.code)
			}
			if resp.StatusCode != 400 && resp.StatusCode != 422 {
				t.Fatalf("status = %d", resp.StatusCode)
			}
		})
	}

	// duplicate username
	resp, data := do(t, "POST", "/auth/register", "", map[string]any{
		"username": "dup_user", "password": "password123", "timezone": "Asia/Shanghai",
	})
	expectStatus(t, resp, 201)
	resp, data = do(t, "POST", "/auth/register", "", map[string]any{
		"username": "dup_user", "password": "password123", "timezone": "Asia/Shanghai",
	})
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("dup register code = %s", got)
	}
}
