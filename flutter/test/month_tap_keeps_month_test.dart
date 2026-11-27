import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:course_planner/presentation/calendar/month_view_content.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart';

/// Regression: tapping a date in 月 mode used to switch the page to 课表.
/// The day sheet should open while 月 stays the active view.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('tapping a day in month view keeps the month view', (
    tester,
  ) async {
    const snapshot = EntitiesSnapshot(
      rows: [],
      pendingOps: [],
      conflicts: [],
    );
    await pumpWeekPage(tester, snapshot);

    await tester.tap(find.byTooltip('切到月视图'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MonthViewContent), findsOneWidget);

    await tester.tap(find.text('15').first);
    await tester.pumpAndSettle();

    // The day sheet opened …
    expect(find.textContaining('15日 · 0 项'), findsOneWidget);
    // … and the page is still the month grid, not the 课表.
    expect(find.byType(MonthViewContent), findsOneWidget);
    expect(find.byType(GridViewContent), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
