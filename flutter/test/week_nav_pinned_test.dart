import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart';

/// ‹ 今天 › (and the 课程可长按拖动 switch) must stay pinned above the timetable:
/// stepping a week slides only the content, never the controls the user is
/// touching. Before, the whole column — toolbar included — lived inside the
/// [AnimatedSwitcher], so the bar slid out and back on every week change.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('week navigation bar does not slide with the week', (tester) async {
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

    await pumpWeekPage(tester, snapshot);

    // The switch lives in the pinned bar, so grid mode is where it shows.
    final toGrid = find.byTooltip('切到课表视图');
    if (toGrid.evaluate().isNotEmpty) {
      await tester.tap(toGrid);
      await tester.pumpAndSettle();
    }
    expect(find.text('课程可长按拖动'), findsOneWidget);

    final today = find.text('今天');
    expect(today, findsOneWidget);
    final before = tester.getTopLeft(today);

    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump(); // start the slide
    await tester.pump(const Duration(milliseconds: 80));

    // Mid-transition: one bar only, still at the same place (the timetable
    // below it is what animates).
    expect(find.text('今天'), findsOneWidget,
        reason: 'the bar must not be duplicated into the sliding content');
    expect(tester.getTopLeft(find.text('今天')), before,
        reason: 'the bar must not move with the week');
    expect(tester.takeException(), isNull);

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('今天')), before);
    expect(find.text('课程可长按拖动'), findsOneWidget);
  });
}
