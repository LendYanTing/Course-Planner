import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('effectiveFor', () {
    final today = DateTime.now().toUtc();

    EntitiesSnapshot snap({
      List<EntityRow> rows = const [],
      List<PendingOperation> ops = const [],
      List<ConflictRecord> conflicts = const [],
    }) =>
        EntitiesSnapshot(rows: rows, pendingOps: ops, conflicts: conflicts);

    test('includes local-only creates (offline todo)', () {
      final s = snap(
        ops: [
          PendingOperation(
            operationId: 'op1',
            entityType: EntityTypes.todo,
            entityId: 't1',
            operation: SyncOperations.create,
            baseRevision: 0,
            changes: {'id': 't1', 'title': '离线待办', 'status': 'todo'},
            createdAt: today,
          ),
        ],
      );
      final items = effectiveFor(s, EntityTypes.todo);
      expect(items, hasLength(1));
      expect(items.first.isLocalCreate, isTrue);
      expect(items.first.payload['title'], '离线待办');
    });

    test('overlays queued updates over the canonical row', () {
      final s = snap(
        rows: [
          EntityRow(
            entityType: EntityTypes.todo,
            entityId: 't1',
            revision: 3,
            payload: {'id': 't1', 'title': '云端标题', 'status': 'todo'},
            updatedAt: today,
          ),
        ],
        ops: [
          PendingOperation(
            operationId: 'op1',
            entityType: EntityTypes.todo,
            entityId: 't1',
            operation: SyncOperations.update,
            baseRevision: 3,
            changes: {'title': '本地新标题'},
            createdAt: today,
          ),
        ],
      );
      final items = effectiveFor(s, EntityTypes.todo);
      expect(items.single.payload['title'], '本地新标题');
      expect(items.single.revision, 3);
      expect(items.single.hasPendingOp, isTrue);
    });

    test('queued delete hides the row but keeps the canonical base', () {
      final s = snap(
        rows: [
          EntityRow(
            entityType: EntityTypes.todo,
            entityId: 't1',
            revision: 3,
            payload: {'id': 't1', 'title': '要删除'},
            updatedAt: today,
          ),
        ],
        ops: [
          PendingOperation(
            operationId: 'op1',
            entityType: EntityTypes.todo,
            entityId: 't1',
            operation: SyncOperations.delete,
            baseRevision: 3,
            changes: const {},
            createdAt: today,
          ),
        ],
      );
      expect(effectiveFor(s, EntityTypes.todo), isEmpty);
    });

    test('server tombstone (deletedAt) hides the row', () {
      final s = snap(
        rows: [
          EntityRow(
            entityType: EntityTypes.todo,
            entityId: 't1',
            revision: 4,
            payload: {'id': 't1', 'title': 'x'},
            updatedAt: today,
            deletedAt: today,
          ),
        ],
      );
      expect(effectiveFor(s, EntityTypes.todo), isEmpty);
    });

    test('local create followed by delete is hidden', () {
      final s = snap(
        ops: [
          PendingOperation(
            operationId: 'op1',
            entityType: EntityTypes.todo,
            entityId: 't1',
            operation: SyncOperations.create,
            baseRevision: 0,
            changes: {'id': 't1', 'title': 'x'},
            createdAt: today,
          ),
          PendingOperation(
            operationId: 'op2',
            entityType: EntityTypes.todo,
            entityId: 't1',
            operation: SyncOperations.delete,
            baseRevision: 0,
            changes: const {},
            createdAt: today,
          ),
        ],
      );
      expect(effectiveFor(s, EntityTypes.todo), isEmpty);
    });
  });
}
