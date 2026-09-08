package tests

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"testing"
)

func mcpCall(t *testing.T, token string, method string, params map[string]any) map[string]any {
	t.Helper()
	payload := map[string]any{"jsonrpc": "2.0", "id": 1, "method": method}
	if params != nil {
		payload["params"] = params
	}
	raw, _ := json.Marshal(payload)
	req, err := http.NewRequest("POST", testURL+"/api/v1/mcp", bytes.NewReader(raw))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := api.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("mcp response %s: %v", string(data), err)
	}
	return m
}

func TestMcpInitializeListAndReadTools(t *testing.T) {
	token := newUser(t)

	init := mcpCall(t, token, "initialize", map[string]any{
		"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "test", "version": "1"},
	})
	result := init["result"].(map[string]any)
	if result["protocolVersion"] != "2025-06-18" {
		t.Fatalf("protocol = %v", result["protocolVersion"])
	}

	list := mcpCall(t, token, "tools/list", nil)
	tools := list["result"].(map[string]any)["tools"].([]any)
	names := map[string]bool{}
	for _, t := range tools {
		names[t.(map[string]any)["name"].(string)] = true
	}
	required := []string{"get_current_time", "get_user_timezone", "get_courses", "get_schedule",
		"get_todos", "get_todo", "get_free_slots", "search_todos", "search_courses",
		"preview_changes", "apply_changes"}
	for _, r := range required {
		if !names[r] {
			t.Fatalf("tool %q missing; have %v", r, names)
		}
	}

	// read tool executes without confirmation
	now := mcpCall(t, token, "tools/call", map[string]any{
		"name": "get_user_timezone", "arguments": map[string]any{},
	})
	res := now["result"].(map[string]any)
	sc := res["structuredContent"].(map[string]any)
	if sc["timezone"] != "Asia/Shanghai" {
		t.Fatalf("tz = %v", sc["timezone"])
	}
}

func TestMcpPreviewApplyAtomic(t *testing.T) {
	token := newUser(t)
	calID := newCalendar(t, token, 16)
	addPeriods(t, token, calID)

	// 1. preview a batch: create todo + create course
	changes := []map[string]any{
		{
			"operation": "create", "entityType": "todo",
			"payload": map[string]any{"title": "生化大作业", "type": "project", "priority": "high", "status": "todo"},
		},
		{
			"operation": "create", "entityType": "course",
			"payload": map[string]any{
				"calendarId": calID, "name": "MCP课程",
			},
		},
	}
	resp := mcpCall(t, token, "tools/call", map[string]any{
		"name":      "preview_changes",
		"arguments": map[string]any{"changes": changes},
	})
	callRes := resp["result"].(map[string]any)
	if _, isErr := callRes["isError"]; isErr {
		t.Fatalf("preview failed: %v", callRes["content"])
	}
	sc := callRes["structuredContent"].(map[string]any)
	confirmationID, _ := sc["confirmationId"].(string)
	if confirmationID == "" {
		t.Fatal("no confirmationId from preview")
	}
	// Nothing applied yet.
	if countTodos(t, token) != 0 {
		t.Fatal("preview must not persist anything")
	}

	// 2. apply
	resp = mcpCall(t, token, "tools/call", map[string]any{
		"name": "apply_changes", "arguments": map[string]any{"confirmationId": confirmationID},
	})
	callRes = resp["result"].(map[string]any)
	sc = callRes["structuredContent"].(map[string]any)
	if sc["applied"] != true {
		t.Fatalf("apply failed: %v", callRes)
	}
	if countTodos(t, token) != 1 {
		t.Fatal("apply should persist exactly one todo")
	}

	// 3. apply again -> CONFIRMATION_EXPIRED
	resp = mcpCall(t, token, "tools/call", map[string]any{
		"name": "apply_changes", "arguments": map[string]any{"confirmationId": confirmationID},
	})
	callRes = resp["result"].(map[string]any)
	if callRes["isError"] != true {
		t.Fatalf("double apply should error: %v", callRes)
	}

	// 4. blocks for the todo in a second change set
	todoID := firstTodoID(t, token)
	changes2 := []map[string]any{
		{
			"operation": "create", "entityType": "todo_block",
			"payload": map[string]any{
				"todoId": todoID, "startAt": "2026-09-08T09:00:00Z",
				"endAt": "2026-09-08T10:00:00Z", "blockNote": "查资料", "status": "scheduled",
			},
		},
		{
			"operation": "create", "entityType": "todo_block",
			"payload": map[string]any{
				"todoId": todoID, "startAt": "2026-09-09T09:00:00Z",
				"endAt": "2026-09-09T10:30:00Z", "blockNote": "分析数据", "status": "scheduled",
			},
		},
	}
	resp = mcpCall(t, token, "tools/call", map[string]any{
		"name":      "preview_changes",
		"arguments": map[string]any{"changes": changes2},
	})
	callRes = resp["result"].(map[string]any)
	sc = callRes["structuredContent"].(map[string]any)
	if sc["confirmationId"] == "" {
		t.Fatalf("block preview failed: %v", callRes)
	}
	// The preview must carry a soft-conflict note on a block that overlaps the
	// Wednesday course if applicable; at minimum it lists two effects.
	effects := sc["changes"].([]any)
	if len(effects) != 2 {
		t.Fatalf("effects = %d", len(effects))
	}
	resp = mcpCall(t, token, "tools/call", map[string]any{
		"name": "apply_changes", "arguments": map[string]any{"confirmationId": sc["confirmationId"].(string)},
	})
	callRes = resp["result"].(map[string]any)
	if _, isErr := callRes["isError"]; isErr {
		t.Fatalf("block apply failed: %v", callRes)
	}

	// 5. an invalid batch (orphan block) fails the preview with no id.
	resp = mcpCall(t, token, "tools/call", map[string]any{
		"name": "preview_changes",
		"arguments": map[string]any{"changes": []map[string]any{{
			"operation": "create", "entityType": "todo_block",
			"payload": map[string]any{
				"startAt": "2026-09-08T09:00:00Z", "endAt": "2026-09-08T10:00:00Z",
			},
		}}},
	})
	callRes = resp["result"].(map[string]any)
	if callRes["isError"] != true {
		t.Fatalf("orphan block preview should error: %v", callRes)
	}
}

func firstTodoID(t *testing.T, token string) string {
	t.Helper()
	resp, data := do(t, "GET", "/todos", token, nil)
	expectStatus(t, resp, 200)
	arr := decode(t, data)["data"].([]any)
	if len(arr) == 0 {
		t.Fatal("no todos")
	}
	return arr[0].(map[string]any)["id"].(string)
}

func countTodos(t *testing.T, token string) int {
	t.Helper()
	resp, data := do(t, "GET", "/todos", token, nil)
	expectStatus(t, resp, 200)
	return len(decode(t, data)["data"].([]any))
}

func TestMcpWriteToolPreviewsSingleChange(t *testing.T) {
	token := newUser(t)
	// create_todo returns a preview with confirmationId; nothing persisted.
	resp := mcpCall(t, token, "tools/call", map[string]any{
		"name": "create_todo",
		"arguments": map[string]any{
			"payload": map[string]any{"title": "单项任务", "type": "one_off", "priority": "normal", "status": "todo"},
		},
	})
	callRes := resp["result"].(map[string]any)
	if _, isErr := callRes["isError"]; isErr {
		t.Fatalf("create_todo failed: %v", callRes)
	}
	sc := callRes["structuredContent"].(map[string]any)
	id, _ := sc["confirmationId"].(string)
	if id == "" {
		t.Fatal("no confirmationId")
	}
	if countTodos(t, token) != 0 {
		t.Fatal("create_todo must not write without apply")
	}
	// apply persists
	mcpCall(t, token, "tools/call", map[string]any{
		"name": "apply_changes", "arguments": map[string]any{"confirmationId": id},
	})
	if countTodos(t, token) != 1 {
		t.Fatal("todo missing after apply")
	}
}

func TestAgentChangesHttpEndpoints(t *testing.T) {
	token := newUser(t)
	body := map[string]any{"changes": []map[string]any{{
		"operation": "create", "entityType": "todo",
		"payload": map[string]any{"title": "HTTP代理任务", "type": "one_off", "priority": "normal", "status": "todo"},
	}}}
	resp, data := do(t, "POST", "/agent/changes/preview", token, body)
	expectStatus(t, resp, 200)
	confirmationID := dataOf(t, data)["confirmationId"].(string)
	resp, data = do(t, "POST", "/agent/changes/apply", token, map[string]any{"confirmationId": confirmationID})
	expectStatus(t, resp, 200)
	if dataOf(t, data)["applied"] != true {
		t.Fatal("apply failed")
	}
}
