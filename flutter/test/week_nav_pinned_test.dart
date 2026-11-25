import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart';

/// The permanent `‹ 今天 › 课程可长按拖动 [switch]` row is gone: the period title
/// owns those actions now (tap it → menu with 回到当前周 / 课程可长按拖动 /
/// 选择日期). The title also inverts: the week number is the headline and the
/// date range is the subtitle.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    pendingOps: const [],
    conflicts: const [],
  );

  testWidgets('the period title carries the actions menu and the week headline',
      (tester) async {
    await pumpWeekPage(tester, snapshot);

    // The old bar is gone in every mode.
    expect(find.text('今天'), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    expect(find.byIcon(Icons.chevron_right), findsNothing);

    // Week number is the big headline; the date range sits underneath it.
    final headline = find.textContaining('· 本周');
    expect(headline, findsOneWidget);
    final range = find.textContaining('月');
    expect(range, findsWidgets);
    final headlineSize = tester.widget<Text>(headline).style?.fontSize ?? 0;
    final rangeSize = tester
            .widgetList<Text>(range)
            .map((t) => t.style?.fontSize ?? 0)
            .reduce((a, b) => a < b ? a : b);
    expect(headlineSize, greaterThan(rangeSize),
        reason: 'week number must be the primary, date range the subtitle');

    // Tapping the title opens the menu.
    await tester.tap(headline);
    await tester.pumpAndSettle();
    expect(find.text('回到当前周'), findsOneWidget);
    expect(find.text('课程可长按拖动'), findsOneWidget);
    expect(find.text('选择日期…'), findsOneWidget);

    // The drag switch writes the same provider the 课表 tiles read.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    );
    expect(container.read(courseEditableInCourseViewProvider), isFalse);
    await tester.tap(find.text('课程可长按拖动'));
    await tester.pumpAndSettle();
    expect(container.read(courseEditableInCourseViewProvider), isTrue);

    // Closing returns to the timetable.
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('回到当前周'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
