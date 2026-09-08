// Package mcp serves the Model Context Protocol tool surface over
// streamable HTTP (JSON-RPC 2.0 at POST /mcp). Read tools execute directly;
// write tools never mutate — they build change sets and return a
// confirmationId that the client must confirm via apply_changes
// (docs/mcp.md). Tool handlers call the same domain services as REST.
package mcp

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/platform/httpx"
)

const protocolVersion = "2025-06-18"

// ToolResult is what a tool handler returns.
type ToolResult struct {
	Content []map[string]any `json:"content"`
	Data    map[string]any   `json:"structuredContent,omitempty"`
	IsError bool             `json:"isError,omitempty"`
}

// Tool defines one MCP tool.
type Tool struct {
	Name        string
	Description string
	InputSchema map[string]any
	Handler     func(ctx *ReqCtx, args map[string]any) (ToolResult, error)
}

// ReqCtx carries the authenticated user to tool handlers.
type ReqCtx struct {
	Ctx      context.Context
	UserID   string
	Timezone string
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
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		httpx.WriteError(w, apperr.InvalidRequest("MCP endpoint accepts POST only"))
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
			results = append(results, s.handleOne(w, r, msg))
		}
		writeJSONRPC(w, http.StatusOK, results)
		return
	}
	result := s.handleOne(w, r, raw)
	if result != nil {
		writeJSONRPC(w, http.StatusOK, result)
	}
}

// handleOne processes one message; returns nil for notifications.
func (s *Server) handleOne(w http.ResponseWriter, r *http.Request, raw json.RawMessage) map[string]any {
	var msg struct {
		JSONRPC string          `json:"jsonrpc"`
		ID      json.RawMessage `json:"id"`
		Method  string          `json:"method"`
		Params  json.RawMessage `json:"params"`
	}
	if err := json.Unmarshal(raw, &msg); err != nil {
		return rpcError(nil, -32700, "parse error")
	}
	isNotification := len(msg.ID) == 0 || string(msg.ID) == "null"
	respond := func(result any, code int, message string) map[string]any {
		if isNotification && code == 0 {
			return nil
		}
		if code != 0 {
			return rpcError(msg.ID, code, message)
		}
		return map[string]any{"jsonrpc": "2.0", "id": msg.ID, "result": result}
	}

	switch msg.Method {
	case "initialize":
		return respond(map[string]any{
			"protocolVersion": protocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      map[string]any{"name": "course-planner", "version": "1.0.0"},
		}, 0, "")
	case "notifications/initialized", "notifications/cancelled":
		return nil
	case "ping":
		return respond(map[string]any{}, 0, "")
	case "tools/list":
		tools := make([]map[string]any, 0, len(s.tools))
		for _, t := range s.tools {
			tools = append(tools, map[string]any{
				"name":        t.Name,
				"description": t.Description,
				"inputSchema": t.InputSchema,
			})
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
		reqCtx := &ReqCtx{Ctx: r.Context(), UserID: httpx.UserID(r.Context()), Timezone: httpx.Timezone(r.Context())}
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
