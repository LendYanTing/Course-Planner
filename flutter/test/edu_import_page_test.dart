import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/presentation/settings/edu_import_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';
import 'helpers/week_page_harness.dart';

/// Education-system import page (phase 6 Step 2).
///
/// Only the local, offline path is exercised: the page is pumped against a
/// fixed snapshot and the pasted-text parser runs without any network call.
void main() {
  EntitiesSnapshot snapshotWithSemester({bool withSemester = false}) {
    return EntitiesSnapshot(
      rows: [
        if (withSemester)
          const EntityRow(
            entityType: 'academic_calendar',
            entityId: 'cal-1',
            revision: 1,
            payload: {
              'id': 'cal-1',
              'name': '2026 秋季',
              'firstDay': '2026-09-01',
              'totalWeeks': 20,
              'revision': 1,
            },
          ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );
  }

  Future<void> pumpPage(WidgetTester tester, EntitiesSnapshot snapshot) async {
    // Tall enough that the whole wizard (preview + confirm) is built and
    // hit-testable without scrolling.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          sessionControllerProvider.overrideWith(FakeSession.new),
          serverNowProvider.overrideWith(
            (ref) => Stream.value(DateTime.utc(2026, 9, 9)),
          ),
        ],
        child: const MaterialApp(home: EduImportPage()),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('没有学期时提供一键创建当前学期', (tester) async {
    await pumpPage(tester, snapshotWithSemester());

    expect(find.text('目标学期'), findsOneWidget);
    expect(find.text('一键创建当前学期'), findsOneWidget);
    // No dropdown yet, but the paste workflow is already available.
    expect(find.text('导入到学期'), findsNothing);
    expect(find.text('粘贴网页/文本'), findsOneWidget);
    expect(find.text('自动识别课表'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('有学期时显示下拉、粘贴框与两种识别按钮', (tester) async {
    await pumpPage(tester, snapshotWithSemester(withSemester: true));

    expect(find.text('一键创建当前学期'), findsNothing);
    expect(find.text('导入到学期'), findsOneWidget);
    expect(find.text('2026 秋季'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('自动识别课表'), findsOneWidget);
    expect(find.text('使用 AI 深度解析'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动识别课表把课程放进预览', (tester) async {
    await pumpPage(tester, snapshotWithSemester(withSemester: true));

    await tester.enterText(
      find.byType(TextField),
      '高等数学 周一 1-2节 1-16周 张老师 逸夫楼201',
    );
    await tester.tap(find.text('自动识别课表'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('高等数学'), findsOneWidget);
    expect(find.text('识别到 1 门课（来源：本地）'), findsOneWidget);
    expect(find.text('确认导入 1 门课程'), findsOneWidget);
    // The preview shows the parsed meeting and teacher/room on one line.
    expect(find.text('周一 第1-2节 · 周次 1-16 · 张老师 · 逸夫楼201'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
