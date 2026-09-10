import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Grid (课表) tile gestures.
///
/// The fixture uses a realistically tall timetable (10 periods) and a short
/// viewport so the view genuinely has somewhere to scroll.
///
/// A phone has no scroll wheel, so a plain swipe anywhere — including over a
/// tile — must scroll the timetable. Moving/resizing therefore starts with a
/// **long press**, which the enclosing scrollable never claims. These tests pin
/// both halves of that contract.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
        (4, '11:00', '11:45'),
        (5, '14:00', '14:45'),
        (6, '14:55', '15:40'),
        (7, '15:50', '16:35'),
        (8, '16:45', '17:30'),
        (9, '19:00', '19:45'),
        (10, '19:55', '20:40'),
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

  // Mon 2026-09-07 08:00–08:40 local (period 1) — a todo block.
  final events = <UiEvent>[
    UiEvent(
      id: 'todo_block:b1',
      type: EventType.todoBlock,
      title: '生化大作业',
      startUtc: DateTime.utc(2026, 9, 7, 0, 0), // 08:00 local (UTC+8)
      endUtc: DateTime.utc(2026, 9, 7, 0, 40), // 08:40 local
      sourceType: EntityTypes.todoBlock,
      sourceId: 'b1',
      conflict: ConflictState.none,
      color: '#7E57C2',
    ),
  ];

  Future<void> pumpGrid(WidgetTester tester, void Function() onCommit) async {
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
                events: events,
                snapshot: snapshot,
                nowUtc: DateTime.utc(2026, 9, 7, 0, 30), // Mon 08:30 local
                onCommitMove: (e, s, en) => onCommit(),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Starts a gesture and holds long enough for the long press to be
  /// recognised, so the following moves drive the tile rather than the scroll.
  Future<TestGesture> longPress(WidgetTester tester, Offset at) async {
    final g = await tester.startGesture(at, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 700)); // > kLongPressTimeout
    return g;
  }

  testWidgets('a plain swipe scrolls instead of moving the block',
      (tester) async {
    var moved = false;
    await pumpGrid(tester, () => moved = true);

    double offset() => tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position
        .pixels;

    final before = offset();
    // Touch: mouse is deliberately not a scroll-drag device on desktop
    // (ScrollBehavior.dragDevices), so only touch exercises the phone path.
    final g = await tester.startGesture(
        tester.getCenter(find.text('生化大作业')), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, -30));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(moved, isFalse,
        reason: 'a quick swipe must scroll the timetable, not move the block');
    expect(offset(), greaterThan(before),
        reason: 'the swipe should have scrolled the view');
  });

  testWidgets('long press then drag moves the block', (tester) async {
    var moved = false;
    await pumpGrid(tester, () => moved = true);

    final g = await longPress(tester, tester.getCenter(find.text('生化大作业')));
    for (var i = 0; i < 4; i++) {
      await g.moveBy(const Offset(0, 30));
      await tester.pump();
    }
    await g.up();
    await tester.pumpAndSettle();

    expect(moved, isTrue, reason: 'dropping after a long-press drag commits');
  });

  testWidgets('long press on the top handle then drag resizes', (tester) async {
    var moved = false;
    await pumpGrid(tester, () => moved = true);

    // Grab inside the top resize band (first ~5px of the 48px tile).
    final tileTop = tester.getTopLeft(find.text('生化大作业'));
    final g = await longPress(tester, tileTop + const Offset(30, 3));
    await g.moveBy(const Offset(0, 60));
    await tester.pump();
    await g.up();
    await tester.pumpAndSettle();

    expect(moved, isTrue, reason: 'resizing from the top handle should commit');
  });

  testWidgets('a ghost preview appears at the target during a long-press drag',
      (tester) async {
    await pumpGrid(tester, () {});

    expect(find.byKey(const ValueKey('grid-drag-ghost')), findsNothing);

    final g = await longPress(tester, tester.getCenter(find.text('生化大作业')));
    await g.moveBy(const Offset(60, 30));
    await tester.pump();

    // Ghost shown while dragging; the source block stays and just dims.
    expect(find.byKey(const ValueKey('grid-drag-ghost')), findsOneWidget);
    expect(find.text('生化大作业'), findsOneWidget);

    await g.up();
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('grid-drag-ghost')), findsNothing);
  });
}
