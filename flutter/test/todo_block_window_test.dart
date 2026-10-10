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

/// A projection window is a half-open range of *instants*: an event belongs to
/// it when `[startAt, endAt)` overlaps `[startUtc, endUtc)`. Courses, recurring
/// schedules and deadlines already honour that; todo blocks were appended
/// unconditionally, so a block from any other week surfaced in whatever range
/// the caller rendered — and the week timeline drew it in the weekday column of
/// the week on screen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  // Mon 2026-09-07 .. Mon 2026-09-14 (UTC instants; the contract is instants,
  // not local days).
  final windowStart = DateTime.utc(2026, 9, 7);
  final windowEnd = DateTime.utc(2026, 9, 14);

  EntitiesSnapshot snapshotWithBlocks(
    Map<String, (DateTime start, DateTime end)> blocks,
  ) =>
      EntitiesSnapshot(
        rows: [
          EntityRow(
            entityType: EntityTypes.todo,
            entityId: 't1',
            revision: 1,
            payload: {
              'id': 't1',
              'title': '生化大作业',
              'status': 'todo',
              'revision': 1,
            },
          ),
          for (final entry in blocks.entries)
            EntityRow(
              entityType: EntityTypes.todoBlock,
              entityId: entry.key,
              revision: 1,
              payload: {
                'id': entry.key,
                'todoId': 't1',
                'startAt': entry.value.$1.toIso8601String(),
                'endAt': entry.value.$2.toIso8601String(),
                'status': 'scheduled',
                'revision': 1,
              },
            ),
        ],
        pendingOps: const [],
        conflicts: const [],
      );

  List<String> projectedBlockIds(EntitiesSnapshot snapshot) =>
      EventProjection(EventExpander(ut))
          .project(snapshot, startUtc: windowStart, endUtc: windowEnd)
          .events
          .where((e) => e.sourceType == EntityTypes.todoBlock)
          .map((e) => e.id)
          .toList()
        ..sort();

  test('only todo blocks overlapping the window are projected', () {
    final snapshot = snapshotWithBlocks({
      'far-before': (
        DateTime.utc(2026, 9, 1, 2),
        DateTime.utc(2026, 9, 1, 3),
      ),
      'inside': (
        DateTime.utc(2026, 9, 9, 2),
        DateTime.utc(2026, 9, 9, 3),
      ),
      'far-after': (
        DateTime.utc(2026, 9, 20, 2),
        DateTime.utc(2026, 9, 20, 3),
      ),
      // Straddles the window's start / end edge: still an overlap.
      'overlaps-start': (
        DateTime.utc(2026, 9, 6, 23),
        DateTime.utc(2026, 9, 7, 1),
      ),
      'overlaps-end': (
        DateTime.utc(2026, 9, 13, 23),
        DateTime.utc(2026, 9, 14, 1),
      ),
      // The window is half-open: starting exactly at endUtc is outside.
      'starts-at-end': (
        DateTime.utc(2026, 9, 14),
        DateTime.utc(2026, 9, 14, 1),
      ),
    });

    expect(
      projectedBlockIds(snapshot),
      [
        'todo_block:inside',
        'todo_block:overlaps-end',
        'todo_block:overlaps-start',
      ],
    );
  });

  group('the filter follows the optimistic local state', () {
    configureHostSqlite();

    late AppDatabase db;
    late SyncStore store;
    late EntityRepo repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = SyncStore(db);
      repo = EntityRepo(db, store);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> seedTodo() => store.upsertEntityRow(EntityRow(
          entityType: EntityTypes.todo,
          entityId: 't1',
          revision: 1,
          payload: {
            'id': 't1',
            'title': '生化大作业',
            'status': 'todo',
            'revision': 1,
          },
        ));

    Future<void> seedBlock(DateTime start, DateTime end) =>
        store.upsertEntityRow(EntityRow(
          entityType: EntityTypes.todoBlock,
          entityId: 'b1',
          revision: 1,
          payload: {
            'id': 'b1',
            'todoId': 't1',
            'startAt': start.toIso8601String(),
            'endAt': end.toIso8601String(),
            'status': 'scheduled',
            'revision': 1,
          },
        ));

    Future<EntitiesSnapshot> snapshot() async => EntitiesSnapshot(
          rows: await store.watchAll().first,
          pendingOps: await store.pendingOps(),
          conflicts: await store.conflicts(),
        );

    test('a queued move into the window surfaces at its moved instant', () async {
      await seedTodo();
      // Canonical position is a week earlier, i.e. outside the rendered window.
      await seedBlock(
        DateTime.utc(2026, 9, 2, 2),
        DateTime.utc(2026, 9, 2, 3),
      );
      expect(projectedBlockIds(await snapshot()), isEmpty,
          reason: 'the canonical block is out of window');

      await repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: 'b1',
        changes: {
          'startAt': DateTime.utc(2026, 9, 9, 2),
          'endAt': DateTime.utc(2026, 9, 9, 3),
        },
      );

      final events = EventProjection(EventExpander(ut))
          .project(await snapshot(), startUtc: windowStart, endUtc: windowEnd)
          .events
          .where((e) => e.sourceType == EntityTypes.todoBlock)
          .toList();
      expect(events, hasLength(1),
          reason: 'the window test must run on the overlaid position');
      expect(events.single.startUtc, DateTime.utc(2026, 9, 9, 2));
    });

    test('a queued move out of the window removes it', () async {
      await seedTodo();
      await seedBlock(
        DateTime.utc(2026, 9, 9, 2),
        DateTime.utc(2026, 9, 9, 3),
      );
      expect(projectedBlockIds(await snapshot()), ['todo_block:b1']);

      await repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: 'b1',
        changes: {
          'startAt': DateTime.utc(2026, 9, 2, 2),
          'endAt': DateTime.utc(2026, 9, 2, 3),
        },
      );

      expect(projectedBlockIds(await snapshot()), isEmpty);
    });
  });
}
