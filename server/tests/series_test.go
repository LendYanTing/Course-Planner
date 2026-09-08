package tests

import (
	"testing"
)

// fixture: one course with a Mon 1-2 every-week meeting (all weeks) named
// series. We use full parity so weeks 1..16 all have Monday occurrences.
func seriesFixture(t *testing.T) (token, calendarID, courseID, meetingID string) {
	t.Helper()
	token = newUser(t)
	calendarID = newCalendar(t, token, 16)
	addPeriods(t, token, calendarID)
	body := map[string]any{
		"calendarId": calendarID, "name": "英语",
		"meetings": []map[string]any{meeting(1, 1, 2, []map[string]any{seg(1, 16, "all")})},
	}
	resp, data := do(t, "POST", "/courses", token, body)
	expectStatus(t, resp, 201)
	courseID = dataOf(t, data)["id"].(string)
	meetings := dataOf(t, data)["meetings"].([]any)
	meetingID = meetings[0].(map[string]any)["id"].(string)
	return
}

func applySeries(t *testing.T, token, seriesType, seriesID string, body map[string]any) map[string]any {
	t.Helper()
	resp, data := do(t, "POST", "/series/"+seriesType+"/"+seriesID+"/apply", token, body)
	expectStatus(t, resp, 200)
	return dataOf(t, data)
}

func TestSeriesThisMoveAndCancel(t *testing.T) {
	token, _, _, meetingID := seriesFixture(t)

	// THIS + MOVE week1 Monday (2026-09-07) from 08:00-09:40 to 15:00-16:00
	// local (07:00Z-08:00Z).
	res := applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope": "THIS", "occurrenceDateLocal": "2026-09-07",
		"operation": map[string]any{
			"type": "MOVE", "startAt": "2026-09-07T07:00:00Z", "endAt": "2026-09-07T08:00:00Z",
		},
	})
	if res["kind"] != "override" {
		t.Fatalf("kind = %v", res["kind"])
	}
	ev := eventsWeek(t, token, 1)
	var found *map[string]any
	for i := range ev {
		if ev[i]["title"] == "英语" {
			found = &ev[i]
		}
	}
	if found == nil {
		t.Fatal("course event missing after move")
	}
	if (*found)["startAt"] != "2026-09-07T07:00:00Z" {
		t.Fatalf("moved start = %v", (*found)["startAt"])
	}
	// Week 2 must be unaffected (original time).
	ev2 := eventsWeek(t, token, 2)
	orig := false
	for _, e := range ev2 {
		if e["title"] == "英语" && e["startAt"] == "2026-09-14T00:00:00Z" {
			orig = true
		}
	}
	if !orig {
		t.Fatal("week2 occurrence should stay at original time")
	}

	// THIS + CANCEL week2 Monday (2026-09-14)
	res = applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope": "THIS", "occurrenceDateLocal": "2026-09-14",
		"operation": map[string]any{"type": "CANCEL"},
	})
	if res["kind"] != "override" {
		t.Fatalf("cancel kind = %v", res["kind"])
	}
	ev2 = eventsWeek(t, token, 2)
	for _, e := range ev2 {
		if e["title"] == "英语" {
			t.Fatal("cancelled occurrence still present in week2")
		}
	}

	// THIS + MOVE onto a conflicting time without force -> COURSE_CONFLICT
	// Put a second course on Tuesday to conflict with a moved Monday
	// occurrence? Simpler: move to Monday 00:00Z (course slot of another
	// fixture course) — create second course Mon 3-4 first.
	body := map[string]any{
		"calendarId": findCalendar(t, token),
		"name":       "另一门",
		"meetings": []map[string]any{
			{"weekday": 1, "periodStart": 3, "periodEnd": 4, "weekRule": []map[string]any{seg(1, 16, "all")}},
		},
	}
	resp, data := do(t, "POST", "/courses", token, body)
	expectStatus(t, resp, 201)
	// This new course is Mon 10:00-11:40 local (02:00Z-03:40Z). Move英语 onto it.
	resp, data = do(t, "POST", "/series/course_meeting/"+meetingID+"/apply", token, map[string]any{
		"scope": "THIS", "occurrenceDateLocal": "2026-09-21",
		"operation": map[string]any{
			"type": "MOVE", "startAt": "2026-09-21T02:00:00Z", "endAt": "2026-09-21T03:00:00Z",
		},
	})
	if got := errCode(t, data); got != "COURSE_CONFLICT" {
		t.Fatalf("conflict code = %s (status %d)", got, resp.StatusCode)
	}
	// With force it succeeds.
	_, data = do(t, "POST", "/series/course_meeting/"+meetingID+"/apply", token, map[string]any{
		"scope": "THIS", "occurrenceDateLocal": "2026-09-21",
		"operation": map[string]any{
			"type": "MOVE", "startAt": "2026-09-21T02:00:00Z", "endAt": "2026-09-21T03:00:00Z", "force": true,
		},
	})
	if got := errCode(t, data); got != "" {
		t.Fatalf("forced move failed: %s", got)
	}
}

func findCalendar(t *testing.T, token string) string {
	t.Helper()
	resp, data := do(t, "GET", "/calendars", token, nil)
	expectStatus(t, resp, 200)
	arr := decode(t, data)["data"].([]any)
	if len(arr) == 0 {
		t.Fatal("no calendar")
	}
	return arr[0].(map[string]any)["id"].(string)
}

func TestSeriesThisAndFutureSplitsSeries(t *testing.T) {
	token, _, _, meetingID := seriesFixture(t)

	// THIS_AND_FUTURE + CANCEL from week 3 (2026-09-21): weeks 1-2 keep the
	// original meeting; weeks 3+ must vanish.
	res := applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope": "THIS_AND_FUTURE", "occurrenceDateLocal": "2026-09-21",
		"operation": map[string]any{"type": "CANCEL"},
	})
	if res["kind"] != "split" {
		t.Fatalf("kind = %v", res["kind"])
	}
	if res["newSeriesId"] != "" {
		t.Fatalf("cancel must not create a tail series, got %v", res["newSeriesId"])
	}
	// weeks 1 and 2 keep original 08:00 local occurrence
	for w := 1; w <= 2; w++ {
		ev := eventsWeek(t, token, w)
		found := false
		for _, e := range ev {
			if e["title"] == "英语" {
				found = true
			}
		}
		if !found {
			t.Fatalf("week%d occurrence should remain", w)
		}
	}
	// weeks 3 and 4 have nothing
	for w := 3; w <= 4; w++ {
		ev := eventsWeek(t, token, w)
		for _, e := range ev {
			if e["title"] == "英语" {
				t.Fatalf("week%d occurrence should be gone", w)
			}
		}
	}
}

func TestSeriesThisAndFutureMovesTail(t *testing.T) {
	token, _, _, meetingID := seriesFixture(t)

	// From week 2 (2026-09-14) move the series to Monday 5-6 (14:00-15:40 local
	// = 06:00Z-07:40Z). Weeks 1 keeps original 08:00 slot; weeks 2+ move.
	res := applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope": "THIS_AND_FUTURE", "occurrenceDateLocal": "2026-09-14",
		"operation": map[string]any{"type": "MOVE", "periodStart": 5, "periodEnd": 6},
	})
	if res["kind"] != "split" || res["newSeriesId"] == "" {
		t.Fatalf("kind = %v new = %v", res["kind"], res["newSeriesId"])
	}
	ev1 := eventsWeek(t, token, 1)
	start1 := firstStart(ev1, "英语")
	if start1 != "2026-09-07T00:00:00Z" {
		t.Fatalf("week1 start = %s", start1)
	}
	ev2 := eventsWeek(t, token, 2)
	start2 := firstStart(ev2, "英语")
	if start2 != "2026-09-14T06:00:00Z" {
		t.Fatalf("week2 start = %s (want moved 06:00Z)", start2)
	}
	// weeks 3+ also moved
	ev3 := eventsWeek(t, token, 3)
	if start3 := firstStart(ev3, "英语"); start3 != "2026-09-21T06:00:00Z" {
		t.Fatalf("week3 start = %s", start3)
	}
}

func firstStart(ev []map[string]any, title string) string {
	for _, e := range ev {
		if e["title"] == title {
			return e["startAt"].(string)
		}
	}
	return ""
}

func TestSeriesAllUpdatesSeries(t *testing.T) {
	token, _, _, meetingID := seriesFixture(t)

	res := applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope":     "ALL",
		"operation": map[string]any{"type": "MOVE", "periodStart": 7, "periodEnd": 8},
	})
	if res["kind"] != "series_update" {
		t.Fatalf("kind = %v", res["kind"])
	}
	// every week now at 16:00-17:40 local = 08:00Z-09:40Z
	ev1 := eventsWeek(t, token, 1)
	if start := firstStart(ev1, "英语"); start != "2026-09-07T08:00:00Z" {
		t.Fatalf("week1 start = %s", start)
	}
	ev2 := eventsWeek(t, token, 2)
	if start := firstStart(ev2, "英语"); start != "2026-09-14T08:00:00Z" {
		t.Fatalf("week2 start = %s", start)
	}

	// ALL + DELETE removes everything
	res = applySeries(t, token, "course_meeting", meetingID, map[string]any{
		"scope": "ALL", "operation": map[string]any{"type": "DELETE"},
	})
	if res["kind"] != "series_delete" {
		t.Fatalf("kind = %v", res["kind"])
	}
	ev3 := eventsWeek(t, token, 1)
	if firstStart(ev3, "英语") != "" {
		t.Fatal("deleted series still present")
	}
}

func TestSeriesRecurringThisCancel(t *testing.T) {
	token := newUser(t)
	resp, data := do(t, "POST", "/recurring-schedules", token, map[string]any{
		"title": "晨跑",
		"rule": map[string]any{
			"kind": "daily", "dateStart": "2026-09-07", "dateEnd": "2026-09-13",
			"startLocal": "06:30", "endLocal": "07:00",
		},
	})
	expectStatus(t, resp, 201)
	schedID := dataOf(t, data)["id"].(string)

	// cancel the Wednesday (2026-09-09) occurrence
	resp, data = do(t, "POST", "/series/recurring_schedule/"+schedID+"/apply", token, map[string]any{
		"scope": "THIS", "occurrenceDateLocal": "2026-09-09",
		"operation": map[string]any{"type": "CANCEL"},
	})
	expectStatus(t, resp, 200)
	ev := eventsWeek(t, token, 1)
	count := 0
	for _, e := range ev {
		if e["title"] == "晨跑" {
			count++
		}
	}
	if count != 6 {
		t.Fatalf("晨跑 after cancel = %d, want 6 (Mon-Sun minus Wed)", count)
	}
}

func TestSeriesRecurringThisAndFutureSplit(t *testing.T) {
	token := newUser(t)
	resp, data := do(t, "POST", "/recurring-schedules", token, map[string]any{
		"title": "背单词",
		"rule": map[string]any{
			"kind": "weekly", "dateStart": "2026-09-07", "dateEnd": "2026-10-31",
			"weekdays": []int{1, 3, 5}, "startLocal": "20:00", "endLocal": "20:30",
		},
	})
	expectStatus(t, resp, 201)
	schedID := dataOf(t, data)["id"].(string)

	// from 2026-09-14 change time to 21:00 and weekday Mon+Fri only
	resp, data = do(t, "POST", "/series/recurring_schedule/"+schedID+"/apply", token, map[string]any{
		"scope": "THIS_AND_FUTURE", "occurrenceDateLocal": "2026-09-14",
		"operation": map[string]any{
			"type":       "UPDATE",
			"patch":      map[string]any{"title": "背单词(加强)"},
			"startLocal": "21:00", "endLocal": "21:30",
		},
	})
	expectStatus(t, resp, 200)

	// Week1 (Sep 7-13): Mon/Wed/Fri at 20:00 title unchanged
	ev1 := eventsWeek(t, token, 1)
	if c := countTitle(ev1, "背单词"); c != 3 {
		t.Fatalf("week1 old series count = %d", c)
	}
	// Week2 (Sep 14-20): Mon/Wed/Fri at 21:00 (13:00Z), new title; weekday set
	// unchanged because the operation only patched time+title.
	ev2 := eventsWeek(t, token, 2)
	if c := countTitle(ev2, "背单词"); c != 0 {
		t.Fatalf("week2 old title count = %d", c)
	}
	if c := countTitle(ev2, "背单词(加强)"); c != 3 {
		t.Fatalf("week2 new title count = %d, want 3 (Mon/Wed/Fri)", c)
	}
	// Monday Sep 14 at 21:00 local == 13:00Z (pick the earliest occurrence).
	earliest := ""
	for _, e := range ev2 {
		if e["title"] == "背单词(加强)" {
			if earliest == "" || e["startAt"].(string) < earliest {
				earliest = e["startAt"].(string)
			}
		}
	}
	if earliest != "2026-09-14T13:00:00Z" {
		t.Fatalf("week2 Mon start = %s (want 21:00 local = 13:00Z)", earliest)
	}
}

func countTitle(ev []map[string]any, title string) int {
	c := 0
	for _, e := range ev {
		if e["title"] == title {
			c++
		}
	}
	return c
}
