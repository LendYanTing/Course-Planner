package mcp

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/carryingon/courseplanner/server/internal/agent"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/course"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/freeslot"
	"github.com/carryingon/courseplanner/server/internal/schedule"
	"github.com/carryingon/courseplanner/server/internal/todo"
)

// Deps bundles everything the tools need; wired in internal/app.
type Deps struct {
	Agent    *agent.Service
	Event    *event.Service
	FreeSlot *freeslot.Service
	Todo     *todo.Service
	Courses  *course.Service
	Schedule *schedule.Service
}

// BuildTools assembles the tool registry (docs/mcp.md §2-3).
func BuildTools(d Deps) []Tool {
	tools := []Tool{
		{
			Name:        "get_current_time",
			Description: "Current server time (UTC) plus the user's local date/time.",
			InputSchema: map[string]any{"type": "object", "properties": map[string]any{}},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				now := timeutil.Now()
				loc, _ := timeutil.LoadTimezone(rc.Timezone)
				if loc == nil {
					loc = time.UTC
				}
				return dataResult(map[string]any{
					"serverTimeUtc": now.Format(time.RFC3339),
					"userTimezone":  rc.Timezone,
					"localDateTime": now.In(loc).Format("2006-01-02 15:04"),
				}), nil
			},
		},
		{
			Name:        "get_user_timezone",
			Description: "The user's immutable IANA timezone.",
			InputSchema: map[string]any{"type": "object", "properties": map[string]any{}},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				return dataResult(map[string]any{"timezone": rc.Timezone}), nil
			},
		},
		{
			Name:        "get_calendar",
			Description: "Calendar events (courses, recurring schedules, todo blocks, deadlines) for a UTC time range.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"start": map[string]any{"type": "string", "description": "UTC RFC3339"},
					"end":   map[string]any{"type": "string", "description": "UTC RFC3339"},
				},
				"required": []string{"start", "end"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				start, end, loc, err := parseRange(rc, args)
				if err != nil {
					return ToolResult{}, err
				}
				events, err := d.Event.Events(rc.Ctx, rc.UserID, start, end, loc, event.IncludeOptions{
					Courses: true, RecurringSchedules: true, TodoBlocks: true, Deadlines: true,
				})
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0, len(events))
				for _, e := range events {
					dto := e.DTO()
					dto["displayStart"] = e.StartAt.In(loc).Format("2006-01-02 15:04")
					if e.EndAtPresent {
						dto["displayEnd"] = e.EndAt.In(loc).Format("2006-01-02 15:04")
					}
					dto["timezone"] = rc.Timezone
					out = append(out, dto)
				}
				return dataResult(map[string]any{"events": out}), nil
			},
		},
		{
			Name:        "get_courses",
			Description: "List courses (optionally filtered by calendarId), including meetings.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"calendarId": map[string]any{"type": "string"},
				},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				calendarID, _ := args["calendarId"].(string)
				list, err := d.Courses.List(rc.Ctx, rc.UserID, calendarID)
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0, len(list))
				for _, c := range list {
					dto := c.Snapshot()
					meetings, err := d.Courses.ListMeetings(rc.Ctx, rc.UserID, c.ID)
					if err == nil {
						ms := make([]map[string]any, 0, len(meetings))
						for _, m := range meetings {
							ms = append(ms, m.DTO())
						}
						dto["meetings"] = ms
					}
					out = append(out, dto)
				}
				return dataResult(map[string]any{"courses": out}), nil
			},
		},
		{
			Name:        "get_schedule",
			Description: "List recurring schedules.",
			InputSchema: map[string]any{"type": "object", "properties": map[string]any{}},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				list, err := d.Schedule.List(rc.Ctx, rc.UserID)
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0, len(list))
				for _, rs := range list {
					out = append(out, rs.DTO())
				}
				return dataResult(map[string]any{"recurringSchedules": out}), nil
			},
		},
		{
			Name:        "get_todos",
			Description: "List todos with optional status/type filters.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"status": map[string]any{"type": "string", "enum": []string{"todo", "in_progress", "completed", "cancelled"}},
					"type":   map[string]any{"type": "string", "enum": []string{"one_off", "project"}},
				},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				filter := todo.ListFilter{}
				if v, ok := args["status"].(string); ok {
					filter.Status = v
				}
				if v, ok := args["type"].(string); ok {
					filter.Type = v
				}
				list, err := d.Todo.List(rc.Ctx, rc.UserID, filter)
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0, len(list))
				for _, t := range list {
					dto := t.DTO()
					if t.DeadlineAt != nil {
						dto["displayDeadline"] = t.DeadlineAt.In(mustLoc(rc)).Format("2006-01-02 15:04")
					}
					out = append(out, dto)
				}
				return dataResult(map[string]any{"todos": out}), nil
			},
		},
		{
			Name:        "get_todo",
			Description: "Fetch one todo with its blocks.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{"todoId": map[string]any{"type": "string"}},
				"required":   []string{"todoId"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				id, _ := args["todoId"].(string)
				t, err := d.Todo.Get(rc.Ctx, rc.UserID, id)
				if err != nil {
					return ToolResult{}, err
				}
				blocks, err := d.Todo.ListBlocks(rc.Ctx, rc.UserID, t.ID)
				if err != nil {
					return ToolResult{}, err
				}
				dto := t.DTO()
				bs := make([]map[string]any, 0, len(blocks))
				for _, b := range blocks {
					bs = append(bs, b.DTO())
				}
				dto["blocks"] = bs
				return dataResult(dto), nil
			},
		},
		{
			Name:        "get_free_slots",
			Description: "Free slots of a given duration in a UTC range, avoiding courses/schedules/blocks.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"start":           map[string]any{"type": "string"},
					"end":             map[string]any{"type": "string"},
					"durationMinutes": map[string]any{"type": "integer", "minimum": 1},
					"alignment":       map[string]any{"type": "string", "enum": []string{"period", "5_minutes", "free"}},
				},
				"required": []string{"start", "end", "durationMinutes"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				start, end, loc, err := parseRange(rc, args)
				if err != nil {
					return ToolResult{}, err
				}
				minutes := 60
				if v, ok := args["durationMinutes"].(float64); ok {
					minutes = int(v)
				}
				alignment := "period"
				if v, ok := args["alignment"].(string); ok {
					alignment = v
				}
				slots, err := d.FreeSlot.Compute(rc.Ctx, rc.UserID, freeslot.Options{
					Start: start, End: end, DurationMinutes: minutes, Alignment: alignment,
					ConsiderCourses: true, ConsiderRecurring: true, ConsiderTodoBlocks: true,
				}, loc)
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0, len(slots))
				for _, s := range slots {
					dto := s.DTO()
					dto["displayStart"] = s.StartAt.In(loc).Format("2006-01-02 15:04")
					dto["displayEnd"] = s.EndAt.In(loc).Format("2006-01-02 15:04")
					out = append(out, dto)
				}
				return dataResult(map[string]any{"freeSlots": out, "timezone": rc.Timezone}), nil
			},
		},
		{
			Name:        "search_todos",
			Description: "Search todos by keyword in title/description.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{"query": map[string]any{"type": "string"}},
				"required":   []string{"query"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				q, _ := args["query"].(string)
				list, err := d.Todo.List(rc.Ctx, rc.UserID, todo.ListFilter{})
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0)
				for _, t := range list {
					if containsFold(t.Title, q) || (t.Description != nil && containsFold(*t.Description, q)) {
						out = append(out, t.DTO())
					}
				}
				return dataResult(map[string]any{"results": out}), nil
			},
		},
		{
			Name:        "search_courses",
			Description: "Search courses by keyword in name/teacher/location.",
			InputSchema: map[string]any{
				"type":       "object",
				"properties": map[string]any{"query": map[string]any{"type": "string"}},
				"required":   []string{"query"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				q, _ := args["query"].(string)
				list, err := d.Courses.List(rc.Ctx, rc.UserID, "")
				if err != nil {
					return ToolResult{}, err
				}
				out := make([]map[string]any, 0)
				for _, c := range list {
					if containsFold(c.Name, q) || strContains(c.Teacher, q) || strContains(c.Location, q) {
						out = append(out, c.Snapshot())
					}
				}
				return dataResult(map[string]any{"results": out}), nil
			},
		},
	}

	// Write tools: each previews a single-change set. Batched writes go
	// through preview_changes (below).
	for _, spec := range []struct {
		verb       string
		entityType string
	}{
		{"create", "todo"}, {"update", "todo"}, {"delete", "todo"},
		{"create", "todo_block"}, {"update", "todo_block"}, {"delete", "todo_block"},
		{"create", "course"}, {"update", "course"}, {"delete", "course"},
		{"create", "recurring_schedule"}, {"update", "recurring_schedule"}, {"delete", "recurring_schedule"},
	} {
		tools = append(tools, buildWriteTool(spec.verb, spec.entityType, d))
	}

	tools = append(tools,
		Tool{
			Name:        "preview_changes",
			Description: "Build a batched change set and return a confirmationId. Nothing is written until apply_changes.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"changes": map[string]any{
						"type": "array",
						"items": map[string]any{
							"type": "object",
							"properties": map[string]any{
								"operation":  map[string]any{"type": "string", "enum": []string{"create", "update", "delete"}},
								"entityType": map[string]any{"type": "string"},
								"entityId":   map[string]any{"type": "string"},
								"payload":    map[string]any{"type": "object"},
							},
							"required": []string{"operation", "entityType", "payload"},
						},
					},
				},
				"required": []string{"changes"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				raw, _ := json.Marshal(args["changes"])
				var changes []agent.Change
				if err := json.Unmarshal(raw, &changes); err != nil {
					return ToolResult{}, errBadChanges()
				}
				preview, err := d.Agent.Preview(rc.Ctx, rc.UserID, agent.ChangeSet{Changes: changes})
				if err != nil {
					return ToolResult{}, err
				}
				return dataResult(map[string]any{
					"confirmationId": preview.ConfirmationID,
					"expiresAt":      preview.ExpiresAt.UTC().Format(time.RFC3339),
					"summary":        preview.Summary,
					"changes":        preview.Effects,
				}), nil
			},
		},
		Tool{
			Name:        "apply_changes",
			Description: "Atomically apply a confirmed change set. Requires user confirmation of the preview.",
			InputSchema: map[string]any{
				"type": "object",
				"properties": map[string]any{
					"confirmationId": map[string]any{"type": "string", "format": "uuid"},
				},
				"required": []string{"confirmationId"},
			},
			Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
				id, _ := args["confirmationId"].(string)
				effects, err := d.Agent.Apply(rc.Ctx, rc.UserID, id)
				if err != nil {
					return ToolResult{}, err
				}
				return dataResult(map[string]any{"applied": true, "changes": effects}), nil
			},
		},
	)
	return tools
}

// buildWriteTool creates a single-change write tool that previews (never
// executes) its effect, returning a confirmationId.
func buildWriteTool(verb, entityType string, d Deps) Tool {
	name := verb + "_" + entityType
	return Tool{
		Name:        name,
		Description: fmt.Sprintf("%s a %s. Returns a preview + confirmationId; call apply_changes to execute after user confirmation.", verb, entityType),
		InputSchema: map[string]any{
			"type": "object",
			"properties": map[string]any{
				"payload":  map[string]any{"type": "object"},
				"entityId": map[string]any{"type": "string"},
			},
			"required": []string{"payload"},
		},
		Handler: func(rc *ReqCtx, args map[string]any) (ToolResult, error) {
			payload, _ := args["payload"].(map[string]any)
			if payload == nil {
				payload = map[string]any{}
			}
			entityID, _ := args["entityId"].(string)
			if verb != "create" && entityID == "" {
				return ToolResult{}, errBadChanges()
			}
			cs := agent.ChangeSet{Changes: []agent.Change{{
				Operation: verb, EntityType: entityType, EntityID: entityID, Payload: payload,
			}}}
			preview, err := d.Agent.Preview(rc.Ctx, rc.UserID, cs)
			if err != nil {
				return ToolResult{}, err
			}
			return dataResult(map[string]any{
				"confirmationId": preview.ConfirmationID,
				"expiresAt":      preview.ExpiresAt.UTC().Format(time.RFC3339),
				"summary":        preview.Summary,
				"changes":        preview.Effects,
			}), nil
		},
	}
}

// ---- helpers -----------------------------------------------------------------

func parseRange(rc *ReqCtx, args map[string]any) (time.Time, time.Time, *time.Location, error) {
	startStr, _ := args["start"].(string)
	endStr, _ := args["end"].(string)
	start, err := timeutil.ParseInstant(startStr)
	if err != nil {
		return time.Time{}, time.Time{}, nil, err
	}
	end, err := timeutil.ParseInstant(endStr)
	if err != nil {
		return time.Time{}, time.Time{}, nil, err
	}
	if !end.After(start) {
		return time.Time{}, time.Time{}, nil, errRange()
	}
	if end.Sub(start) > 62*24*time.Hour {
		return time.Time{}, time.Time{}, nil, errRangeBig()
	}
	loc, _ := timeutil.LoadTimezone(rc.Timezone)
	if loc == nil {
		loc = time.UTC
	}
	return start, end, loc, nil
}

func mustLoc(rc *ReqCtx) *time.Location {
	loc, _ := timeutil.LoadTimezone(rc.Timezone)
	if loc == nil {
		return time.UTC
	}
	return loc
}

func containsFold(s, q string) bool {
	if q == "" {
		return false
	}
	return indexOfFold(s, q) >= 0
}

func indexOfFold(s, q string) int {
	ls, lq := lower(s), lower(q)
	for i := 0; i+len(lq) <= len(ls); i++ {
		if ls[i:i+len(lq)] == lq {
			return i
		}
	}
	return -1
}

func lower(s string) string {
	out := []rune(s)
	for i, r := range out {
		if r >= 'A' && r <= 'Z' {
			out[i] = r + 32
		}
	}
	return string(out)
}

func strContains(p *string, q string) bool {
	if p == nil {
		return false
	}
	return containsFold(*p, q)
}
