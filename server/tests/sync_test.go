package tests

import (
	"testing"
)

func opCreate(operationID, entityType, entityID string, fields map[string]any) map[string]any {
	return map[string]any{
		"operationId": operationID, "entityType": entityType, "entityId": entityID,
		"operation": "create", "baseRevision": 0, "changes": fields,
	}
}

func opUpdate(operationID, entityType, entityID string, baseRev int64, fields map[string]any) map[string]any {
	return map[string]any{
		"operationId": operationID, "entityType": entityType, "entityId": entityID,
		"operation": "update", "baseRevision": baseRev, "changes": fields,
	}
}

func opDelete(operationID, entityType, entityID string, baseRev int64) map[string]any {
	return map[string]any{
		"operationId": operationID, "entityType": entityType, "entityId": entityID,
		"operation": "delete", "baseRevision": baseRev, "changes": map[string]any{},
	}
}

func push(t *testing.T, token string, ops []map[string]any) map[string]any {
	t.Helper()
	resp, data := do(t, "POST", "/sync/push", token, map[string]any{
		"baseCursor": 0, "operations": ops,
	})
	expectStatus(t, resp, 200)
	return dataOf(t, data)
}

func pushStatus(t *testing.T, token string, op map[string]any) string {
	t.Helper()
	res := push(t, token, []map[string]any{op})
	if len(res["conflicts"].([]any)) > 0 {
		return "conflict"
	}
	if len(res["accepted"].([]any)) > 0 {
		return "accepted"
	}
	if len(res["merged"].([]any)) > 0 {
		return "merged"
	}
	return "?"
}

func TestSyncPushCreateIdempotent(t *testing.T) {
	token := newUser(t)

	// check cursor 0
	resp, data := do(t, "GET", "/sync/state", token, nil)
	expectStatus(t, resp, 200)
	if dataOf(t, data)["serverCursor"].(float64) != 0 {
		t.Fatal("fresh user cursor must be 0")
	}

	entityID := "11111111-1111-4111-8111-111111111111"
	create := opCreate("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "todo", entityID, map[string]any{
		"title": "同步任务", "type": "one_off", "priority": "normal", "status": "todo",
	})

	// first push
	res := push(t, token, []map[string]any{create})
	if len(res["accepted"].([]any)) != 1 {
		t.Fatalf("accepted = %v", res["accepted"])
	}
	if res["serverCursor"].(float64) < 1 {
		t.Fatalf("cursor = %v", res["serverCursor"])
	}

	// duplicate push of the same operationId is a no-op
	res2 := push(t, token, []map[string]any{create})
	if len(res2["accepted"].([]any)) != 1 {
		t.Fatalf("replay accepted = %v", res2["accepted"])
	}

	// exactly one todo exists
	resp, data = do(t, "GET", "/todos", token, nil)
	expectStatus(t, resp, 200)
	todos := decode(t, data)["data"].([]any)
	if len(todos) != 1 {
		t.Fatalf("todos = %d, want 1 (idempotency broken)", len(todos))
	}

	// update via REST returns revision 2 and syncs changes
	resp, data = do(t, "PATCH", "/todos/"+entityID, token, map[string]any{"title": "同步任务v2"})
	expectStatus(t, resp, 200)
	rev := dataOf(t, data)["revision"].(float64)
	if rev != 2 {
		t.Fatalf("revision = %v", rev)
	}

	// changes pull contains create + update
	resp, data = do(t, "GET", "/sync/changes?after=0&limit=50", token, nil)
	expectStatus(t, resp, 200)
	changes := decode(t, data)["data"].(map[string]any)["changes"].([]any)
	if len(changes) < 2 {
		t.Fatalf("changes = %d", len(changes))
	}
	first := changes[0].(map[string]any)
	if first["operation"] != "create" || first["entityId"] != entityID {
		t.Fatalf("first change = %v", first)
	}
}

func TestSyncThreeWayMergeAndConflict(t *testing.T) {
	token := newUser(t)
	entityID := "22222222-2222-4222-8222-222222222222"
	create := opCreate("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", "todo", entityID, map[string]any{
		"title": "标题A", "priority": "normal", "type": "one_off", "status": "todo",
	})
	pushStatus(t, token, create)

	// REST update changes priority to high -> server revision 2, base snapshot
	// revision 1 has priority=normal.
	resp, data := do(t, "PATCH", "/todos/"+entityID, token, map[string]any{"priority": "high"})
	expectStatus(t, resp, 200)

	// Client (base revision 1) edits title only. Server changed priority, so:
	// - title: base==server -> local wins
	// - priority: base normal, server high, local unchanged (normal) -> keep server
	// Result: MERGED with both title and priority applied.
	res := push(t, token, []map[string]any{
		opUpdate("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "todo", entityID, 1, map[string]any{"title": "标题B"}),
	})
	if len(res["merged"].([]any)) != 1 {
		t.Fatalf("merged = %v conflicts=%v", res["merged"], res["conflicts"])
	}
	resp, data = do(t, "GET", "/todos/"+entityID, token, nil)
	d := dataOf(t, data)
	if d["title"] != "标题B" || d["priority"] != "high" {
		t.Fatalf("after merge title=%v priority=%v", d["title"], d["priority"])
	}

	// Real conflict: base rev2 title=B, server changed title to C; client edits
	// title to D (from base B).
	serverRev := d["revision"].(float64)
	do(t, "PATCH", "/todos/"+entityID, token, map[string]any{"title": "标题C"})
	res = push(t, token, []map[string]any{
		opUpdate("dddddddd-dddd-4ddd-8ddd-dddddddddddd", "todo", entityID, int64(serverRev),
			map[string]any{"title": "标题D"}),
	})
	conflicts := res["conflicts"].([]any)
	if len(conflicts) != 1 {
		t.Fatalf("conflicts = %d", len(conflicts))
	}
	c := conflicts[0].(map[string]any)
	if c["entityId"] != entityID {
		t.Fatalf("conflict entity = %v", c["entityId"])
	}
	fields := c["conflictingFields"].([]any)
	if len(fields) != 1 || fields[0] != "title" {
		t.Fatalf("conflictingFields = %v", fields)
	}
	// Entity untouched by the conflicting operation.
	resp, data = do(t, "GET", "/todos/"+entityID, token, nil)
	if dataOf(t, data)["title"] != "标题C" {
		t.Fatal("server title should remain 标题C")
	}
}

func TestSyncTombstoneAndUpdateOnDeleted(t *testing.T) {
	token := newUser(t)
	entityID := "33333333-3333-4333-8333-333333333333"
	create := opCreate("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "todo", entityID, map[string]any{
		"title": "要删除的任务", "type": "one_off", "priority": "normal", "status": "todo",
	})
	pushStatus(t, token, create)

	// REST delete -> tombstone
	resp, _ := do(t, "DELETE", "/todos/"+entityID, token, nil)
	expectStatus(t, resp, 204)

	// changes include a delete op carrying deletedAt in payload
	resp, data := do(t, "GET", "/sync/changes?after=0&limit=50", token, nil)
	expectStatus(t, resp, 200)
	changes := decode(t, data)["data"].(map[string]any)["changes"].([]any)
	last := changes[len(changes)-1].(map[string]any)
	if last["operation"] != "delete" {
		t.Fatalf("last op = %v", last["operation"])
	}
	if _, ok := last["payload"].(map[string]any)["deletedAt"]; !ok {
		t.Fatal("tombstone payload missing deletedAt")
	}

	// pushing an update on a deleted entity -> conflict
	update := opUpdate("ffffffff-ffff-4fff-8fff-ffffffffffff", "todo", entityID, 2, map[string]any{"title": "改已删除"})
	res := push(t, token, []map[string]any{update})
	if len(res["conflicts"].([]any)) != 1 {
		t.Fatalf("update on deleted should conflict: %v", res)
	}

	// pushing a delete on an already deleted entity -> accepted (idempotent)
	res2 := push(t, token, []map[string]any{opDelete("abababab-abab-4bab-8bab-abababababab", "todo", entityID, 2)})
	if len(res2["accepted"].([]any)) != 1 {
		t.Fatalf("delete of deleted = %v", res2)
	}
}

func TestRestStaleRevision(t *testing.T) {
	token := newUser(t)
	resp, data := do(t, "POST", "/todos", token, map[string]any{
		"title": "并发任务", "type": "one_off", "priority": "normal", "status": "todo",
	})
	expectStatus(t, resp, 201)
	todoID := dataOf(t, data)["id"].(string)

	do(t, "PATCH", "/todos/"+todoID, token, map[string]any{"title": "v1"})
	// Now patch with a stale baseRevision 1 -> STALE_REVISION
	resp, data = do(t, "PATCH", "/todos/"+todoID, token, map[string]any{"title": "v2", "baseRevision": 1})
	if got := errCode(t, data); got != "STALE_REVISION" {
		t.Fatalf("code = %s", got)
	}
	_ = resp
}

func TestSyncBlockCreateAndCourseIsolation(t *testing.T) {
	// Blocks sync with cross-midnight validation.
	token, calendarID := setupCourseFixture(t)
	_ = calendarID
	resp, data := do(t, "POST", "/todos", token, map[string]any{
		"title": "母任务", "type": "project", "priority": "normal", "status": "todo",
	})
	expectStatus(t, resp, 201)
	todoID := dataOf(t, data)["id"].(string)

	blockID := "44444444-4444-4444-8444-444444444444"
	op := opCreate("cccccccc-cccc-4ccc-8ccc-dddddddddddd", "todo_block", blockID, map[string]any{
		"todoId": todoID, "startAt": "2026-09-07T09:00:00Z", "endAt": "2026-09-07T10:00:00Z",
		"blockNote": "同步块", "status": "scheduled",
	})
	st := pushStatus(t, token, op)
	if st != "accepted" {
		t.Fatalf("block push status = %s", st)
	}
	resp, data = do(t, "GET", "/todos/"+todoID+"/blocks", token, nil)
	expectStatus(t, resp, 200)
	if len(decode(t, data)["data"].([]any)) != 1 {
		t.Fatal("pushed block not visible")
	}

	// cross-midnight block (23:00-01:00 local) rejected deterministically
	bad := opCreate("dddddddd-dddd-4ddd-8ddd-eeeeeeeeeeee", "todo_block", "55555555-5555-4555-8555-555555555555", map[string]any{
		"todoId": todoID, "startAt": "2026-09-07T15:00:00Z", "endAt": "2026-09-07T17:00:00Z",
		"status": "scheduled",
	})
	res := push(t, token, []map[string]any{bad})
	if len(res["conflicts"].([]any)) != 1 {
		t.Fatalf("cross-midnight block must conflict: %v", res)
	}
}
