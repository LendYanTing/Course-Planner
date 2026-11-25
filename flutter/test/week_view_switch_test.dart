import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart';

/// Regression: the 日程 page must survive walking the 课表 → 周 → 月 switcher
/// repeatedly. Switching used to be two-state and the grid could come back
/// empty; adding the month mode must not break the projection either.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('week view survives repeated 课表/周/月 switches',
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

    // "now" must fall inside the displayed week so the current-time line
    // actually renders (that is where the orange takeover came from).
    await pumpWeekPage(tester, snapshot);

    expect(tester.takeException(), isNull);
    expect(find.text('高等数学'), findsWidgets, reason: 'the default view shows the course');

    // The current-time line must stay a thin rule. When its Positioned was
    // nested inside another Positioned, the outer geometry won and the line
    // was laid out as a full-day-width, full-height ORANGE block painted over
    // the events — the "orange background, content gone" report.
    Finder nowLine() => find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == AppTheme.nowLineColor);

    Future<void> switchTo(String tooltip) async {
      await tester.tap(find.byTooltip(tooltip));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      // Let the switcher drop the outgoing view before asserting finds.
      await tester.pump();
      expect(tester.takeException(), isNull, reason: '$tooltip threw');
    }

    final monthLabel = '${today.year}年${today.month}月';

    for (var i = 0; i < 3; i++) {
      await switchTo('切到课表视图');
      expect(find.text('高等数学'), findsWidgets,
          reason: '课表 must still render the course after switch $i');

      await switchTo('切到周视图');
      expect(find.text('高等数学'), findsWidgets,
          reason: '周 must still render the course after switch $i');
      expect(nowLine(), findsOneWidget,
          reason: 'now line should render in 周 after switch $i');
      final lineSize = tester.getSize(nowLine());
      expect(lineSize.height, lessThanOrEqualTo(4),
          reason: 'now line height was ${lineSize.height} (expected ~2)');

      await switchTo('切到月视图');
      expect(find.text(monthLabel), findsOneWidget,
          reason: '月 must show YYYY年M月 after switch $i');
      // The bare weekday header is unique to the month grid (the other two
      // views label columns 周一…周日).
      expect(find.text('一'), findsOneWidget,
          reason: 'month grid should render after switch $i');
    }
  });
}
