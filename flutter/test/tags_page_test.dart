import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/presentation/settings/tags_page.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: the tags/categories page hosted a bare [TabBar]/[TabBarView]
/// with no `DefaultTabController`, which threw a framework assertion
/// (`InheritedElement.debugDeactivated`: `_dependents.isEmpty`) and rendered a
/// red error screen. `CoursesPage` already wrapped its tabs correctly.
void main() {
  testWidgets('TagsPage renders its tabs without a TabController assertion',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          snapshotProvider.overrideWith(
            (ref) => Stream.value(const EntitiesSnapshot(
              rows: [],
              pendingOps: [],
              conflicts: [],
            )),
          ),
        ],
        child: const MaterialApp(home: TagsPage()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('标签 / 分类'), findsOneWidget);
    expect(find.text('标签 (0)'), findsOneWidget);
    expect(find.text('分类 (0)'), findsOneWidget);

    // "Add" must be reachable even when a list is non-empty (it used to only
    // exist inside the empty state), so a FAB is always present and switches
    // its label with the active tab.
    expect(find.text('新建标签'), findsOneWidget);
    await tester.tap(find.text('分类 (0)'));
    await tester.pumpAndSettle();
    expect(find.text('新建分类'), findsOneWidget);
  });
}
