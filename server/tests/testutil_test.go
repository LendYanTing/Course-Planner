// Package tests contains black-box integration tests that run the real HTTP
// server against PostgreSQL (TEST_DATABASE_URL). The schema is wiped and
// re-migrated on every run so results are deterministic.
package tests

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"sync/atomic"
	"testing"
	"time"

	"github.com/carryingon/courseplanner/server/internal/app"
	"github.com/carryingon/courseplanner/server/internal/platform/config"
	"github.com/carryingon/courseplanner/server/internal/platform/database"
)

var (
	server  *app.Server
	api     *httptest.Server
	testURL string
	testDB  = "postgres://courseplanner@127.0.0.1:5433/courseplanner_test?sslmode=disable"
	seq     atomic.Int64
)

func TestMain(m *testing.M) {
	if v := os.Getenv("TEST_DATABASE_URL"); v != "" {
		testDB = v
	}
	slog.SetLogLoggerLevel(slog.LevelError)

	ctx := context.Background()
	pool, err := database.Connect(ctx, testDB)
	if err != nil {
		fmt.Fprintln(os.Stderr, "SKIP integration tests: cannot reach TEST_DATABASE_URL:", err)
		os.Exit(0)
	}
	// Wipe and re-migrate for a deterministic run.
	if _, err := pool.Exec(ctx, `DROP SCHEMA public CASCADE`); err != nil {
		fmt.Fprintln(os.Stderr, "drop schema:", err)
		os.Exit(1)
	}
	if _, err := pool.Exec(ctx, `CREATE SCHEMA public`); err != nil {
		fmt.Fprintln(os.Stderr, "create schema:", err)
		os.Exit(1)
	}
	pool.Close()

	cfg, err := loadTestConfig()
	if err != nil {
		fmt.Fprintln(os.Stderr, "config:", err)
		os.Exit(1)
	}
	server, err = app.New(ctx, cfg)
	if err != nil {
		fmt.Fprintln(os.Stderr, "app:", err)
		os.Exit(1)
	}
	api = httptest.NewServer(server.Router)
	testURL = api.URL
	code := m.Run()
	api.Close()
	server.Close()
	os.Exit(code)
}

func loadTestConfig() (*config.Config, error) {
	os.Setenv("DATABASE_URL", testDB)
	os.Setenv("JWT_SECRET", "integration-test-secret-0123456789abcdef")
	os.Setenv("ACCESS_TOKEN_TTL", "1h")
	os.Setenv("REFRESH_TOKEN_TTL", "24h")
	os.Setenv("CONFIRMATION_TTL", "10m")
	os.Setenv("COOKIE_SECURE", "false")
	os.Setenv("TEST_MODE", "1")
	return config.Load()
}

// ---- HTTP helpers -----------------------------------------------------------

func do(t *testing.T, method, path, token string, body any) (*http.Response, []byte) {
	t.Helper()
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			t.Fatal(err)
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequest(method, testURL+"/api/v1"+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

func decode(t *testing.T, data []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("decode %s: %v", string(data), err)
	}
	return m
}

func expectStatus(t *testing.T, resp *http.Response, want int) {
	t.Helper()
	if resp.StatusCode != want {
		t.Fatalf("status = %d, want %d", resp.StatusCode, want)
	}
}

func errCode(t *testing.T, data []byte) string {
	t.Helper()
	m := decode(t, data)
	if e, ok := m["error"].(map[string]any); ok {
		s, _ := e["code"].(string)
		return s
	}
	return ""
}

func dataOf(t *testing.T, data []byte) map[string]any {
	t.Helper()
	m := decode(t, data)
	d, ok := m["data"].(map[string]any)
	if !ok {
		t.Fatalf("no data key in %s", string(data))
	}
	return d
}

// ---- domain helpers ----------------------------------------------------------

func newUser(t *testing.T) string {
	t.Helper()
	n := seq.Add(1)
	name := fmt.Sprintf("u%d_%d", n, time.Now().UnixNano()%100000)
	resp, data := do(t, "POST", "/auth/register", "", map[string]any{
		"username": name, "password": "password123", "timezone": "Asia/Shanghai",
	})
	expectStatus(t, resp, 201)
	return dataOf(t, data)["accessToken"].(string)
}

// uniqueName builds a collision-free username; register returns the token.
func uniqueName(prefix string) string {
	return fmt.Sprintf("%s_%d_%d", prefix, seq.Add(1), time.Now().UnixNano()%100000)
}

func registerNamed(t *testing.T, username string) (string, string) {
	t.Helper()
	resp, data := do(t, "POST", "/auth/register", "", map[string]any{
		"username": username, "password": "password123", "timezone": "Asia/Shanghai",
	})
	expectStatus(t, resp, 201)
	d := dataOf(t, data)
	return d["id"].(string), d["accessToken"].(string)
}

func timeNowNano() int64 { return time.Now().UnixNano() }

// newCSVRequest builds a POST with raw CSV content and a bearer token.
func newCSVRequest(t *testing.T, token, path, csv string) *http.Request {
	t.Helper()
	req, err := http.NewRequest("POST", testURL+"/api/v1"+path, bytes.NewBufferString(csv))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "text/csv")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	return req
}

func readAll(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	data, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return data
}

func readAllForErr(t *testing.T, resp *http.Response) []byte {
	t.Helper()
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return data
}

func newCalendar(t *testing.T, token string, weeks int) string {
	t.Helper()
	resp, data := do(t, "POST", "/calendars", token, map[string]any{
		"name": "2026秋", "firstDay": "2026-09-07", "totalWeeks": weeks,
	})
	expectStatus(t, resp, 201)
	return dataOf(t, data)["id"].(string)
}

func addPeriods(t *testing.T, token, calendarID string) {
	t.Helper()
	times := [][3]any{{1, "08:00", "08:45"}, {2, "08:55", "09:40"}, {3, "10:00", "10:45"},
		{4, "10:55", "11:40"}, {5, "14:00", "14:45"}, {6, "14:55", "15:40"},
		{7, "16:00", "16:45"}, {8, "16:55", "17:40"}}
	for _, tm := range times {
		resp, _ := do(t, "POST", "/calendars/"+calendarID+"/periods", token, map[string]any{
			"periodNo": tm[0], "startLocal": tm[1], "endLocal": tm[2],
		})
		expectStatus(t, resp, 201)
	}
}

// weekUTCRange returns the UTC range covering the local week of
// Mon 2026-09-07 + (week-1)*7 days in Asia/Shanghai.
func weekUTCRange(week int) (string, string) {
	loc, _ := time.LoadLocation("Asia/Shanghai")
	monday := time.Date(2026, 9, 7+(week-1)*7, 0, 0, 0, 0, loc).UTC()
	return monday.Format(time.RFC3339), monday.AddDate(0, 0, 7).Format(time.RFC3339)
}

func events(t *testing.T, token, start, end string) []map[string]any {
	t.Helper()
	resp, data := do(t, "GET", "/calendar/events?start="+start+"&end="+end, token, nil)
	expectStatus(t, resp, 200)
	arr, _ := decode(t, data)["data"].([]any)
	out := make([]map[string]any, 0, len(arr))
	for _, v := range arr {
		out = append(out, v.(map[string]any))
	}
	return out
}

// eventsWeek queries events for the local week containing Mon 2026-09-07 +
// (week-1)*7 days (Asia/Shanghai).
func eventsWeek(t *testing.T, token string, week int) []map[string]any {
	t.Helper()
	start, end := weekUTCRange(week)
	return events(t, token, start, end)
}

func addCourse(t *testing.T, token, calendarID string, meetings []map[string]any) string {
	t.Helper()
	body := map[string]any{"calendarId": calendarID, "name": "高等数学", "meetings": meetings}
	resp, data := do(t, "POST", "/courses", token, body)
	expectStatus(t, resp, 201)
	return dataOf(t, data)["id"].(string)
}

// seg builds one week-rule segment.
func seg(start, end int, parity string) map[string]any {
	return map[string]any{"start": start, "end": end, "parity": parity}
}

// meeting builds a course meeting payload.
func meeting(weekday, periodStart, periodEnd int, weekRule []map[string]any) map[string]any {
	return map[string]any{
		"weekday": weekday, "periodStart": periodStart, "periodEnd": periodEnd,
		"weekRule": weekRule,
	}
}
