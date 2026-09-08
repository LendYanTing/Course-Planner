package tests

import (
	"testing"
)

func TestTodoBlockDeadlineAndSoftConflict(t *testing.T) {
	token, _ := setupCourseFixture(t)

	// create project todo with deadline
	resp, data := do(t, "POST", "/todos", token, map[string]any{
		"title": "生化大作业", "type": "project", "priority": "high",
		"deadlineAt": "2026-09-20T08:00:00Z",
	})
	expectStatus(t, resp, 201)
	todoID := dataOf(t, data)["id"].(string)
	deadline := dataOf(t, data)["deadlineAt"].(string)
	if deadline != "2026-09-20T08:00:00Z" {
		t.Fatalf("deadline = %s", deadline)
	}

	// three blocks (查资料/分析/撰写)
	blocks := []map[string]any{
		{"startAt": "2026-09-07T09:00:00Z", "endAt": "2026-09-07T10:00:00Z", "blockNote": "查资料和整理文献"},
		{"startAt": "2026-09-08T09:00:00Z", "endAt": "2026-09-08T10:30:00Z", "blockNote": "分析实验数据"},
		{"startAt": "2026-09-10T09:00:00Z", "endAt": "2026-09-10T10:30:00Z", "blockNote": "撰写讨论部分"},
	}
	for _, b := range blocks {
		resp, _ := do(t, "POST", "/todos/"+todoID+"/blocks", token, b)
		expectStatus(t, resp, 201)
	}
	// A block placed on Monday 08:00-09:00 local (00:00Z-01:00Z) overlaps the
	// Mon course (00:00Z-01:40Z) -> allowed but flagged soft_conflict.
	resp, data = do(t, "POST", "/todos/"+todoID+"/blocks", token, map[string]any{
		"startAt": "2026-09-07T00:00:00Z", "endAt": "2026-09-07T01:00:00Z", "blockNote": "撞课时间",
	})
	expectStatus(t, resp, 201)
	if dataOf(t, data)["conflictState"] != "soft_conflict" {
		t.Fatalf("conflictState = %v", dataOf(t, data)["conflictState"])
	}

	// deadline shows in events
	ev := events(t, token, "2026-09-19T16:00:00Z", "2026-09-20T16:00:00Z")
	foundDeadline := false
	for _, e := range ev {
		if e["type"] == "deadline" && e["title"] == "生化大作业" {
			foundDeadline = true
		}
	}
	if !foundDeadline {
		t.Fatal("deadline event missing")
	}

	// cross-midnight block rejected (UTC instant 23:00Z lands next local day)
	resp, data = do(t, "POST", "/todos/"+todoID+"/blocks", token, map[string]any{
		"startAt": "2026-09-07T15:00:00Z", "endAt": "2026-09-07T17:00:00Z",
	})
	if got := errCode(t, data); got != "CROSS_MIDNIGHT_NOT_ALLOWED" {
		t.Fatalf("cross midnight code = %s", got)
	}
	_ = resp

	// move/resize via PATCH /todo-blocks/{id}
	ev2 := eventsWeek(t, token, 1)
	var blockID string
	for _, e := range ev2 {
		if e["type"] == "todo_block" && e["metadata"].(map[string]any)["blockNote"] == "查资料和整理文献" {
			blockID = e["metadata"].(map[string]any)["blockId"].(string)
		}
	}
	if blockID == "" {
		t.Fatal("block not found in events")
	}
	resp, data = do(t, "PATCH", "/todo-blocks/"+blockID, token, map[string]any{"endAt": "2026-09-07T10:30:00Z"})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["endAt"] != "2026-09-07T10:30:00Z" {
		t.Fatalf("endAt after resize = %v", dataOf(t, data)["endAt"])
	}

	// mark todo completed
	resp, data = do(t, "PATCH", "/todos/"+todoID, token, map[string]any{"status": "completed"})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["status"] != "completed" {
		t.Fatal("status not updated")
	}

	// delete a block (tombstone) then it disappears from events
	do(t, "DELETE", "/todo-blocks/"+blockID, token, nil)
	ev3 := eventsWeek(t, token, 1)
	for _, e := range ev3 {
		if e["type"] == "todo_block" && e["id"] == "todo_block:"+blockID {
			t.Fatal("deleted block still in events")
		}
	}
}

func TestRecurringScheduleDailyWeeklyAcademic(t *testing.T) {
	token, calendarID := setupCourseFixture(t)

	// daily 2026-09-08..2026-09-11 19:00-20:00
	resp, _ := do(t, "POST", "/recurring-schedules", token, map[string]any{
		"title": "晚自习",
		"rule": map[string]any{
			"kind": "daily", "dateStart": "2026-09-08", "dateEnd": "2026-09-11",
			"startLocal": "19:00", "endLocal": "20:00",
		},
	})
	expectStatus(t, resp, 201)

	// weekly Monday+Wednesday 21:00-22:00 within Sep range
	resp, _ = do(t, "POST", "/recurring-schedules", token, map[string]any{
		"title": "阅读时间",
		"rule": map[string]any{
			"kind": "weekly", "dateStart": "2026-09-07", "dateEnd": "2026-09-30",
			"weekdays": []int{1, 3}, "startLocal": "21:00", "endLocal": "22:00",
		},
	})
	expectStatus(t, resp, 201)

	// by_academic_week: Mon 5-6 periods on odd weeks (reuses calendar periods)
	resp, _ = do(t, "POST", "/recurring-schedules", token, map[string]any{
		"title": "小组研讨",
		"rule": map[string]any{
			"kind": "by_academic_week", "calendarId": calendarID,
			"weekdays": []int{4}, "weekRule": []map[string]any{seg(1, 16, "odd")},
			"periodStart": 5, "periodEnd": 6,
		},
	})
	expectStatus(t, resp, 201)

	// week 1 events: Mon course + 晚自习 x4? 晚自习 covers Tue-Fri (09-08..09-11)
	ev := eventsWeek(t, token, 1)
	counts := map[string]int{}
	for _, e := range ev {
		counts[e["title"].(string)]++
	}
	if counts["晚自习"] != 4 {
		t.Fatalf("晚自习 week1 = %d, want 4 (Tue-Fri); events=%v", counts["晚自习"], titles(ev))
	}
	if counts["阅读时间"] != 2 {
		t.Fatalf("阅读时间 week1 = %d, want 2 (Mon+Wed)", counts["阅读时间"])
	}
	// Thu odd week1 小组研讨 periods 5-6 = 14:00-15:40 local
	if counts["小组研讨"] != 1 {
		t.Fatalf("小组研讨 week1 = %d, want 1 (Thu)", counts["小组研讨"])
	}

	// update the schedule rule (weekly -> weekdays Mon only)
	var schedID string
	for _, e := range ev {
		if e["type"] == "recurring_schedule" && e["title"] == "阅读时间" {
			schedID = e["source"].(map[string]any)["id"].(string)
			break
		}
	}
	resp, _ = do(t, "PATCH", "/recurring-schedules/"+schedID, token, map[string]any{
		"rule": map[string]any{
			"kind": "weekly", "dateStart": "2026-09-07", "dateEnd": "2026-09-30",
			"weekdays": []int{1}, "startLocal": "21:00", "endLocal": "22:00",
		},
	})
	expectStatus(t, resp, 200)
	ev2 := eventsWeek(t, token, 1)
	c2 := map[string]int{}
	for _, e := range ev2 {
		c2[e["title"].(string)]++
	}
	if c2["阅读时间"] != 1 {
		t.Fatalf("阅读时间 after update = %d, want 1 (Mon only)", c2["阅读时间"])
	}

	// delete a schedule -> disappears
	do(t, "DELETE", "/recurring-schedules/"+schedID, token, nil)
	ev3 := eventsWeek(t, token, 1)
	for _, e := range ev3 {
		if e["title"] == "阅读时间" {
			t.Fatal("deleted schedule still present")
		}
	}
}

func titles(ev []map[string]any) []string {
	out := make([]string, 0, len(ev))
	for _, e := range ev {
		out = append(out, e["title"].(string)+"@"+e["startAt"].(string))
	}
	return out
}

func TestFreeSlots(t *testing.T) {
	token, _ := setupCourseFixture(t)
	// Monday week1: course 08:00-09:40 (00:00Z-01:40Z). Free 2h slots:
	// Saturday/Sunday are fully free.
	start, end := weekUTCRange(1)
	resp, data := do(t, "GET", "/free-slots?start="+start+"&end="+end+"&durationMinutes=120&alignment=5_minutes", token, nil)
	expectStatus(t, resp, 200)
	slots, _ := decode(t, data)["data"].([]any)
	if len(slots) < 1 {
		t.Fatalf("no free slots; got %d", len(slots))
	}
	// A slot covering the weekend (before Monday 00:00Z or after Friday) must
	// not intersect the Monday course instant.
	for _, s := range slots {
		slot := s.(map[string]any)
		if slot["startAt"] == "2026-09-07T00:00:00Z" {
			t.Fatalf("slot must not start inside the Monday course: %v", slot)
		}
	}

	// invalid alignment
	resp, data = do(t, "GET", "/free-slots?start="+start+"&end="+end+"&durationMinutes=60&alignment=bogus", token, nil)
	if got := errCode(t, data); got != "VALIDATION_ERROR" {
		t.Fatalf("code = %s", got)
	}
	_ = resp
}

func TestTagsAndCategories(t *testing.T) {
	token := newUser(t)
	resp, data := do(t, "POST", "/tags", token, map[string]any{"name": "考试", "color": "#ff0000"})
	expectStatus(t, resp, 201)
	tagID := dataOf(t, data)["id"].(string)

	resp, data = do(t, "POST", "/todo-categories", token, map[string]any{"name": "作业", "color": "#00ff00"})
	expectStatus(t, resp, 201)
	catID := dataOf(t, data)["id"].(string)

	// todo referencing tag + category
	resp, data = do(t, "POST", "/todos", token, map[string]any{
		"title": "带标签任务", "type": "one_off",
		"tagIds": []string{tagID}, "categoryId": catID,
	})
	expectStatus(t, resp, 201)
	todoID := dataOf(t, data)["id"].(string)

	// list filter by tag
	resp, data = do(t, "GET", "/todos?tagIds="+tagID, token, nil)
	expectStatus(t, resp, 200)
	if len(decode(t, data)["data"].([]any)) != 1 {
		t.Fatal("tag filter failed")
	}

	// delete tag; todo remains with dangling reference (client treats as none)
	do(t, "DELETE", "/tags/"+tagID, token, nil)
	resp, data = do(t, "GET", "/todos/"+todoID, token, nil)
	expectStatus(t, resp, 200)
}
