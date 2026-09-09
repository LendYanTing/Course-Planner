import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('GridViewContent renders rows, tiles, divider and markers',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++) tz.TZDateTime(ut.location, 2026, 9, 7 + i),
    ];

    final snapshot = EntitiesSnapshot(
      rows: [
        EntityRow(
          entityType: EntityTypes.calendar,
          entityId: 'cal1',
          revision: 1,
          payload: {
            'id': 'cal1',
            'name': '2026秋',
            'firstDay': '2026-09-07',
            'totalWeeks': 16,
            'revision': 1,
          },
        ),
        for (final p in [
          (1, '08:00', '08:45'),
          (2, '08:55', '09:40'),
          (3, '10:00', '10:45'),
          (4, '14:00', '14:45'),
        ])
          EntityRow(
            entityType: EntityTypes.period,
            entityId: 'p${p.$1}',
            revision: 1,
            payload: {
              'id': 'p${p.$1}',
              'calendarId': 'cal1',
              'periodNo': p.$1,
              'startLocal': p.$2,
              'endLocal': p.$3,
              'revision': 1,
            },
          ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    final events = <UiEvent>[
      UiEvent(
        id: 'course:m1:2026-09-07',
        type: EventType.course,
        title: '高等数学',
        startUtc: DateTime.utc(2026, 9, 7, 0, 0), // 08:00 local
        endUtc: DateTime.utc(2026, 9, 7, 1, 40), // 09:40 local (merged 1-2)
        sourceType: EntityTypes.courseMeeting,
        sourceId: 'm1',
        conflict: ConflictState.none,
        color: '#4A6FA5',
      ),
      UiEvent(
        id: 'todo_block:b1',
        type: EventType.todoBlock,
        title: '生化大作业',
        startUtc: DateTime.utc(2026, 9, 8, 2, 0), // Tue 10:00 local
        endUtc: DateTime.utc(2026, 9, 8, 3, 0),
        sourceType: EntityTypes.todoBlock,
        sourceId: 'b1',
        conflict: ConflictState.soft,
        color: '#7E57C2',
      ),
      UiEvent(
        id: 'deadline:t1',
        type: EventType.deadline,
        title: '线代作业',
        startUtc: DateTime.utc(2026, 9, 10, 10, 0), // Thu 18:00 local (after row 4 end)
        endUtc: DateTime.utc(2026, 9, 10, 10, 0),
        sourceType: EntityTypes.todo,
        sourceId: 't1',
        conflict: ConflictState.none,
        color: '#E53935',
      ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 900,
            height: 700,
            child: GridViewContent(
              userTime: ut,
              days: days,
              events: events,
              snapshot: snapshot,
              nowUtc: DateTime.utc(2026, 9, 8, 0, 30), // Tue 08:30 local
              onCommitMove: (e, s, en) {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsWidgets); // course tile (row run)
    expect(find.text('生化大作业'), findsWidgets); // todo block tile
    expect(find.text('线代作业 · 18:00'), findsWidgets); // pinned deadline marker
    expect(find.textContaining('现在'), findsOneWidget); // now line label
    expect(find.text('上午 AM · 下午 PM'), findsOneWidget); // divider capsule
    // All four period rows labelled in the left gutter.
    expect(find.text('4'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
