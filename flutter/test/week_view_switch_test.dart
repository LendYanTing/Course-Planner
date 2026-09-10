import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/week_page.dart';
import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Regression: repeatedly toggling the week view between 时间轴 and 课表 must
/// keep rendering the events (previously the grid could come back empty).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('week view survives repeated timeline/grid switches',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final today = ut.localFromUtc(DateTime.now().toUtc());
    // Monday of the current week, so the meeting lands in the shown week.
    final monday = ut.addLocalDays(
        ut.fromLocalParts(today.year, today.month, today.day, 0, 0),
        -(ut.isoWeekday(today) - 1));
    final firstDay = ut.localDateString(monday);

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
          // "now" must fall inside the displayed week so the current-time line
          // actually renders (that is where the orange takeover came from).
          serverNowProvider
              .overrideWith((ref) => Stream.value(DateTime.now().toUtc())),
        ],
        child: const MaterialApp(home: WeekPage()),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('高等数学'), findsWidgets, reason: 'timeline shows the course');

    // The current-time line must stay a thin rule. When its Positioned was
    // nested inside another Positioned, the outer geometry won and the line
    // was laid out as a full-day-width, full-height ORANGE block painted over
    // the events — the "orange background, content gone" report.
    final nowLine = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == AppTheme.nowLineColor);
    expect(nowLine, findsOneWidget, reason: 'now line should render');
    final lineSize = tester.getSize(nowLine);
    expect(lineSize.height, lessThanOrEqualTo(4),
        reason: 'now line height was ${lineSize.height} (expected ~2)');

    Future<void> toggle() async {
      final toGrid = find.byTooltip('切到课表视图');
      final toTimeline = find.byTooltip('切到时间轴周视图');
      if (toGrid.evaluate().isNotEmpty) {
        await tester.tap(toGrid);
      } else {
        await tester.tap(toTimeline);
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }

    for (var i = 0; i < 3; i++) {
      await toggle(); // -> grid
      expect(tester.takeException(), isNull, reason: 'grid switch $i threw');
      expect(find.text('高等数学'), findsWidgets,
          reason: 'grid must still render the course after switch $i');
      await toggle(); // -> timeline
      expect(tester.takeException(), isNull, reason: 'timeline switch $i threw');
      expect(find.text('高等数学'), findsWidgets,
          reason: 'timeline must still render the course after switch $i');
    }
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
