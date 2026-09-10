package mcptoken

import (
	"strings"
	"testing"
)

func TestLookLike(t *testing.T) {
	cases := []struct {
		token string
		want  bool
	}{
		{"cpmcp_abcdefghijklmnop", true},
		{"eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ4In0.sig", false},
		{"", false},
		{"cpmcp_" + strings.Repeat("a", 200), false}, // implausibly long
		{"Bearer cpmcp_x", false},
	}
	for _, c := range cases {
		if got := LookLike(c.token); got != c.want {
			t.Errorf("LookLike(%q) = %v, want %v", c.token, got, c.want)
		}
	}
}

func TestNormalizeScopes(t *testing.T) {
	t.Run("empty means read+write", func(t *testing.T) {
		got, err := NormalizeScopes(nil)
		if err != nil {
			t.Fatal(err)
		}
		if strings.Join(got, ",") != "read,write" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("read stays read-only", func(t *testing.T) {
		got, err := NormalizeScopes([]string{"read"})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Join(got, ",") != "read" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("write implies read", func(t *testing.T) {
		got, err := NormalizeScopes([]string{"write"})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Join(got, ",") != "read,write" {
			t.Fatalf("got %v", got)
		}
	})
	t.Run("unknown scope rejected", func(t *testing.T) {
		if _, err := NormalizeScopes([]string{"admin"}); err == nil {
			t.Fatal("expected an error for an unsupported scope")
		}
	})
}

func TestValidateName(t *testing.T) {
	if err := ValidateName("Claude Desktop"); err != nil {
		t.Fatalf("valid name rejected: %v", err)
	}
	if err := ValidateName("   "); err == nil {
		t.Fatal("blank name accepted")
	}
	if err := ValidateName(strings.Repeat("x", 65)); err == nil {
		t.Fatal("over-long name accepted")
	}
}

func TestHashIsStableAndNotTheSecret(t *testing.T) {
	const secret = "cpmcp_secret"
	h := Hash(secret)
	if h == secret || len(h) != 64 {
		t.Fatalf("hash = %q", h)
	}
	if Hash(secret) != h {
		t.Fatal("hash must be deterministic")
	}
	if Hash(secret+"x") == h {
		t.Fatal("different secrets must not collide")
	}
}
