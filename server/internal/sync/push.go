package sync

import (
	"context"
	"encoding/json"

	"github.com/carryingon/courseplanner/server/internal/common/apperr"
	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// EntityState classifies an entity for push handling.
type EntityState int

const (
	StateMissing EntityState = iota // row does not exist
	StateLive                       // exists, not deleted
	StateDeleted                    // tombstoned
)

// EntityAdapter plugs a domain entity into the push engine. Adapters live in
// each domain package (they need repo access); the engine stays generic.
type EntityAdapter interface {
	// Load returns the live snapshot, its revision and row state.
	Load(ctx context.Context, userID, entityID string) (snap map[string]any, revision int64, state EntityState, err error)
	// Create inserts the entity with the client-chosen id.
	Create(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any) error
	// ApplyUpdate patches fields at the given base revision (optimistic).
	ApplyUpdate(ctx context.Context, tx pgx.Tx, userID, entityID string, fields map[string]any, baseRevision int64) (newRevision int64, err error)
	// Delete tombstones at the given base revision.
	Delete(ctx context.Context, tx pgx.Tx, userID, entityID string, baseRevision int64) error
}

// Wire types (docs/sync-protocol.md).

type PushOperation struct {
	OperationID  string         `json:"operationId"`
	EntityType   string         `json:"entityType"`
	EntityID     string         `json:"entityId"`
	Operation    string         `json:"operation"`
	BaseRevision int64          `json:"baseRevision"`
	Changes      map[string]any `json:"changes"`
}

type PushRequest struct {
	BaseCursor int64           `json:"baseCursor"`
	Operations []PushOperation `json:"operations"`
}

type ConflictEntry struct {
	OperationID       string         `json:"operationId"`
	EntityType        string         `json:"entityType"`
	EntityID          string         `json:"entityId"`
	Base              map[string]any `json:"base"`
	Local             map[string]any `json:"local"`
	Server            map[string]any `json:"server"`
	ConflictingFields []string       `json:"conflictingFields"`
}

type PushResponseData struct {
	Accepted     []string        `json:"accepted"`
	Merged       []string        `json:"merged"`
	Conflicts    []ConflictEntry `json:"conflicts"`
	ServerCursor int64           `json:"serverCursor"`
}

// OpResult is the durable per-operation outcome stored for idempotent replay.
type OpResult struct {
	Status   string         `json:"status"` // accepted | merged | conflict | rejected
	Revision int64          `json:"revision,omitempty"`
	Snapshot map[string]any `json:"snapshot,omitempty"`
	Conflict *ConflictEntry `json:"conflict,omitempty"`
	Error    string         `json:"error,omitempty"`
}

// PushService executes pushed client operations with idempotency and
// field-aware three-way merge.
type PushService struct {
	pool     *pgxpool.Pool
	journal  *Journal
	adapters map[string]EntityAdapter
}

func NewPushService(pool *pgxpool.Pool, journal *Journal) *PushService {
	return &PushService{pool: pool, journal: journal, adapters: map[string]EntityAdapter{}}
}

func (s *PushService) Register(entityType string, adapter EntityAdapter) {
	s.adapters[entityType] = adapter
}

// Adapter exposes the registered adapter for an entity type (shared with the
// agent change-set engine).
func (s *PushService) Adapter(entityType string) (EntityAdapter, bool) {
	a, ok := s.adapters[entityType]
	return a, ok
}

// Push processes each operation in its own transaction and aggregates results.
func (s *PushService) Push(ctx context.Context, userID string, req PushRequest) (PushResponseData, error) {
	out := PushResponseData{Accepted: []string{}, Merged: []string{}, Conflicts: []ConflictEntry{}}
	for _, op := range req.Operations {
		res, err := s.processOne(ctx, userID, op)
		if err != nil {
			return out, err
		}
		switch res.Status {
		case "accepted":
			out.Accepted = append(out.Accepted, op.OperationID)
		case "merged":
			out.Merged = append(out.Merged, op.OperationID)
		case "conflict":
			if res.Conflict != nil {
				out.Conflicts = append(out.Conflicts, *res.Conflict)
			}
		case "rejected":
			// Replayed rejections surface as conflicts with the error text.
			out.Conflicts = append(out.Conflicts, ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Server: map[string]any{"error": res.Error},
			})
		}
	}
	cursor, err := s.journal.CurrentCursor(ctx, userID)
	if err != nil {
		return out, err
	}
	out.ServerCursor = cursor
	return out, nil
}

func (s *PushService) processOne(ctx context.Context, userID string, op PushOperation) (OpResult, error) {
	if _, err := uuid.Parse(op.OperationID); err != nil {
		return OpResult{}, apperr.Validation("operationId", "must be a uuid")
	}
	if _, err := uuid.Parse(op.EntityID); err != nil {
		return OpResult{}, apperr.Validation("entityId", "must be a uuid")
	}
	switch op.Operation {
	case OpCreate, OpUpdate, OpDelete:
	default:
		return OpResult{}, apperr.Validation("operation", "must be create, update or delete")
	}
	adapter, ok := s.adapters[op.EntityType]
	if !ok {
		return OpResult{}, apperr.Validation("entityType", "unsupported entity type "+op.EntityType)
	}

	// 1. Idempotency claim.
	claimed, err := s.claim(ctx, userID, op.OperationID)
	if err != nil {
		return OpResult{}, err
	}
	if !claimed {
		return s.loadStoredResult(ctx, userID, op.OperationID)
	}

	// 2. Execute.
	res, execErr := s.execute(ctx, userID, op, adapter)

	// 3. Persist the outcome for replays.
	if execErr != nil {
		if aerr, ok2 := apperr.From(execErr); ok2 && aerr.Status < 500 {
			// Validation-style failures are deterministic conflicts.
			res = OpResult{Status: "conflict", Error: aerr.Code + ": " + aerr.Message,
				Conflict: &ConflictEntry{
					OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
					Server: map[string]any{"error": aerr.Code, "message": aerr.Message},
				}}
		} else {
			res = OpResult{Status: "rejected", Error: "internal error"}
		}
	}
	if err := s.storeResult(ctx, userID, op.OperationID, res); err != nil {
		return OpResult{}, err
	}
	if execErr != nil && res.Status == "rejected" {
		return res, execErr
	}
	return res, nil
}

func (s *PushService) execute(ctx context.Context, userID string, op PushOperation, adapter EntityAdapter) (OpResult, error) {
	snap, rev, state, err := adapter.Load(ctx, userID, op.EntityID)
	if err != nil {
		return OpResult{}, err
	}

	switch op.Operation {
	case OpCreate:
		switch state {
		case StateLive:
			// Entity-level idempotent replay? Compare payload to server state.
			if sameEntity(op.Changes, snap) {
				return OpResult{Status: "accepted", Revision: rev, Snapshot: snap}, nil
			}
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Local: op.Changes, Server: snap,
				ConflictingFields: diffFields(op.Changes, snap),
			}}, nil
		case StateDeleted:
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Local: op.Changes, Server: map[string]any{"deleted": true, "revision": rev},
			}}, nil
		}
		var created map[string]any
		err := withTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return adapter.Create(ctx, tx, userID, op.EntityID, op.Changes)
		})
		if err != nil {
			return OpResult{}, err
		}
		// Post-commit read-back (inside the transaction the row would be
		// invisible to pool-backed reads).
		created, _, st, err := adapter.Load(ctx, userID, op.EntityID)
		if err != nil {
			return OpResult{}, err
		}
		if st != StateLive {
			return OpResult{}, apperr.New(500, apperr.CodeInternal, "entity not live after create")
		}
		return OpResult{Status: "accepted", Snapshot: created}, nil

	case OpUpdate:
		switch state {
		case StateMissing:
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Local: op.Changes, Server: map[string]any{"missing": true},
			}}, nil
		case StateDeleted:
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Local: op.Changes, Server: map[string]any{"deleted": true, "revision": rev},
			}}, nil
		}
		// Fast path: revision matches base -> direct apply.
		if rev == op.BaseRevision {
			var newRev int64
			err := withTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
				var err error
				newRev, err = adapter.ApplyUpdate(ctx, tx, userID, op.EntityID, op.Changes, op.BaseRevision)
				return err
			})
			if err != nil {
				return OpResult{}, err
			}
			return OpResult{Status: "accepted", Revision: newRev}, nil
		}
		// Three-way merge.
		base, err := s.journal.SnapshotAtRevision(ctx, userID, op.EntityType, op.EntityID, op.BaseRevision)
		if err != nil {
			return OpResult{}, err
		}
		if base == nil {
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Local: op.Changes, Server: snap,
				ConflictingFields: []string{"revision"},
			}}, nil
		}
		patch, conflicts := threeWay(base, op.Changes, snap)
		if len(conflicts) > 0 {
			return OpResult{Status: "conflict", Conflict: &ConflictEntry{
				OperationID: op.OperationID, EntityType: op.EntityType, EntityID: op.EntityID,
				Base: base, Local: op.Changes, Server: snap, ConflictingFields: conflicts,
			}}, nil
		}
		if len(patch) == 0 {
			// Client's changes were already absorbed server-side.
			return OpResult{Status: "merged", Revision: rev, Snapshot: snap}, nil
		}
		var newRev int64
		err = withTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			var err error
			newRev, err = adapter.ApplyUpdate(ctx, tx, userID, op.EntityID, patch, rev)
			return err
		})
		if err != nil {
			return OpResult{}, err
		}
		return OpResult{Status: "merged", Revision: newRev}, nil

	default: // delete
		switch state {
		case StateMissing, StateDeleted:
			// Already gone: acknowledge idempotently without new changes.
			return OpResult{Status: "accepted", Revision: rev}, nil
		}
		err := withTx(ctx, s.pool, func(ctx context.Context, tx pgx.Tx) error {
			return adapter.Delete(ctx, tx, userID, op.EntityID, rev)
		})
		if err != nil {
			return OpResult{}, err
		}
		return OpResult{Status: "accepted"}, nil
	}
}

// threeWay computes the patch that is safe to apply (fields the client
// changed that the server did not touch since base) and the conflicting
// field list. Only "leaf" JSON values are compared; nested objects use
// canonical JSON equality, so a change to any nested field marks the whole
// field conflicting.
func threeWay(base, local, server map[string]any) (patch map[string]any, conflicts []string) {
	patch = map[string]any{}
	for field, localValue := range local {
		baseValue, hasBase := base[field]
		serverValue, hasServer := server[field]
		if !hasBase {
			baseValue = nil
		}
		if !hasServer {
			serverValue = nil
		}
		baseJSON, _ := json.Marshal(baseValue)
		serverJSON, _ := json.Marshal(serverValue)
		localJSON, _ := json.Marshal(localValue)
		if string(baseJSON) == string(serverJSON) {
			// Server did not touch this field: apply the client value.
			if string(localJSON) != string(baseJSON) {
				patch[field] = localValue
			}
			continue
		}
		if string(localJSON) == string(baseJSON) {
			// Client did not really change it: server value wins silently.
			continue
		}
		conflicts = append(conflicts, field)
	}
	return patch, conflicts
}

func diffFields(a, b map[string]any) []string {
	var out []string
	for k, v := range a {
		bv, ok := b[k]
		vj, _ := json.Marshal(v)
		bjj, _ := json.Marshal(bv)
		if !ok || string(vj) != string(bjj) {
			out = append(out, k)
		}
	}
	return out
}

func sameEntity(a, b map[string]any) bool {
	for k, v := range a {
		if k == "revision" || k == "createdAt" || k == "updatedAt" || k == "deletedAt" {
			continue
		}
		bv, ok := b[k]
		if !ok {
			return false
		}
		vj, _ := json.Marshal(v)
		bjj, _ := json.Marshal(bv)
		if string(vj) != string(bjj) {
			return false
		}
	}
	return true
}

func (s *PushService) claim(ctx context.Context, userID, operationID string) (bool, error) {
	tag, err := s.pool.Exec(ctx, `
		INSERT INTO sync_operations (user_id, operation_id, status, result)
		VALUES ($1, $2, 'processing', '{}'::jsonb)
		ON CONFLICT (user_id, operation_id) DO NOTHING`,
		userID, operationID)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() > 0, nil
}

func (s *PushService) storeResult(ctx context.Context, userID, operationID string, res OpResult) error {
	raw, err := json.Marshal(res)
	if err != nil {
		return err
	}
	_, err = s.pool.Exec(ctx, `
		UPDATE sync_operations SET status = $3, result = $4 WHERE user_id = $1 AND operation_id = $2`,
		userID, operationID, res.Status, raw)
	return err
}

func (s *PushService) loadStoredResult(ctx context.Context, userID, operationID string) (OpResult, error) {
	var status string
	var result []byte
	if err := s.pool.QueryRow(ctx, `SELECT status, result FROM sync_operations
		WHERE user_id = $1 AND operation_id = $2`, userID, operationID).Scan(&status, &result); err != nil {
		return OpResult{}, err
	}
	var res OpResult
	if err := json.Unmarshal(result, &res); err != nil {
		res = OpResult{Status: status}
	}
	if res.Status == "processing" {
		// A concurrent request is mid-flight; treat as accepted to avoid
		// duplicate execution (worst case the client sees a stale result).
		res = OpResult{Status: "accepted"}
	}
	return res, nil
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
