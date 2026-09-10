package tests

import (
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"testing"
)

// ---- helpers -----------------------------------------------------------------

// rawReq drives any path (including the non-/api/v1 connect page) with full
// control over method and headers. Redirects are surfaced instead of followed
// so the connect flow can be asserted on its Location header.
func rawReq(t *testing.T, method, path, token string, headers map[string]string, body string) (*http.Response, []byte) {
	t.Helper()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	req, err := http.NewRequest(method, testURL+path, reader)
	if err != nil {
		t.Fatal(err)
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	resp, err := noRedirectClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(resp.Body)
	return resp, data
}

var noRedirectClient = &http.Client{
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

func mcpCallWithHeaders(t *testing.T, token, method string, params map[string]any, headers map[string]string) (map[string]any, *http.Response) {
	t.Helper()
	payload := map[string]any{"jsonrpc": "2.0", "id": 1, "method": method}
	if params != nil {
		payload["params"] = params
	}
	raw, _ := json.Marshal(payload)
	h := map[string]string{"Content-Type": "application/json"}
	for k, v := range headers {
		h[k] = v
	}
	resp, data := rawReq(t, "POST", "/api/v1/mcp", token, h, string(raw))
	var m map[string]any
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("mcp response %s: %v", string(data), err)
	}
	return m, resp
}

// mintToken creates a long-lived credential through the REST surface.
func mintToken(t *testing.T, session string, scopes []string, expiresInDays int) (string, map[string]any) {
	t.Helper()
	body := map[string]any{"name": "test client"}
	if scopes != nil {
		body["scopes"] = scopes
	}
	if expiresInDays != 0 {
		body["expiresInDays"] = expiresInDays
	}
	resp, data := do(t, "POST", "/mcp-tokens", session, body)
	expectStatus(t, resp, 200)
	d := dataOf(t, data)
	secret, _ := d["token"].(string)
	if secret == "" {
		t.Fatalf("no token in %s", string(data))
	}
	return secret, d
}

func toolResult(t *testing.T, resp map[string]any) map[string]any {
	t.Helper()
	res, ok := resp["result"].(map[string]any)
	if !ok {
		t.Fatalf("no result in %v", resp)
	}
	return res
}

// ---- long-lived credentials --------------------------------------------------

func TestMcpLongLivedTokenLifecycle(t *testing.T) {
	session := newUser(t)
	secret, record := mintToken(t, session, nil, 0)

	if !strings.HasPrefix(secret, "cpmcp_") {
		t.Fatalf("token %q is not an MCP credential", secret)
	}
	if record["expiresAt"] != nil {
		t.Fatal("a default token must not expire")
	}
	if record["tokenPrefix"] == secret {
		t.Fatal("the listing prefix must not be the secret")
	}

	// 1. read tools work with the long-lived credential.
	resp, httpResp := mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "get_user_timezone", "arguments": map[string]any{},
	}, nil)
	expectStatus(t, httpResp, 200)
	sc := toolResult(t, resp)["structuredContent"].(map[string]any)
	if sc["timezone"] != "Asia/Shanghai" {
		t.Fatalf("timezone = %v", sc["timezone"])
	}

	// 2. writes still gate through preview -> apply.
	resp, _ = mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "create_todo",
		"arguments": map[string]any{
			"payload": map[string]any{"title": "长效令牌任务", "type": "one_off", "priority": "normal", "status": "todo"},
		},
	}, nil)
	sc = toolResult(t, resp)["structuredContent"].(map[string]any)
	confirmationID, _ := sc["confirmationId"].(string)
	if confirmationID == "" {
		t.Fatalf("no confirmationId: %v", resp)
	}
	if countTodos(t, secret) != 0 {
		t.Fatal("nothing may be written before apply_changes")
	}
	resp, _ = mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "apply_changes", "arguments": map[string]any{"confirmationId": confirmationID},
	}, nil)
	if toolResult(t, resp)["structuredContent"].(map[string]any)["applied"] != true {
		t.Fatalf("apply failed: %v", resp)
	}
	if countTodos(t, secret) != 1 {
		t.Fatal("todo missing after apply")
	}

	// 3. an MCP credential must not mint further credentials...
	respBody, data := do(t, "POST", "/mcp-tokens", secret, map[string]any{"name": "nested"})
	expectStatus(t, respBody, 403)
	if errCode(t, data) != "FORBIDDEN" {
		t.Fatalf("code = %s", errCode(t, data))
	}
	// ...nor revoke them.
	respBody, _ = do(t, "DELETE", "/mcp-tokens/"+record["id"].(string), secret, nil)
	expectStatus(t, respBody, 403)

	// 4. the owner lists it (secret never returned again).
	respBody, data = do(t, "GET", "/mcp-tokens", session, nil)
	expectStatus(t, respBody, 200)
	list := decode(t, data)["data"].([]any)
	if len(list) != 1 {
		t.Fatalf("list = %v", list)
	}
	entry := list[0].(map[string]any)
	if _, leaked := entry["token"]; leaked {
		t.Fatal("listing must not expose the secret")
	}
	if entry["tokenPrefix"] != record["tokenPrefix"] {
		t.Fatalf("prefix mismatch: %v", entry)
	}

	// 5. revocation takes effect immediately.
	respBody, _ = do(t, "DELETE", "/mcp-tokens/"+record["id"].(string), session, nil)
	expectStatus(t, respBody, 204)
	respBody, _ = rawReq(t, "POST", "/api/v1/mcp", secret, map[string]string{"Content-Type": "application/json"},
		`{"jsonrpc":"2.0","id":1,"method":"tools/list"}`)
	expectStatus(t, respBody, 401)

	// A revoked token is reported as not found on a second revoke.
	respBody, _ = do(t, "DELETE", "/mcp-tokens/"+record["id"].(string), session, nil)
	expectStatus(t, respBody, 404)
}

func TestMcpTokenExpiry(t *testing.T) {
	session := newUser(t)
	secret, record := mintToken(t, session, nil, 30)
	if record["expiresAt"] == nil {
		t.Fatal("expiresInDays=30 must set expiresAt")
	}
	// The token is usable right away (the expiry is in the future).
	if _, httpResp := mcpCallWithHeaders(t, secret, "ping", nil, nil); httpResp.StatusCode != 200 {
		t.Fatalf("status = %d", httpResp.StatusCode)
	}
}

func TestMcpReadOnlyScope(t *testing.T) {
	session := newUser(t)
	secret, record := mintToken(t, session, []string{"read"}, 0)
	scopes, _ := record["scopes"].([]any)
	if len(scopes) != 1 || scopes[0] != "read" {
		t.Fatalf("scopes = %v", record["scopes"])
	}

	// Read tools are fine over MCP...
	resp, httpResp := mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "get_todos", "arguments": map[string]any{},
	}, nil)
	expectStatus(t, httpResp, 200)
	if toolResult(t, resp)["isError"] == true {
		t.Fatalf("read tool refused for a read-only token: %v", resp)
	}

	// ...but every write path is refused, at tool granularity.
	for _, call := range []map[string]any{
		{"name": "create_todo", "arguments": map[string]any{"payload": map[string]any{"title": "x", "type": "one_off"}}},
		{"name": "delete_todo", "arguments": map[string]any{"entityId": "00000000-0000-0000-0000-000000000000", "payload": map[string]any{}}},
		{"name": "preview_changes", "arguments": map[string]any{"changes": []map[string]any{}}},
		{"name": "apply_changes", "arguments": map[string]any{"confirmationId": "00000000-0000-0000-0000-000000000000"}},
	} {
		resp, httpResp := mcpCallWithHeaders(t, secret, "tools/call", call, nil)
		expectStatus(t, httpResp, 200)
		res := toolResult(t, resp)
		if res["isError"] != true {
			t.Fatalf("%v must be refused for a read-only token: %v", call["name"], res)
		}
		text := res["content"].([]any)[0].(map[string]any)["text"].(string)
		if !strings.Contains(text, "FORBIDDEN") {
			t.Fatalf("%v: unexpected message %q", call["name"], text)
		}
	}

	// REST reads pass, REST writes are blocked by the write guard.
	respBody, _ := do(t, "GET", "/todos", secret, nil)
	expectStatus(t, respBody, 200)
	respBody, data := do(t, "POST", "/todos", secret, map[string]any{"title": "x", "type": "one_off"})
	expectStatus(t, respBody, 403)
	if errCode(t, data) != "FORBIDDEN" {
		t.Fatalf("code = %s", errCode(t, data))
	}
}

func TestMcpTokenIsRejectedForUnknownSecret(t *testing.T) {
	session := newUser(t)
	mintToken(t, session, nil, 0)
	resp, data := do(t, "GET", "/me", "cpmcp_"+strings.Repeat("A", 43), nil)
	expectStatus(t, resp, 401)
	if errCode(t, data) != "UNAUTHORIZED" {
		t.Fatalf("code = %s", errCode(t, data))
	}
}

// ---- connect page ------------------------------------------------------------

var tokenInTextarea = regexp.MustCompile(`id="tokenText" readonly>(cpmcp_[A-Za-z0-9_\-]+)<`)

func connectForm(username, password, scopes, redirect string) string {
	form := url.Values{
		"username": {username},
		"password": {password},
		"name":     {"helpers client"},
		"scopes":   {scopes},
	}
	if redirect != "" {
		form.Set("redirect_uri", redirect)
	}
	return form.Encode()
}

func TestMcpConnectPageSignsInAndReturnsToken(t *testing.T) {
	username := uniqueName("connect")
	_, session := registerNamed(t, username)

	// The form renders.
	resp, body := rawReq(t, "GET", "/mcp/connect", "", nil, "")
	expectStatus(t, resp, 200)
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/html") {
		t.Fatalf("content type = %s", ct)
	}
	if resp.Header.Get("Cache-Control") == "" || !strings.Contains(resp.Header.Get("Cache-Control"), "no-store") {
		t.Fatal("the page carries a secret and must not be cached")
	}
	if !strings.Contains(string(body), "生成 token") {
		t.Fatal("form missing")
	}

	formHeaders := map[string]string{"Content-Type": "application/x-www-form-urlencoded"}

	// Wrong password: rejected, and no credential is created.
	resp, body = rawReq(t, "POST", "/mcp/connect", "", formHeaders, connectForm(username, "wrong-password", "read", ""))
	expectStatus(t, resp, 401)
	if strings.Contains(string(body), "cpmcp_") {
		t.Fatal("a failed login must not leak a token")
	}

	// Correct password: the page renders the token exactly once.
	resp, body = rawReq(t, "POST", "/mcp/connect", "", formHeaders, connectForm(username, "password123", "read", ""))
	expectStatus(t, resp, 200)
	match := tokenInTextarea.FindSubmatch(body)
	if match == nil {
		t.Fatalf("no token rendered: %s", string(body))
	}
	secret := string(match[1])
	if !strings.Contains(string(body), "/api/v1/mcp") {
		t.Fatal("page must show the endpoint")
	}

	// The token it printed actually works, and is read-only as requested.
	resp2, _ := mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "get_todos", "arguments": map[string]any{},
	}, nil)
	if toolResult(t, resp2)["isError"] == true {
		t.Fatalf("issued token cannot read: %v", resp2)
	}
	resp3, _ := mcpCallWithHeaders(t, secret, "tools/call", map[string]any{
		"name": "create_todo", "arguments": map[string]any{"payload": map[string]any{"title": "x", "type": "one_off"}},
	}, nil)
	if toolResult(t, resp3)["isError"] != true {
		t.Fatal("a read-only connect token must not write")
	}

	// The same session token can list what the page created.
	respBody, data := do(t, "GET", "/mcp-tokens", session, nil)
	expectStatus(t, respBody, 200)
	if len(decode(t, data)["data"].([]any)) != 1 {
		t.Fatal("connect must register exactly one credential")
	}
}

func TestMcpConnectPageRedirectHandling(t *testing.T) {
	username := uniqueName("connectredir")
	registerNamed(t, username)
	formHeaders := map[string]string{"Content-Type": "application/x-www-form-urlencoded"}

	// A non-loopback redirect_uri is dropped: the token is shown in the page
	// instead, never forwarded to a third party.
	resp, body := rawReq(t, "POST", "/mcp/connect", "", formHeaders,
		connectForm(username, "password123", "write", "https://evil.example/callback"))
	expectStatus(t, resp, 200)
	if resp.Header.Get("Location") != "" {
		t.Fatalf("must not redirect to %q", resp.Header.Get("Location"))
	}
	if !tokenInTextarea.Match(body) {
		t.Fatal("token should be rendered in the page")
	}

	// A loopback redirect is followed, with the secret handed to the helper.
	resp, _ = rawReq(t, "POST", "/mcp/connect", "", formHeaders,
		connectForm(username, "password123", "write", "http://127.0.0.1:8123/callback"))
	expectStatus(t, resp, 303)
	location := resp.Header.Get("Location")
	if !strings.HasPrefix(location, "http://127.0.0.1:8123/callback?") {
		t.Fatalf("location = %q", location)
	}
	parsed, err := url.Parse(location)
	if err != nil {
		t.Fatal(err)
	}
	secret := parsed.Query().Get("token")
	if !strings.HasPrefix(secret, "cpmcp_") {
		t.Fatalf("token = %q", secret)
	}
	if parsed.Query().Get("tokenId") == "" {
		t.Fatal("redirect must include the token id so it can be revoked")
	}
	if _, httpResp := mcpCallWithHeaders(t, secret, "tools/list", nil, nil); httpResp.StatusCode != 200 {
		t.Fatalf("redirected token unusable: %d", httpResp.StatusCode)
	}
}

func TestMcpConnectPageRejectsCrossSitePost(t *testing.T) {
	username := uniqueName("connectcsrf")
	registerNamed(t, username)

	resp, body := rawReq(t, "POST", "/mcp/connect", "", map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Origin":       "https://evil.example",
	}, connectForm(username, "password123", "write", ""))
	expectStatus(t, resp, 403)
	if tokenInTextarea.Match(body) || strings.Contains(string(body), "cpmcp_") {
		t.Fatal("a cross-site post must never mint a token")
	}
}

// In-app webviews report an opaque origin (`Origin: null`) for ordinary form
// posts, which must not be mistaken for a cross-site attempt.
func TestMcpConnectPageAcceptsOpaqueOrigin(t *testing.T) {
	username := uniqueName("connectwebview")
	registerNamed(t, username)
	formHeaders := map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Origin":       "null",
	}

	resp, _ := rawReq(t, "GET", "/mcp/connect", "", map[string]string{"Origin": "null"}, "")
	expectStatus(t, resp, 200)

	resp, body := rawReq(t, "POST", "/mcp/connect", "", formHeaders, connectForm(username, "password123", "write", ""))
	expectStatus(t, resp, 200)
	if !tokenInTextarea.Match(body) {
		t.Fatalf("webview login failed: %s", string(body))
	}

	// An opaque origin still gets its Referer checked when the browser sends
	// one, so a cross-site post cannot hide behind `null`.
	resp, body = rawReq(t, "POST", "/mcp/connect", "", map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Origin":       "null",
		"Referer":      "https://evil.example/attack.html",
	}, connectForm(username, "password123", "write", ""))
	expectStatus(t, resp, 403)
	if strings.Contains(string(body), "cpmcp_") {
		t.Fatal("mismatched referer must not mint a token")
	}
}

// A failure the user cannot retry their way out of must not render the form
// again, otherwise they type the password in a loop.
func TestMcpConnectOriginFailureHasNoRetryForm(t *testing.T) {
	resp, body := rawReq(t, "POST", "/mcp/connect", "", map[string]string{
		"Content-Type": "application/x-www-form-urlencoded",
		"Origin":       "https://evil.example",
	}, connectForm("whoever", "password123", "read", ""))
	expectStatus(t, resp, 403)
	if strings.Contains(string(body), `name="password"`) {
		t.Fatal("a 403 for the wrong origin should not offer a retry form")
	}
}

// ---- transport behaviour -----------------------------------------------------

func TestMcpTransportMethodAndHeaderRules(t *testing.T) {
	token := newUser(t)

	for _, method := range []string{"GET", "DELETE"} {
		resp, _ := rawReq(t, method, "/api/v1/mcp", token, nil, "")
		expectStatus(t, resp, 405)
		if allow := resp.Header.Get("Allow"); allow != "POST" {
			t.Fatalf("%s Allow = %q", method, allow)
		}
	}

	// A client that only accepts an event stream cannot be served.
	resp, _ := rawReq(t, "POST", "/api/v1/mcp", token, map[string]string{
		"Content-Type": "application/json",
		"Accept":       "text/event-stream",
	}, `{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	expectStatus(t, resp, 406)

	// The event-stream-inclusive Accept that real clients send is fine.
	resp, _ = rawReq(t, "POST", "/api/v1/mcp", token, map[string]string{
		"Content-Type": "application/json",
		"Accept":       "application/json, text/event-stream",
	}, `{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	expectStatus(t, resp, 200)

	// An unsupported pinned protocol version is refused outright.
	resp, _ = rawReq(t, "POST", "/api/v1/mcp", token, map[string]string{
		"Content-Type":         "application/json",
		"MCP-Protocol-Version": "1999-01-01",
	}, `{"jsonrpc":"2.0","id":1,"method":"ping"}`)
	expectStatus(t, resp, 400)

	// A notification gets 202 with no body.
	resp, body := rawReq(t, "POST", "/api/v1/mcp", token, map[string]string{
		"Content-Type": "application/json",
	}, `{"jsonrpc":"2.0","method":"notifications/initialized"}`)
	expectStatus(t, resp, 202)
	if len(body) != 0 {
		t.Fatalf("notification body = %q", string(body))
	}
}

func TestMcpInitializeNegotiatesAndInstructs(t *testing.T) {
	token := newUser(t)

	// A supported older revision is echoed back.
	resp, _ := mcpCallWithHeaders(t, token, "initialize", map[string]any{
		"protocolVersion": "2024-11-05", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "legacy", "version": "1"},
	}, nil)
	result := toolResult(t, resp)
	if result["protocolVersion"] != "2024-11-05" {
		t.Fatalf("protocolVersion = %v", result["protocolVersion"])
	}
	instructions, _ := result["instructions"].(string)
	if !strings.Contains(instructions, "preview_changes") {
		t.Fatalf("instructions must explain the write workflow: %q", instructions)
	}
	if result["serverInfo"].(map[string]any)["name"] != "course-planner" {
		t.Fatalf("serverInfo = %v", result["serverInfo"])
	}

	// An unknown revision falls back to the newest supported one.
	resp, _ = mcpCallWithHeaders(t, token, "initialize", map[string]any{
		"protocolVersion": "1899-01-01",
	}, nil)
	if toolResult(t, resp)["protocolVersion"] != "2025-06-18" {
		t.Fatalf("fallback failed: %v", toolResult(t, resp)["protocolVersion"])
	}
}

func TestMcpToolsAdvertiseHints(t *testing.T) {
	token := newUser(t)
	resp, _ := mcpCallWithHeaders(t, token, "tools/list", nil, nil)
	tools := toolResult(t, resp)["tools"].([]any)

	byName := map[string]map[string]any{}
	for _, raw := range tools {
		entry := raw.(map[string]any)
		byName[entry["name"].(string)] = entry
	}

	want := map[string]struct {
		readOnly    bool
		destructive bool
	}{
		"get_todos":       {readOnly: true},
		"search_courses":  {readOnly: true},
		"create_todo":     {},
		"update_todo":     {},
		"delete_todo":     {destructive: true},
		"preview_changes": {},
		"apply_changes":   {destructive: true},
	}
	for name, expect := range want {
		entry, ok := byName[name]
		if !ok {
			t.Fatalf("tool %s missing", name)
		}
		if entry["title"] == "" || entry["title"] == nil {
			t.Fatalf("%s has no title", name)
		}
		ann, ok := entry["annotations"].(map[string]any)
		if !ok {
			t.Fatalf("%s has no annotations", name)
		}
		if got := ann["readOnlyHint"] == true; got != expect.readOnly {
			t.Fatalf("%s readOnlyHint = %v, want %v", name, got, expect.readOnly)
		}
		if got := ann["destructiveHint"] == true; got != expect.destructive {
			t.Fatalf("%s destructiveHint = %v, want %v", name, got, expect.destructive)
		}
	}
}
