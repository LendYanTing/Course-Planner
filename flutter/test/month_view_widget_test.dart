import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/month_page.dart';
import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Month view adjustments: time blocks show their note, classes show the room
/// and teacher (blank when absent), and deadlines show the actual due time
/// instead of a bare "截止".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('eventMeta', () {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;

    UiEvent ev(EventType type, {String? location, String? teacher, String? note}) => UiEvent(
          id: 'x',
          type: type,
          title: 't',
          startUtc: ut.fromLocalParts(2026, 9, 10, 9, 0).toUtc(),
          endUtc: ut.fromLocalParts(2026, 9, 10, 9, 45).toUtc(),
          sourceType: EntityTypes.courseMeeting,
          sourceId: 's',
          conflict: ConflictState.none,
          location: location,
          teacher: teacher,
          note: note,
        );

    test('class shows room and teacher', () {
      expect(eventMeta(ev(EventType.course, location: '12-209', teacher: '张三')),
          '12-209 · 张三');
      expect(eventMeta(ev(EventType.course, location: '12-209')), '12-209');
      expect(eventMeta(ev(EventType.course, teacher: '张三')), '张三');
    });

    test('class with neither room nor teacher is blank (not a placeholder)', () {
      expect(eventMeta(ev(EventType.course)), isNull);
      expect(eventMeta(ev(EventType.course, location: '', teacher: '')), isNull);
    });

    test('todo block shows its note, blank when absent', () {
      expect(eventMeta(ev(EventType.todoBlock, note: '第一章习题')), '第一章习题');
      expect(eventMeta(ev(EventType.todoBlock)), isNull);
      expect(eventMeta(ev(EventType.todoBlock, note: '')), isNull);
    });

    test('deadlines and schedules carry no meta line', () {
      expect(eventMeta(ev(EventType.deadline, note: 'x')), isNull);
      expect(eventMeta(ev(EventType.recurringSchedule, note: 'x')), isNull);
    });
  });

  testWidgets('month cell shows room/teacher, block note and deadline time',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    // Built relative to the displayed month so the test never depends on the
    // wall clock: the Monday of the week containing the 15th, plus a deadline
    // on the 15th at 18:00 local.
    final nowLocal = ut.localFromUtc(DateTime.now().toUtc());
    final fifteenth = ut.fromLocalParts(nowLocal.year, nowLocal.month, 15, 0, 0);
    final monday = ut.addLocalDays(fifteenth, -(ut.isoWeekday(fifteenth) - 1));
    final firstDay = ut.localDateString(monday);
    final deadlineUtc = ut.fromLocalParts(nowLocal.year, nowLocal.month, 15, 18, 0).toUtc();
    final blockUtc = ut.fromLocalParts(
        monday.year, monday.month, monday.day, 14, 0).toUtc();

    final snapshot = EntitiesSnapshot(
      rows: [
        EntityRow(
          entityType: EntityTypes.calendar,
          entityId: 'cal1',
          revision: 1,
          payload: {
            'id': 'cal1',
            'name': '2026 Autumn',
            'firstDay': firstDay,
            'totalWeeks': 16,
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.period,
          entityId: 'p1',
          revision: 1,
          payload: {
            'id': 'p1',
            'calendarId': 'cal1',
            'periodNo': 1,
            'startLocal': '08:00',
            'endLocal': '08:45',
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.course,
          entityId: 'c1',
          revision: 1,
          payload: {
            'id': 'c1',
            'calendarId': 'cal1',
            'name': '高等数学',
            'location': '12-209',
            'teacher': '张三',
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.courseMeeting,
          entityId: 'm1',
          revision: 1,
          payload: {
            'id': 'm1',
            'courseId': 'c1',
            'weekday': 1,
            'periodStart': 1,
            'periodEnd': 1,
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.todo,
          entityId: 't1',
          revision: 1,
          payload: {
            'id': 't1',
            'title': '线代作业',
            'status': 'todo',
            'deadlineAt': deadlineUtc.toIso8601String(),
            'revision': 1,
          },
        ),
        // A block on the deadline day: the cell then holds a course/block chip
        // AND a reminder, which is exactly the ordering being asserted.
        EntityRow(
          entityType: EntityTypes.todoBlock,
          entityId: 'b2',
          revision: 1,
          payload: {
            'id': 'b2',
            'todoId': 't1',
            'startAt': ut
                .fromLocalParts(nowLocal.year, nowLocal.month, 15, 9, 0)
                .toUtc()
                .toIso8601String(),
            'endAt': ut
                .fromLocalParts(nowLocal.year, nowLocal.month, 15, 10, 0)
                .toUtc()
                .toIso8601String(),
            'status': 'scheduled',
            'blockNote': '当天时间块',
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.todoBlock,
          entityId: 'b1',
          revision: 1,
          payload: {
            'id': 'b1',
            'todoId': 't1',
            'startAt': blockUtc.toIso8601String(),
            'endAt': blockUtc.add(const Duration(hours: 1)).toIso8601String(),
            'status': 'scheduled',
            'blockNote': '第一章习题',
            'revision': 1,
          },
        ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          sessionControllerProvider.overrideWith(_FakeSession.new),
        ],
        child: const MaterialApp(home: MonthPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('高等数学'), findsWidgets);
    expect(find.textContaining('12-209'), findsWidgets, reason: 'class room shown');
    expect(find.textContaining('张三'), findsWidgets, reason: 'class teacher shown');
    expect(find.text('第一章习题'), findsWidgets, reason: 'block note shown');
    expect(find.textContaining('18:00'), findsWidgets, reason: 'deadline time shown');

    // The reminder is pinned above the day's blocks so a full day cannot bury it.
    final reminderTop = tester.getTopLeft(find.textContaining('18:00').first).dy;
    final blockTop = tester.getTopLeft(find.text('当天时间块').first).dy;
    expect(reminderTop, lessThan(blockTop),
        reason: 'the deadline line must sit above the block chip in the cell');
  });
}

/// Signed-in session with a fixed timezone (no providers touched).
class _FakeSession extends SessionController {
  @override
  SessionState build() => const SessionState(
        phase: AuthPhase.signedIn,
        profile: SessionProfile(
          userId: 'u1',
          username: 'webdev',
          timezone: 'Asia/Shanghai',
        ),
      );
}
