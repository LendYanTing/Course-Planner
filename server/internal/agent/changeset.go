// Package agent implements the MCP write workflow (docs/mcp.md):
// preview_changes -> confirmationId -> apply_changes, with the whole change
// set committed atomically in a single transaction. Read tools are served by
// internal/mcp; both share the same domain services as REST.
package agent

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/carryingon/courseplanner/server/internal/common/timeutil"
	"github.com/carryingon/courseplanner/server/internal/event"
	"github.com/carryingon/courseplanner/server/internal/sync"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Change is one entry of an MCP change set. Creates may omit entityId; the
// server assigns one during preview resolution so apply stays deterministic.
type Change struct {
	Operation  string         `json:"operation"` // create | update | delete
	EntityType string         `json:"entityType"`
	EntityID   string         `json:"entityId,omitempty"`
	Payload    map[string]any `json:"payload"`
}

type ChangeSet struct {
	Changes []Change `json:"changes"`
}

// Effect describes one applied change for the confirmation UI.
type Effect struct {
	Operation     string         `json:"operation"`
	EntityType    string         `json:"entityType"`
	EntityID      string         `json:"entityId"`
	Description   string         `json:"description"`
	ConflictState string         `json:"conflictState"`
	Snapshot      map[string]any `json:"snapshot,omitempty"`
}

type Preview struct {
	ConfirmationID string    `json:"confirmationId"`
	ExpiresAt      time.Time `json:"expiresAt"`
	Summary        []string  `json:"summary"`
	Effects        []Effect  `json:"changes"`
}

type Service struct {
	pool     *pgxpool.Pool
	push     *sync.PushService
	eventSvc *event.Service
	ttl      time.Duration
}

func NewService(pool *pgxpool.Pool, push *sync.PushService, eventSvc *event.Service, ttl time.Duration) *Service {
	return &Service{pool: pool, push: push, eventSvc: eventSvc, ttl: ttl}
}

// supportedEntity keeps the tool surface aligned with docs/mcp.md §3.
var supportedEntities = map[string]bool{
	sync.EntityTodo: true, sync.EntityTodoBlock: true,
	sync.EntityCourse: true, sync.EntityRecurring: true,
	sync.EntityTag: true, sync.EntityCategory: true,
	sync.EntityCalendar: true, sync.EntityPeriod: true,
	sync.EntityMeeting: true,
}

// Preview validates the change set by executing it inside a transaction that
// is always rolled back, stores the resolved changes under a confirmationId,
// and renders a confirmation preview.
func (s *Service) Preview(ctx context.Context, userID string, cs ChangeSet) (Preview, error) {
	if len(cs.Changes) == 0 {
		return Preview{}, apperr.Validation("changes", "at least one change is required")
	}
	if len(cs.Changes) > 50 {
		return Preview{}, apperr.Validation("changes", "at most 50 changes per set")
	}
	// Structural validation + id resolution.
	resolved := make([]Change, len(cs.Changes))
	for i, ch := range cs.Changes {
		switch ch.Operation {
		case sync.OpCreate, sync.OpUpdate, sync.OpDelete:
		default:
			return Preview{}, apperr.Validation("changes", fmt.Sprintf("change %d: operation must be create, update or delete", i+1))
		}
		if !supportedEntities[ch.EntityType] {
			return Preview{}, apperr.Validation("entityType", "unsupported entity type "+ch.EntityType)
		}
		if ch.Payload == nil {
			ch.Payload = map[string]any{}
		}
		if ch.EntityID == "" {
			if ch.Operation == sync.OpCreate {
				ch.EntityID = uuid.NewString()
			} else {
				return Preview{}, apperr.Validation("changes", fmt.Sprintf("change %d: entityId is required for %s", i+1, ch.Operation))
			}
		}
		resolved[i] = ch
	}

	effects, err := s.previewRollback(ctx, userID, resolved)
	if err != nil {
		return Preview{}, err
	}

	confirmationID := uuid.NewString()
	expiresAt := time.Now().Add(s.ttl)
	changesJSON, err := json.Marshal(resolved)
	if err != nil {
		return Preview{}, err
	}
	previewJSON, err := json.Marshal(effects)
	if err != nil {
		return Preview{}, err
	}
	if _, err := s.pool.Exec(ctx, `
		INSERT INTO agent_change_sets (id, user_id, changes, preview, status, expires_at)
		VALUES ($1,$2,$3,$4,'pending',$5)`,
		confirmationID, userID, changesJSON, previewJSON, expiresAt); err != nil {
		return Preview{}, err
	}

	summary := make([]string, 0, len(effects))
	for _, e := range effects {
		summary = append(summary, e.Description)
	}
	return Preview{
		ConfirmationID: confirmationID,
		ExpiresAt:      expiresAt,
		Summary:        summary,
		Effects:        effects,
	}, nil
}

// previewRollback executes the changes and always rolls back.
func (s *Service) previewRollback(ctx context.Context, userID string, resolved []Change) ([]Effect, error) {
	loc, err := s.userTz(ctx, userID)
	if err != nil {
		return nil, err
	}
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return nil, err
	}
	defer tx.Rollback(ctx)
	effects, err := s.executeAll(ctx, tx, userID, resolved, loc)
	if err != nil {
		return nil, err
	}
	return effects, tx.Rollback(ctx)
}

// Apply atomically executes a previously previewed change set.
func (s *Service) Apply(ctx context.Context, userID, confirmationID string) ([]Effect, error) {
	if _, err := uuid.Parse(confirmationID); err != nil {
		return nil, apperr.Validation("confirmationId", "must be a uuid")
	}
	var (
		changesRaw []byte
		status     string
		expiresAt  time.Time
	)
	err := s.pool.QueryRow(ctx, `SELECT changes, status, expires_at FROM agent_change_sets
		WHERE id=$1 AND user_id=$2`, confirmationID, userID).Scan(&changesRaw, &status, &expiresAt)
	if err != nil {
		return nil, apperr.ConfirmationExpired()
	}
	if status != "pending" || time.Now().After(expiresAt) {
		_, _ = s.pool.Exec(ctx, `UPDATE agent_change_sets SET status='expired' WHERE id=$1 AND status='pending'`, confirmationID)
		return nil, apperr.ConfirmationExpired()
	}
	var changes []Change
	if err := json.Unmarshal(changesRaw, &changes); err != nil {
		return nil, apperr.New(500, apperr.CodeInternal, "stored change set is corrupt")
	}
	loc, err := s.userTz(ctx, userID)
	if err != nil {
		return nil, err
	}
	var effects []Effect
	err = withTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
		var err error
		effects, err = s.executeAll(ctx, tx, userID, changes, loc)
		if err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE agent_change_sets SET status='applied', applied_at=now()
			WHERE id=$1 AND status='pending'`, confirmationID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return apperr.ConfirmationExpired()
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	return effects, nil
}

// executeAll applies changes through the sync adapters (identical semantics
// to pushed operations) and renders effects.
func (s *Service) executeAll(ctx context.Context, tx pgx.Tx, userID string, changes []Change, loc *time.Location) ([]Effect, error) {
	effects := make([]Effect, 0, len(changes))
	for _, ch := range changes {
		adapter, ok := s.push.Adapter(ch.EntityType)
		if !ok {
			return nil, apperr.Validation("entityType", "unsupported entity type "+ch.EntityType)
		}
		snap, rev, state, err := adapter.Load(ctx, userID, ch.EntityID)
		if err != nil {
			return nil, err
		}
		switch ch.Operation {
		case sync.OpCreate:
			if state == sync.StateLive {
				return nil, apperr.New(409, apperr.CodeSyncConflict, "entity already exists: "+ch.EntityID)
			}
			if err := adapter.Create(ctx, tx, userID, ch.EntityID, ch.Payload); err != nil {
				return nil, err
			}
			// The row is only visible after commit, so describe creates from
			// their payload (server fields like id are deterministic here).
			snap = map[string]any{"id": ch.EntityID, "revision": float64(1)}
			for k, v := range ch.Payload {
				snap[k] = v
			}
		case sync.OpUpdate:
			if state != sync.StateLive {
				return nil, apperr.NotFound(ch.EntityType)
			}
			if _, err := adapter.ApplyUpdate(ctx, tx, userID, ch.EntityID, ch.Payload, rev); err != nil {
				return nil, err
			}
			snap, _, _, err = adapter.Load(ctx, userID, ch.EntityID)
			if err != nil {
				return nil, err
			}
		case sync.OpDelete:
			if state == sync.StateMissing {
				return nil, apperr.NotFound(ch.EntityType)
			}
			if state == sync.StateLive {
				if err := adapter.Delete(ctx, tx, userID, ch.EntityID, rev); err != nil {
					return nil, err
				}
			}
			snap = map[string]any{"deleted": true}
		}
		effect := Effect{
			Operation:  ch.Operation,
			EntityType: ch.EntityType,
			EntityID:   ch.EntityID,
			Snapshot:   snap,
		}
		effect.ConflictState, effect.Description = s.describe(ctx, userID, ch, snap, loc)
		effects = append(effects, effect)
	}
	return effects, nil
}

// describe renders a human-readable line plus the soft-conflict state for
// todo blocks (docs/agent-behavior.md §Confirmation).
func (s *Service) describe(ctx context.Context, userID string, ch Change, snap map[string]any, loc *time.Location) (string, string) {
	switch ch.EntityType {
	case sync.EntityTodo:
		title, _ := snap["title"].(string)
		if ch.Operation == sync.OpDelete {
			return "none", fmt.Sprintf("删除待办「%s」", title)
		}
		return "none", fmt.Sprintf("%s待办「%s」", opVerb(ch.Operation), title)
	case sync.EntityTodoBlock:
		startAt, _ := snap["startAt"].(string)
		endAt, _ := snap["endAt"].(string)
		blockNote, _ := snap["blockNote"].(string)
		todoID, _ := snap["todoId"].(string)
		when := describeRange(startAt, endAt, loc)
		if ch.Operation == sync.OpDelete {
			return "none", fmt.Sprintf("删除时间块 %s", when)
		}
		conflict := "none"
		if s.eventSvc != nil && startAt != "" && endAt != "" {
			st, err1 := timeutil.ParseInstant(startAt)
			en, err2 := timeutil.ParseInstant(endAt)
			if err1 == nil && err2 == nil {
				if occs, err := s.eventSvc.CourseOccurrences(ctx, userID, st, en, loc); err == nil && len(occs) > 0 {
					conflict = "soft_conflict"
				}
			}
		}
		suffix := ""
		if blockNote != "" {
			suffix = "：" + blockNote
		}
		_ = todoID
		return conflict, fmt.Sprintf("%s时间块 %s%s", opVerb(ch.Operation), when, suffix)
	case sync.EntityCourse:
		name, _ := snap["name"].(string)
		if ch.Operation == sync.OpDelete {
			return "none", fmt.Sprintf("删除课程「%s」", name)
		}
		return "none", fmt.Sprintf("%s课程「%s」", opVerb(ch.Operation), name)
	case sync.EntityRecurring:
		title, _ := snap["title"].(string)
		if ch.Operation == sync.OpDelete {
			return "none", fmt.Sprintf("删除周期安排「%s」", title)
		}
		return "none", fmt.Sprintf("%s周期安排「%s」", opVerb(ch.Operation), title)
	default:
		name, _ := snap["name"].(string)
		if name == "" {
			name = ch.EntityType
		}
		return "none", fmt.Sprintf("%s %s", opVerb(ch.Operation), name)
	}
}

func opVerb(op string) string {
	switch op {
	case sync.OpCreate:
		return "创建"
	case sync.OpUpdate:
		return "更新"
	default:
		return "删除"
	}
}

func describeRange(startAt, endAt string, loc *time.Location) string {
	st, err1 := timeutil.ParseInstant(startAt)
	en, err2 := timeutil.ParseInstant(endAt)
	if err1 != nil || err2 != nil {
		return startAt + " ~ " + endAt
	}
	return fmt.Sprintf("%s %s-%s",
		st.In(loc).Format("1月2日 15:04"),
		st.In(loc).Format("15:04"),
		en.In(loc).Format("15:04"))
}

// userTz loads the user's timezone.
func (s *Service) userTz(ctx context.Context, userID string) (*time.Location, error) {
	var tz string
	if err := s.pool.QueryRow(ctx, `SELECT timezone FROM users WHERE id=$1`, userID).Scan(&tz); err != nil {
		return nil, apperr.NotFound("user")
	}
	return timeutil.LoadTimezone(tz)
}

func withTx(ctx context.Context, pool *pgxpool.Pool, fn func(ctx context.Context, tx pgx.Tx) error) error {
	tx, err := pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if err := fn(ctx, tx); err != nil {
		return err
	}
	return tx.Commit(ctx)
}
