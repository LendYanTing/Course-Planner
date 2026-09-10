// Package mcp serves the Model Context Protocol tool surface over
// streamable HTTP (JSON-RPC 2.0 at POST /api/v1/mcp). Read tools execute
// directly; write tools never mutate — they build change sets and return a
// confirmationId that the client must confirm via apply_changes
// (docs/mcp.md). Tool handlers call the same domain services as REST.
//
// The transport is intentionally stateless: no Mcp-Session-Id is issued and
// no SSE stream is offered, so GET/DELETE answer 405 and every request is
// self-contained (docs/mcp.md §12).
package mcp

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

// protocolVersion is the newest revision this server implements. Older
// revisions are accepted on initialize so an existing client keeps working.
const protocolVersion = "2025-06-18"

// serverVersion is reported to clients in initialize.
const serverVersion = "1.1.0"

var supportedProtocolVersions = []string{"2025-06-18", "2025-03-26", "2024-11-05"}

// instructions is returned by initialize: the standing orders an agent needs
// before it starts calling tools (docs/mcp.md §4, §8).
const instructions = `Course Planner exposes one user's courses, recurring schedules, todos and todo blocks.

- Read tools (get_*, search_*) execute immediately and are safe to call freely.
- Writes never happen directly. Call preview_changes (or a create_/update_/delete_ tool) to get a confirmationId, show the returned summary to the user, and only then call apply_changes. The whole change set is applied in one transaction.
- Never invent free time: call get_free_slots before scheduling and get_calendar before assuming a slot is empty. Courses are hard conflicts; recurring schedules and todo blocks are soft conflicts.
- Datetimes in arguments are UTC RFC3339. Results carry both the UTC instant and display* fields already rendered in the user's immutable timezone; always interpret and repeat wall-clock times in that timezone.
- When a tool returns isError, surface the error code to the user instead of retrying blindly.`

// ToolResult is what a tool handler returns.
type ToolResult struct {
	Content []map[string]any `json:"content"`
	Data    map[string]any   `json:"structuredContent,omitempty"`
	IsError bool             `json:"isError,omitempty"`
}

// Tool defines one MCP tool.
type Tool struct {
	Name        string
	Title       string
	Description string
	InputSchema map[string]any
	// Annotations carries the behaviour hints from docs/mcp.md §12.
	Annotations map[string]any
	// RequiresWrite is true for tools that reach a write path, so a
	// read-only credential can be refused before the handler runs.
	RequiresWrite bool
	Handler       func(ctx *ReqCtx, args map[string]any) (ToolResult, error)
}

// ReqCtx carries the authenticated user and credential to tool handlers.
type ReqCtx struct {
	Ctx      context.Context
	UserID   string
	Timezone string
	Scopes   []string
}

// CanWrite reports whether the presented credential may reach write tools.
func (rc *ReqCtx) CanWrite() bool {
	for _, s := range rc.Scopes {
		if s == httpx.ScopeWrite {
			return true
		}
	}
	return false
}

// Server dispatches JSON-RPC requests to tools.
type Server struct {
	tools  []Tool
	byName map[string]Tool
}

func NewServer(tools []Tool) *Server {
	byName := map[string]Tool{}
	for _, t := range tools {
		byName[t.Name] = t
	}
	return &Server{tools: tools, byName: byName}
}

// ServeHTTP implements POST /mcp (single message; batch arrays accepted).
func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Cache-Control", "no-store")

	if r.Method != http.MethodPost {
		// No SSE stream and no sessions to terminate, so the transport
		// answers these with 405 rather than an empty event stream.
		w.Header().Set("Allow", "POST")
		httpx.WriteError(w, apperr.New(http.StatusMethodNotAllowed, apperr.CodeInvalidRequest,
			"MCP endpoint accepts POST only: this server offers neither an SSE stream nor sessions"))
		return
	}
	if !acceptsJSON(r) {
		httpx.WriteError(w, apperr.New(http.StatusNotAcceptable, apperr.CodeInvalidRequest,
			"Accept header must allow application/json"))
		return
	}
	if v := r.Header.Get("MCP-Protocol-Version"); v != "" && !isSupportedProtocol(v) {
		writeJSONRPC(w, http.StatusBadRequest, rpcError(nil, -32600, "unsupported protocol version: "+v))
		return
	}

	var raw json.RawMessage
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&raw); err != nil {
		writeRPCError(w, nil, -32700, "parse error")
		return
	}
	if len(raw) > 0 && raw[0] == '[' {
		var batch []json.RawMessage
		if err := json.Unmarshal(raw, &batch); err != nil {
			writeRPCError(w, nil, -32700, "parse error")
			return
		}
		results := make([]map[string]any, 0, len(batch))
		for _, msg := range batch {
			body, _ := s.handleOne(r, msg)
			if body != nil {
				results = append(results, body)
			}
		}
		// A batch of nothing but notifications has no response to send.
		if len(results) == 0 {
			w.WriteHeader(http.StatusAccepted)
			return
		}
		writeJSONRPC(w, http.StatusOK, results)
		return
	}
	body, status := s.handleOne(r, raw)
	if body == nil {
		w.WriteHeader(status)
		return
	}
	writeJSONRPC(w, status, body)
}

// acceptsJSON reports whether the client will accept a JSON response. The
// streamable-HTTP spec asks clients for `application/json, text/event-stream`;
// a client that only accepts event streams cannot be served here.
func acceptsJSON(r *http.Request) bool {
	accept := r.Header.Get("Accept")
	if accept == "" {
		return true
	}
	for _, part := range strings.Split(accept, ",") {
		media := strings.TrimSpace(strings.SplitN(part, ";", 2)[0])
		switch media {
		case "application/json", "application/*", "*/*":
			return true
		}
	}
	return false
}

func isSupportedProtocol(v string) bool {
	for _, s := range supportedProtocolVersions {
		if s == v {
			return true
		}
	}
	return false
}

// negotiateProtocol echoes the client's revision when supported, otherwise
// answers with the newest one we implement.
func negotiateProtocol(requested string) string {
	if isSupportedProtocol(requested) {
		return requested
	}
	return protocolVersion
}

// handleOne processes one message. A nil body means "no response": the status
// then carries the sole meaning (202 for notifications).
func (s *Server) handleOne(r *http.Request, raw json.RawMessage) (map[string]any, int) {
	var msg struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(raw, &msg); err != nil {
		return rpcError(nil, -32700, "parse error"), http.StatusOK
	}
	// Notifications (and id-less messages) never get a reply, including
	// when they carry an error.
	if len(msg.ID) == 0 || string(msg.ID) == "null" {
		return nil, http.StatusAccepted
	}
	respond := func(result any, code int, message string) (map[string]any, int) {
		if code != 0 {
			return rpcError(msg.ID, code, message), http.StatusOK
		}
		return map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": result}, http.StatusOK
	}

	switch msg.Method {
	case "initialize":
		var params struct {
			ProtocolVersion string `json:"protocolVersion"`
		}
		_ = json.Unmarshal(msg.Params, &params)
		return respond(map[string]any{
			"protocolVersion": negotiateProtocol(params.ProtocolVersion),
			"capabilities":    map[string]any{"tools": map[string]any{"listChanged": false}},
			"serverInfo":      map[string]any{"name": "course-planner", "title": "Course Planner", "version": serverVersion},
			"instructions":    instructions,
		}, 0, "")
	case "notifications/initialized", "notifications/cancelled":
		return nil, http.StatusAccepted
	case "ping":
		return respond(map[string]any{}, 0, "")
	case "tools/list":
		tools := make([]map[string]any, 0, len(s.tools))
		for _, t := range s.tools {
			entry := map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"inputSchema": t.InputSchema,
			}
			if t.Title != "" {
				entry["title"] = t.Title
			}
			if len(t.Annotations) > 0 {
				entry["annotations"] = t.Annotations
			}
			tools = append(tools, entry)
		}
		return respond(map[string]any{"tools": tools}, 0, "")
	case "tools/call":
		var params struct {
			Name      string          `json:"name"`
			Arguments json.RawMessage `json:"arguments"`
		}
		if err := json.Unmarshal(msg.Params, &params); err != nil {
			return respond(nil, -32602, "invalid params")
		}
		tool, ok := s.byName[params.Name]
		if !ok {
			return respond(nil, -32602, "unknown tool: "+params.Name)
		}
		args := map[string]any{}
		if len(params.Arguments) > 0 {
			if err := json.Unmarshal(params.Arguments, &args); err != nil {
				return respond(nil, -32602, "invalid arguments")
			}
		}
		reqCtx := &ReqCtx{
			Ctx:      r.Context(),
			UserID:   httpx.UserID(r.Context()),
			Timezone: httpx.Timezone(r.Context()),
			Scopes:   httpx.Scopes(r.Context()),
		}
		if tool.RequiresWrite && !reqCtx.CanWrite() {
			return respond(map[string]any{
				"content": []map[string]any{{"type": "text", "text": "FORBIDDEN: this MCP credential is read-only. Ask the user for a token that includes the write scope."}},
				"isError": true,
			}, 0, "")
		}
		result, err := tool.Handler(reqCtx, args)
		if err != nil {
			// Tool-level failures are results with isError, not protocol errors.
			if ae, ok := apperr.From(err); ok {
				return respond(map[string]any{
					"content": []map[string]any{{"type": "text", "text": ae.Code + ": " + ae.Message}},
					"isError": true,
				}, 0, "")
			}
			return respond(map[string]any{
				"content": []map[string]any{{"type": "text", "text": "internal error"}},
				"isError": true,
			}, 0, "")
		}
		out := map[string]any{
			"content": result.Content,
		}
		if result.Data != nil {
			out["structuredContent"] = result.Data
		}
		if result.IsError {
			out["isError"] = true
		}
		return respond(out, 0, "")
	default:
		return respond(nil, -32601, "method not found: "+msg.Method)
	}
}

func textResult(text string) ToolResult {
	return ToolResult{Content: []map[string]any{{"type": "text", "text": text}}}
}

func dataResult(data map[string]any) ToolResult {
	b, _ := json.Marshal(data)
	return ToolResult{
		Content: []map[string]any{{"type": "text", "text": string(b)}},
		Data:    data,
	}
}

func writeRPCError(w http.ResponseWriter, id json.RawMessage, code int, message string) {
	writeJSONRPC(w, http.StatusOK, rpcError(id, code, message))
}

func rpcError(id json.RawMessage, code int, message string) map[string]any {
	if id == nil {
		id = json.RawMessage("null")
	}
	return map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   map[string]any{"code": code, "message": message},
	}
}

func writeJSONRPC(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
