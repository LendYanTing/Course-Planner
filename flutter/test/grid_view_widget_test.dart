import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';
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
        // The todo that owns the deadline event, with one done + one pending
        // block, so the deadline sheet has something real to summarise.
        EntityRow(
          entityType: EntityTypes.todo,
          entityId: 't1',
          revision: 1,
          payload: {'id': 't1', 'title': '线代作业', 'status': 'todo', 'revision': 1},
        ),
        EntityRow(
          entityType: EntityTypes.todoBlock,
          entityId: 'blk1',
          revision: 1,
          payload: {
            'id': 'blk1',
            'todoId': 't1',
            'startAt': '2026-09-08T01:00:00Z',
            'endAt': '2026-09-08T02:00:00Z',
            'status': 'completed',
            'blockNote': '第一章',
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.todoBlock,
          entityId: 'blk2',
          revision: 1,
          payload: {
            'id': 'blk2',
            'todoId': 't1',
            'startAt': '2026-09-09T01:00:00Z',
            'endAt': '2026-09-09T02:00:00Z',
            'status': 'scheduled',
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
      ProviderScope(
        overrides: [prefStoreProvider.overrideWithValue(MemoryPrefs())],
        child: MaterialApp(
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsWidgets); // course tile (row run)
    expect(find.text('生化大作业'), findsWidgets); // todo block tile
    expect(find.text('线代作业 · 18:00'), findsWidgets); // pinned deadline marker
    expect(find.textContaining('现在'), findsOneWidget); // now line label
    // The 上午/下午 capsule label was removed; the tinted halves and the rule
    // between them carry the distinction now.
    expect(find.text('上午 AM · 下午 PM'), findsNothing);
    // All four period rows labelled in the left gutter.
    expect(find.text('4'), findsWidgets);
    expect(tester.takeException(), isNull);

    // Tapping a course tile shows full detail including start AND end time.
    await tester.tap(find.text('高等数学').first);
    await tester.pumpAndSettle();
    expect(find.text('开始'), findsOneWidget);
    expect(find.text('结束'), findsOneWidget);
    expect(find.text('9月7日 08:00'), findsOneWidget);
    expect(find.text('9月7日 09:40'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    // Tapping the deadline capsule shows the due instant, the block count and
    // which blocks are done.
    await tester.tap(find.text('线代作业 · 18:00').first);
    await tester.pumpAndSettle();
    expect(find.text('截止 2026-09-10 18:00'), findsOneWidget);
    expect(find.text('时间块 1/2 已完成'), findsOneWidget);
    expect(find.textContaining('第一章'), findsWidgets); // block note listed
    expect(tester.takeException(), isNull);
  });

  testWidgets('上午/下午 split follows the local noon-boundary preference',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++) tz.TZDateTime(ut.location, 2026, 9, 7 + i),
    ];
    // Periods at 08:00, 13:00 and 15:00: with a 12:00 boundary the 13:00 row is
    // already afternoon, with a 14:00 boundary (western-China habit) it is not.
    final snapshot = EntitiesSnapshot(
      rows: [
        EntityRow(
          entityType: EntityTypes.calendar,
          entityId: 'cal1',
          revision: 1,
          payload: {
            'id': 'cal1', 'name': '2026秋', 'firstDay': '2026-09-07',
            'totalWeeks': 16, 'revision': 1,
          },
        ),
        for (final p in [(1, '08:00', '08:45'), (2, '13:00', '13:45'), (3, '15:00', '15:45')])
          EntityRow(
            entityType: EntityTypes.period,
            entityId: 'p${p.$1}',
            revision: 1,
            payload: {
              'id': 'p${p.$1}', 'calendarId': 'cal1', 'periodNo': p.$1,
              'startLocal': p.$2, 'endLocal': p.$3, 'revision': 1,
            },
          ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    const amTint = Color(0xFFEDF4FF);
    const pmTint = Color(0xFFFFF2E4);

    Future<({int am, int pm})> tintsFor(int boundary) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: SizedBox(
                width: 900,
                height: 700,
                child: GridViewContent(
                  userTime: ut,
                  days: days,
                  events: const [],
                  snapshot: snapshot,
                  nowUtc: null,
                  noonBoundaryMinutes: boundary,
                  onCommitMove: (e, s, en) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      int count(Color c) => tester
          .widgetList(find.byWidgetPredicate((w) => w is ColoredBox && w.color == c))
          .length;
      return (am: count(amTint), pm: count(pmTint));
    }

    final def = await tintsFor(12 * 60);
    expect(def.am, 1, reason: 'only 08:00 counts as morning at a 12:00 boundary');
    expect(def.pm, 2, reason: '13:00 and 15:00 are afternoon at 12:00');

    final late = await tintsFor(14 * 60);
    expect(late.am, 2, reason: '13:00 is still morning at a 14:00 boundary');
    expect(late.pm, 1, reason: 'only 15:00 is afternoon at 14:00');
  });

  testWidgets('tile title/location line counts follow the preference',
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
            'id': 'cal1', 'name': '2026秋', 'firstDay': '2026-09-07',
            'totalWeeks': 16, 'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.period,
          entityId: 'p1',
          revision: 1,
          payload: {
            'id': 'p1', 'calendarId': 'cal1', 'periodNo': 1,
            'startLocal': '08:00', 'endLocal': '08:45', 'revision': 1,
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
        title: '中国近现代史纲要',
        startUtc: DateTime.utc(2026, 9, 7, 0, 0),
        endUtc: DateTime.utc(2026, 9, 7, 0, 45),
        sourceType: EntityTypes.courseMeeting,
        sourceId: 'm1',
        conflict: ConflictState.none,
        location: '逸夫楼201-阶梯教室',
      ),
    ];

    // A container we can drive directly: re-pumping a ProviderScope would reuse
    // the same notifier, so a second set of overrides would never be read.
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(MemoryPrefs())],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: GridViewContent(
                userTime: ut,
                days: days,
                events: events,
                snapshot: snapshot,
                nowUtc: null,
                onCommitMove: (e, s, en) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    int titleLines() =>
        tester.widget<Text>(find.text('中国近现代史纲要').first).maxLines!;
    int locationLines() =>
        tester.widget<Text>(find.text('逸夫楼201-阶梯教室').first).maxLines!;

    // Defaults.
    expect(titleLines(), 2);
    expect(locationLines(), 1);

    // A long room name can be given two lines, the name one.
    await container.read(tileTextLinesProvider.notifier).setTitle(1);
    await container.read(tileTextLinesProvider.notifier).setLocation(2);
    await tester.pumpAndSettle();
    expect(titleLines(), 1);
    expect(locationLines(), 2);
  });
}
