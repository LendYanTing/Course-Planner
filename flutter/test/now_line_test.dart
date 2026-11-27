import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:course_planner/presentation/calendar/week_page.dart';
import 'package:course_planner/state/now_ticker.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:course_planner/sync/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'helpers/memory_prefs.dart';
import 'helpers/week_page_harness.dart' show FakeSession;

/// The current-time line: it follows a 1 Hz ticker (never a stale snapshot),
/// the 时间轴 opens centered on "now", and 课表 no longer draws the line at all.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Shanghai 14:00 on Wednesday 2026-09-09 — inside the Sep 7 week.
  final now = DateTime.utc(2026, 9, 9, 6, 0);
  final userTime = UserTime.tryCreate('Asia/Shanghai')!;

  const snapshot = EntitiesSnapshot(
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
    ],
    pendingOps: [],
    conflicts: [],
  );

  Finder lineFinder() => find.byWidgetPredicate(
      (w) => w is ColoredBox && w.color == AppTheme.nowLineColor);

  Future<void> pumpWeekPageAt(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          sessionControllerProvider.overrideWith(FakeSession.new),
          serverNowProvider.overrideWith((ref) => Stream.value(now)),
          serverClockProvider.overrideWithValue(_TestClock(now)),
        ],
        child: const MaterialApp(home: WeekPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
    // Let the initial jump-to-today slide finish, so only the shown week's
    // scroll view is left in the tree.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
  }

  testWidgets('timeline opens centered on now and keeps the orange line', (
    tester,
  ) async {
    await pumpWeekPageAt(tester);

    final scroll = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(WeekPage),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    final position = scroll.controller!.position;
    // 14:00 → 14/24 of the 24-hour canvas, minus half a viewport, clamped.
    const totalHeight = 24 * 48.0;
    final expected = (14 / 24 * totalHeight - position.viewportDimension / 2)
        .clamp(0.0, position.maxScrollExtent);
    expect(position.pixels, closeTo(expected, 2));

    final line = lineFinder();
    expect(line, findsOneWidget);
    final rect = tester.getRect(line);
    expect(rect.height, lessThanOrEqualTo(4));
    // Wednesday (index 2) column: gutter + two day widths.
    expect(rect.left, closeTo(46 + 2 * rect.width, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('课表 grid draws a gutter-free now line with a bright today', (
    tester,
  ) async {
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++) tz.TZDateTime(userTime.location, 2026, 9, 7 + i),
    ];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          serverNowProvider.overrideWith((ref) => Stream.value(now)),
          serverClockProvider.overrideWithValue(_TestClock(now)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: GridViewContent(
                userTime: userTime,
                days: days,
                events: const [],
                snapshot: snapshot,
                nowUtc: now,
                hasBackground: false,
                onCommitMove: (e, s, en) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // No 「现在 HH:mm」 text in the period gutter.
    expect(find.textContaining('现在'), findsNothing);
    final segments = find.byWidgetPredicate(
      (w) =>
          w is ColoredBox &&
          (w.color == AppTheme.nowLineColor ||
              w.color == AppTheme.nowLineColor.withValues(alpha: 0.5)),
    );
    expect(segments, findsNWidgets(7));
    // Today's segment (Wednesday, index 2) is fully opaque, the rest are 50%.
    final colors = tester
        .widgetList<ColoredBox>(segments)
        .map((w) => w.color)
        .toList();
    expect(colors[2].a, 1.0);
    for (var i = 0; i < 7; i++) {
      if (i == 2) continue;
      expect(colors[i].a, closeTo(0.5, 0.001));
    }
    // The rule starts after the period gutter, so it cannot cover 节次.
    final first = tester.getRect(segments.at(0));
    expect(first.left, closeTo(GridViewContent.leftWidth, 0.5));
    expect(tester.takeException(), isNull);
  });

  testWidgets('ticker emits at once, every second and on foreground return', (
    tester,
  ) async {
    final clock = _TestClock(now);
    final container = ProviderContainer(
      overrides: [serverClockProvider.overrideWithValue(clock)],
    );
    final seen = <DateTime>[];
    final sub = container.listen<AsyncValue<DateTime>>(
      nowTickerProvider,
      (previous, next) {
        final value = next.value;
        if (value != null) seen.add(value);
      },
    );

    try {
      await tester.pump();
      await tester.pump();
      expect(seen, isNotEmpty, reason: 'the first value must not wait a second');
      final initial = seen.length;

      clock.now = now.add(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      final afterOneSecond = seen.length;
      expect(afterOneSecond, greaterThan(initial), reason: 'ticks once per second');

      clock.now = now.add(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 1));
      expect(seen.length, greaterThan(afterOneSecond), reason: 'keeps ticking');

      // Background return must emit immediately, without waiting out the second.
      clock.now = now.add(const Duration(seconds: 3));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump();
      expect(seen.last, now.add(const Duration(seconds: 3)));
    } finally {
      // The ticker owns a periodic timer: cancel it before the binding checks
      // for pending timers at the end of the test.
      sub.close();
      container.dispose();
    }
  });
}

/// A server clock frozen at [now], movable by tests.
class _TestClock extends ServerClock {
  _TestClock(this.now);

  DateTime now;

  @override
  DateTime estimateNow() => now;
}
