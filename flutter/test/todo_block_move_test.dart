import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/sync/expander.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  late AppDatabase db;
  late SyncStore store;
  late EntityRepo repo;
  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
    repo = EntityRepo(db, store);
  });

  tearDown(() async {
    await db.close();
  });

  Future<EntitiesSnapshot> snapshot() async => EntitiesSnapshot(
        rows: await store.watchAll().first,
        pendingOps: await store.pendingOps(),
        conflicts: await store.conflicts(),
      );

  test('pending move reflects optimistically in the projection', () async {
    // Canonical todo block at A (Mon 08:00–08:40 local = 00:00–00:40Z).
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todo,
      entityId: 't1',
      revision: 1,
      payload: {'id': 't1', 'title': '生化大作业', 'status': 'todo', 'revision': 1},
    ));
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todoBlock,
      entityId: 'b1',
      revision: 1,
      payload: {
        'id': 'b1',
        'todoId': 't1',
        'startAt': '2026-09-07T00:00:00Z',
        'endAt': '2026-09-07T00:40:00Z',
        'status': 'scheduled',
        'revision': 1,
      },
    ));

    final proj = EventProjection(EventExpander(ut));
    var events = proj
        .project(await snapshot(),
            startUtc: DateTime.utc(2026, 9, 7), endUtc: DateTime.utc(2026, 9, 14))
        .events
        .where((e) => e.sourceType == EntityTypes.todoBlock)
        .toList();
    expect(events.single.startUtc, DateTime.utc(2026, 9, 7, 0, 0));

    // Move A -> B (Mon 10:20–11:00 local = 02:20–03:00Z). Use a DateTime (not
    // a TZDateTime) to isolate the overlay path from the serialization path.
    await repo.localUpdate(
      entityType: EntityTypes.todoBlock,
      entityId: 'b1',
      changes: {
        'startAt': DateTime.utc(2026, 9, 7, 2, 20),
        'endAt': DateTime.utc(2026, 9, 7, 3, 0),
      },
    );

    final pending = await store.pendingOps();
    expect(pending, hasLength(1));

    events = proj
        .project(await snapshot(),
            startUtc: DateTime.utc(2026, 9, 7), endUtc: DateTime.utc(2026, 9, 14))
        .events
        .where((e) => e.sourceType == EntityTypes.todoBlock)
        .toList();
    expect(events.single.startUtc, DateTime.utc(2026, 9, 7, 2, 20),
        reason: 'a queued update must optimistically move the block in the projection');
  });
}
