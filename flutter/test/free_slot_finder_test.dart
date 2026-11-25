import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/free_slot_finder.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

/// Phase 5 Step 1: free slots are the gaps of the local projection inside the
/// daily planning window, clipped to the caller's UTC range.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;
  final finder = FreeSlotFinder(ut);

  late AppDatabase db;
  late SyncStore store;
  late EntityRepo repo;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
    repo = EntityRepo(db, store);

    // 2026-09-07 is a Monday; the semester runs 16 weeks.
    final calendarId = await repo.localCreate(
      entityType: EntityTypes.calendar,
      snapshot: {
        'name': '2026 Autumn',
        'firstDay': '2026-09-07',
        'totalWeeks': 16,
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 1,
        'startLocal': '08:00',
        'endLocal': '08:45',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 2,
        'startLocal': '08:55',
        'endLocal': '09:40',
      },
    );
    final courseId = await repo.localCreate(
      entityType: EntityTypes.course,
      snapshot: {'calendarId': calendarId, 'name': '高等数学'},
    );
    await repo.localCreate(
      entityType: EntityTypes.courseMeeting,
      snapshot: {
        'courseId': courseId,
        'weekday': 1,
        'periodStart': 1,
        'periodEnd': 2,
        'weekRule': const WeekRule([WeekSegment(start: 1, end: 16)]).toJson(),
      },
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<EntitiesSnapshot> snapshot() async => EntitiesSnapshot(
    rows: await store.allEntities(),
    pendingOps: await store.pendingOps(),
    conflicts: await store.conflicts(),
  );

  DateTime local(
    int year,
    int month,
    int day, [
    int hour = 0,
    int minute = 0,
  ]) => ut.utcFromLocalParts(year, month, day, hour, minute);

  Future<void> addBlock(
    String title,
    DateTime startUtc,
    DateTime endUtc,
  ) async {
    final todoId = await repo.localCreate(
      entityType: EntityTypes.todo,
      snapshot: {
        'title': title,
        'type': 'one_off',
        'priority': 'normal',
        'status': 'todo',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.todoBlock,
      snapshot: {
        'todoId': todoId,
        'startAt': startUtc,
        'endAt': endUtc,
        'status': 'scheduled',
      },
    );
  }

  test('subtracts a course and a todo block into two gaps', () async {
    await addBlock('生化大作业', local(2026, 9, 7, 14), local(2026, 9, 7, 15, 30));

    final slots = finder.find(
      snapshot: await snapshot(),
      fromUtc: local(2026, 9, 7),
      toUtc: local(2026, 9, 8),
    );

    expect(slots, hasLength(2));
    expect(slots[0].dateLocal, '2026-09-07');
    expect(slots[0].displayStartLocal, '09:40');
    expect(slots[0].displayEndLocal, '14:00');
    expect(slots[0].startUtc, local(2026, 9, 7, 9, 40));
    expect(slots[0].endUtc, local(2026, 9, 7, 14));
    expect(slots[0].durationMinutes, 260);

    expect(slots[1].dateLocal, '2026-09-07');
    expect(slots[1].displayStartLocal, '15:30');
    expect(slots[1].displayEndLocal, '22:30');
    expect(slots[1].durationMinutes, 420);
  });

  test('dayEndMinute narrows the last gap', () async {
    await addBlock('生化大作业', local(2026, 9, 7, 14), local(2026, 9, 7, 15, 30));

    final slots = finder.find(
      snapshot: await snapshot(),
      fromUtc: local(2026, 9, 7),
      toUtc: local(2026, 9, 8),
      dayEndMinute: 22 * 60,
    );

    expect(slots, hasLength(2));
    expect(slots[1].displayStartLocal, '15:30');
    expect(slots[1].displayEndLocal, '22:00');
    expect(slots[1].durationMinutes, 390);
  });

  test('minDurationMinutes filters short gaps', () async {
    await addBlock('生化大作业', local(2026, 9, 7, 14), local(2026, 9, 7, 15, 30));

    final slots = finder.find(
      snapshot: await snapshot(),
      fromUtc: local(2026, 9, 7),
      toUtc: local(2026, 9, 8),
      minDurationMinutes: 300,
    );

    expect(slots, hasLength(1));
    expect(slots.single.displayStartLocal, '15:30');
    expect(slots.single.durationMinutes, 420);
  });

  test('clips gaps to the half-open UTC range', () async {
    await addBlock('生化大作业', local(2026, 9, 7, 14), local(2026, 9, 7, 15, 30));

    final slots = finder.find(
      snapshot: await snapshot(),
      fromUtc: local(2026, 9, 7, 12),
      toUtc: local(2026, 9, 7, 16),
    );

    expect(slots.map((s) => '${s.displayStartLocal}-${s.displayEndLocal}'), [
      '12:00-14:00',
      '15:30-16:00',
    ]);
    expect(slots.last.durationMinutes, 30);
  });

  test('a cross-midnight block only occupies the part of each day', () async {
    await addBlock('生化大作业', local(2026, 9, 7, 14), local(2026, 9, 7, 15, 30));
    await addBlock('通宵任务', local(2026, 9, 7, 21, 30), local(2026, 9, 8, 1));

    final slots = finder.find(
      snapshot: await snapshot(),
      fromUtc: local(2026, 9, 7),
      toUtc: local(2026, 9, 9),
    );

    expect(
      slots.map(
        (s) => '${s.dateLocal} ${s.displayStartLocal}-${s.displayEndLocal}',
      ),
      [
        '2026-09-07 09:40-14:00',
        '2026-09-07 15:30-21:30',
        '2026-09-08 08:00-22:30',
      ],
    );
  });

  test('an inverted daily window yields no slots', () {
    final slots = finder.find(
      snapshot: const EntitiesSnapshot(rows: [], pendingOps: [], conflicts: []),
      fromUtc: local(2026, 9, 7),
      toUtc: local(2026, 9, 8),
      dayStartMinute: 20 * 60,
      dayEndMinute: 8 * 60,
    );
    expect(slots, isEmpty);
  });
}
