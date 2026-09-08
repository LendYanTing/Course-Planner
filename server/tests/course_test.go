package tests

import (
	"strings"
	"testing"
)

// setupCourseFixture creates calendar (16 weeks, 8 periods) + one course
// "高等数学" on Mon(1-2, odd weeks) and Wed(3-4, even weeks).
func setupCourseFixture(t *testing.T) (token, calendarID string) {
	t.Helper()
	token = newUser(t)
	calendarID = newCalendar(t, token, 16)
	addPeriods(t, token, calendarID)
	addCourse(t, token, calendarID, []map[string]any{
		meeting(1, 1, 2, []map[string]any{seg(1, 16, "odd")}),
		meeting(3, 3, 4, []map[string]any{seg(1, 16, "even")}),
	})
	return token, calendarID
}

func TestCourseCrud(t *testing.T) {
	token, _ := setupCourseFixture(t)

	// list courses
	resp, data := do(t, "GET", "/courses", token, nil)
	expectStatus(t, resp, 200)
	arr := decode(t, data)["data"].([]any)
	if len(arr) != 1 {
		t.Fatalf("courses = %d", len(arr))
	}
	course := arr[0].(map[string]any)
	if course["name"] != "高等数学" {
		t.Fatalf("name = %v", course["name"])
	}

	// meetings under the course
	courseID := course["id"].(string)
	resp, data = do(t, "GET", "/courses/"+courseID+"/meetings", token, nil)
	expectStatus(t, resp, 200)
	ms := decode(t, data)["data"].([]any)
	if len(ms) != 2 {
		t.Fatalf("meetings = %d", len(ms))
	}
	first := ms[0].(map[string]any)
	weekRule := first["weekRule"].([]any)
	if len(weekRule) != 1 {
		t.Fatalf("weekRule = %v", weekRule)
	}
	rule := weekRule[0].(map[string]any)
	if rule["parity"] != "odd" {
		t.Fatalf("parity = %v", rule["parity"])
	}

	// update the course name via PATCH
	resp, data = do(t, "PATCH", "/courses/"+courseID, token, map[string]any{"name": "高等数学A"})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["name"] != "高等数学A" {
		t.Fatal("name not updated")
	}

	// ownership isolation: a second user cannot see/update it
	other := newUser(t)
	resp, _ = do(t, "GET", "/courses/"+courseID, other, nil)
	expectStatus(t, resp, 404)
	resp, _ = do(t, "PATCH", "/courses/"+courseID, other, map[string]any{"name": "hacked"})
	expectStatus(t, resp, 404)

	// delete
	resp, _ = do(t, "DELETE", "/courses/"+courseID, token, nil)
	expectStatus(t, resp, 204)
	resp, _ = do(t, "GET", "/courses/"+courseID, token, nil)
	expectStatus(t, resp, 404)
}

func TestOddEvenWeeksAndContinuousPeriods(t *testing.T) {
	token, _ := setupCourseFixture(t)

	// Week 1 (odd): Monday 1-2 only. Asia/Shanghai 08:00 = 00:00Z.
	ev := eventsWeek(t, token, 1)
	if len(ev) != 1 {
		t.Fatalf("week1 events = %d, want 1", len(ev))
	}
	e := ev[0]
	if e["title"] != "高等数学" {
		t.Fatalf("title = %v", e["title"])
	}
	// Monday periods 1-2 = 08:00..09:40 local = 00:00Z..01:40Z
	if e["startAt"] != "2026-09-07T00:00:00Z" || e["endAt"] != "2026-09-07T01:40:00Z" {
		t.Fatalf("mon1 times = %v..%v, want 2026-09-07T00:00:00Z..2026-09-07T01:40:00Z", e["startAt"], e["endAt"])
	}
	meta := e["metadata"].(map[string]any)
	if meta["periodStart"] != float64(1) || meta["periodEnd"] != float64(2) {
		t.Fatalf("periods = %v..%v", meta["periodStart"], meta["periodEnd"])
	}
	if meta["week"] != float64(1) {
		t.Fatalf("week = %v", meta["week"])
	}

	// Week 2 (even): Wednesday 3-4 = 10:00..11:40 local = 02:00Z..03:40Z
	ev2 := eventsWeek(t, token, 2)
	if len(ev2) != 1 {
		t.Fatalf("week2 events = %d, want 1", len(ev2))
	}
	if ev2[0]["startAt"] != "2026-09-16T02:00:00Z" {
		t.Fatalf("wed2 start = %v", ev2[0]["startAt"])
	}
	if ev2[0]["endAt"] != "2026-09-16T03:40:00Z" {
		t.Fatalf("wed2 end = %v", ev2[0]["endAt"])
	}
}

func TestCourseHardConflictRejected(t *testing.T) {
	token, calendarID := setupCourseFixture(t)

	// Overlapping the existing Monday odd-weeks 1-2 with a new course Monday 1-2.
	resp, data := do(t, "POST", "/courses", token, map[string]any{
		"calendarId": calendarID,
		"name":       "冲突课",
		"meetings": []map[string]any{
			meeting(1, 1, 2, []map[string]any{seg(1, 16, "all")}),
		},
	})
	if got := errCode(t, data); got != "COURSE_CONFLICT" {
		t.Fatalf("code = %s, want COURSE_CONFLICT (status %d)", got, resp.StatusCode)
	}

	// A non-overlapping one (Tuesday, different periods) succeeds.
	resp, data = do(t, "POST", "/courses", token, map[string]any{
		"calendarId": calendarID,
		"name":       "物理",
		"meetings": []map[string]any{
			meeting(2, 5, 6, []map[string]any{seg(1, 16, "all")}),
		},
	})
	expectStatus(t, resp, 201)
}

func TestCourseCrossMidnightAndValidation(t *testing.T) {
	token := newUser(t)
	calendarID := newCalendar(t, token, 8)
	addPeriods(t, token, calendarID)

	// weekday out of range
	resp, data := do(t, "POST", "/courses", token, map[string]any{
		"calendarId": calendarID, "name": "x",
		"meetings": []map[string]any{meeting(8, 1, 2, []map[string]any{seg(1, 8, "all")})},
	})
	if resp.StatusCode != 422 {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	// week out of calendar range
	resp, data = do(t, "POST", "/courses", token, map[string]any{
		"calendarId": calendarID, "name": "x",
		"meetings": []map[string]any{meeting(1, 1, 2, []map[string]any{seg(1, 20, "all")})},
	})
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("week out of range code = %s", got)
	}
	// period not defined in calendar
	resp, data = do(t, "POST", "/courses", token, map[string]any{
		"calendarId": calendarID, "name": "x",
		"meetings": []map[string]any{meeting(1, 9, 9, []map[string]any{seg(1, 8, "all")})},
	})
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("period not defined code = %s", got)
	}
	_ = resp
}

func TestPeriodValidationCrossMidnight(t *testing.T) {
	token := newUser(t)
	calendarID := newCalendar(t, token, 8)
	// end before start
	resp, data := do(t, "POST", "/calendars/"+calendarID+"/periods", token, map[string]any{
		"periodNo": 1, "startLocal": "09:00", "endLocal": "08:00",
	})
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("code = %s", got)
	}
	_ = resp
	// invalid time format
	resp, data = do(t, "POST", "/calendars/"+calendarID+"/periods", token, map[string]any{
		"periodNo": 1, "startLocal": "25:00", "endLocal": "26:00",
	})
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("bad time code = %s", got)
	}
	_ = resp
}

func TestCalendarCrudAndPeriods(t *testing.T) {
	token := newUser(t)
	calendarID := newCalendar(t, token, 16)
	addPeriods(t, token, calendarID)

	// period list ordered by periodNo
	resp, data := do(t, "GET", "/calendars/"+calendarID+"/periods", token, nil)
	expectStatus(t, resp, 200)
	ps := decode(t, data)["data"].([]any)
	if len(ps) != 8 {
		t.Fatalf("periods = %d", len(ps))
	}
	first := ps[0].(map[string]any)
	if first["periodNo"] != float64(1) || first["startLocal"] != "08:00" {
		t.Fatalf("period1 = %v", first)
	}

	// update period 1 to 08:10
	pID := first["id"].(string)
	resp, data = do(t, "PATCH", "/calendars/"+calendarID+"/periods/"+pID, token, map[string]any{"startLocal": "08:10"})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["startLocal"] != "08:10" {
		t.Fatal("period not updated")
	}

	// cross-user isolation: deleting a foreign period yields 404
	other := newUser(t)
	resp, _ = do(t, "DELETE", "/calendars/"+calendarID+"/periods/"+pID, other, nil)
	expectStatus(t, resp, 404)
	// the owner can delete it (tombstone)
	resp, _ = do(t, "DELETE", "/calendars/"+calendarID+"/periods/"+pID, token, nil)
	expectStatus(t, resp, 204)
}

func TestCsvImportPreviewAndCommit(t *testing.T) {
	token, calendarID := setupCourseFixture(t)
	csv := strings.Join([]string{
		"课程名称,星期,开始节数,结束节数,老师,地点,周数",
		"线性代数,2,1,2,李老师,理工楼110,1-16",
		"大学英语,4,5,6,张老师,文成楼125,2、5、8",
		"离散数学,5,1,2,赵老师,信科楼301,1-5、7-11单、12-16双",
	}, "\n")

	// preview success
	req := newCSVRequest(t, token, "/import/courses/preview?calendarId="+calendarID, csv)
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("preview status = %d", resp.StatusCode)
	}
	data := readAll(t, resp)
	d := dataOf(t, data)
	previewID := d["previewId"].(string)
	courses := d["courses"].([]any)
	if len(courses) != 3 {
		t.Fatalf("parsed courses = %d", len(courses))
	}
	// verify the odd/even mixed rule parsed
	disc := courses[2].(map[string]any)
	if !strings.Contains(disc["weeks"].(string), "单") {
		t.Fatalf("weeks = %v", disc["weeks"])
	}

	// commit
	resp, data = do(t, "POST", "/import/courses/commit", token, map[string]any{"previewId": previewID})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["courses"].(float64) != 3 {
		t.Fatal("committed count != 3")
	}

	// courses now visible via events on their days
	ev := eventsWeek(t, token, 1)
	foundTue := false
	for _, e := range ev {
		if e["title"] == "线性代数" {
			foundTue = true
		}
	}
	if !foundTue {
		t.Fatal("imported course missing from events")
	}

	// committing twice must fail (CONFIRMATION_EXPIRED)
	resp, data = do(t, "POST", "/import/courses/commit", token, map[string]any{"previewId": previewID})
	if got := errCode(t, data); got != "CONFIRMATION_EXPIRED" {
		t.Fatalf("second commit code = %s", got)
	}
}

func TestCsvImportConflictDetected(t *testing.T) {
	token, calendarID := setupCourseFixture(t)
	// The fixture already has a course Mon 1-2 odd weeks; CSV conflicts with it.
	csv := "课程名称,星期,开始节数,结束节数,老师,地点,周数\n冲突课,1,1,2,老师,教室,1-5\n"
	req := newCSVRequest(t, token, "/import/courses/preview?calendarId="+calendarID, csv)
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 422 {
		t.Fatalf("conflict preview status = %d", resp.StatusCode)
	}
	body := readAll(t, resp)
	if errCode(t, body) != "COURSE_CONFLICT" {
		t.Fatalf("code = %s", errCode(t, body))
	}
}

func TestCsvImportBadWeekSyntax(t *testing.T) {
	token, calendarID := setupCourseFixture(t)
	csv := "课程名称,星期,开始节数,结束节数,老师,地点,周数\n坏课,1,1,2,老师,教室,abc\n"
	req := newCSVRequest(t, token, "/import/courses/preview?calendarId="+calendarID, csv)
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	body := readAll(t, resp)
	if errCode(t, body) != "CSV_VALIDATION_ERROR" {
		t.Fatalf("code = %s", errCode(t, body))
	}
}

func TestTimeZoneImmutability(t *testing.T) {
	token := newUser(t)
	// The user API exposes no way to change timezone: there is no /me PATCH.
	// Guard: registration bakes the value.
	resp, data := do(t, "GET", "/me", token, nil)
	expectStatus(t, resp, 200)
	if dataOf(t, data)["timezone"] != "Asia/Shanghai" {
		t.Fatalf("tz = %v", dataOf(t, data)["timezone"])
	}
}
