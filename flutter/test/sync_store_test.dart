import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  late AppDatabase db;
  late SyncStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('entity mirror upsert/list/clear', () async {
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todo,
      entityId: 't1',
      revision: 2,
      payload: {'id': 't1', 'title': 'hello', 'status': 'todo'},
    ));
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todo,
      entityId: 't2',
      revision: 1,
      payload: {'id': 't2', 'title': 'world'},
    ));
    final rows = await store.entitiesOfType(EntityTypes.todo);
    expect(rows, hasLength(2));
    expect(rows.firstWhere((r) => r.entityId == 't1').revision, 2);

    // overwrite by key
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todo,
      entityId: 't1',
      revision: 3,
      payload: {'id': 't1', 'title': 'updated'},
    ));
    expect((await store.entitiesOfType(EntityTypes.todo)).length, 2);
    expect((await store.entityRow(EntityTypes.todo, 't1'))!.revision, 3);

    await store.clearEntities();
    expect(await store.entitiesOfType(EntityTypes.todo), isEmpty);
  });

  test('pending ops round trip FIFO order', () async {
    final now = DateTime.now().toUtc();
    await store.enqueueOp(PendingOperation(
      operationId: 'a',
      entityType: EntityTypes.todo,
      entityId: 't1',
      operation: SyncOperations.create,
      baseRevision: 0,
      changes: {'title': 'A'},
      createdAt: now,
    ));
    await store.enqueueOp(PendingOperation(
      operationId: 'b',
      entityType: EntityTypes.todo,
      entityId: 't1',
      operation: SyncOperations.update,
      baseRevision: 0,
      changes: {'title': 'B'},
      createdAt: now.add(const Duration(seconds: 1)),
    ));
    final ops = await store.pendingOps();
    expect(ops.map((o) => o.operationId), ['a', 'b']);
    expect(ops.last.changes['title'], 'B');

    await store.removeOp('a');
    expect((await store.pendingOps()).single.operationId, 'b');
  });

  test('conflicts stored and cleared', () async {
    await store.saveConflict(ConflictRecord(
      operationId: 'op1',
      entityType: EntityTypes.todo,
      entityId: 't1',
      base: {'title': 'base'},
      local: {'title': 'local'},
      server: {'title': 'server'},
      conflictingFields: const ['title'],
      createdAt: DateTime.now().toUtc(),
    ));
    final conflicts = await store.conflicts();
    expect(conflicts, hasLength(1));
    expect(conflicts.single.conflictingFields, ['title']);
    await store.removeConflict('op1');
    expect(await store.conflicts(), isEmpty);
  });

  test('meta persists cursor and profile and resets fully', () async {
    await store.saveMeta(const AppMetaSnapshot(userId: 'u1', timezone: 'Asia/Shanghai'));
    await store.saveMeta(const AppMetaSnapshot(
      userId: 'u1',
      username: 'alice',
      timezone: 'Asia/Shanghai',
      lastServerCursor: 42,
    ));
    final meta = await store.meta();
    expect(meta!.userId, 'u1');
    expect(meta.username, 'alice');
    expect(meta.lastServerCursor, 42);

    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.course,
      entityId: 'c1',
      revision: 1,
      payload: {'id': 'c1'},
    ));
    await store.resetForNewUser();
    expect(await store.meta(), isNull);
    expect(await store.entitiesOfType(EntityTypes.course), isEmpty);
    expect(await store.pendingOps(), isEmpty);
  });
}
