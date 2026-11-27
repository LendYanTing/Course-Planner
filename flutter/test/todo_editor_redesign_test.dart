import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/adaptive/adaptive.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart' show FakeSession;

/// Phase 8: the todo editor is a three-block segmented-card sheet (immersive
/// borderless input card, time/schedule group, attribute group), and the todo
/// list renders each category as a segmented card.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpEditor(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    final userTime = UserTime.tryCreate('Asia/Shanghai')!;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [userTimeProvider.overrideWithValue(userTime)],
        child: const MaterialApp(
          home: Scaffold(body: TodoEditorSheet(tags: [], categories: [])),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final size in const [Size(360, 640), Size(320, 568)]) {
    testWidgets(
      'new todo sheet lays out cleanly at '
      '${size.width.toInt()}x${size.height.toInt()}',
      (tester) async {
        await pumpEditor(tester, size);

        // No RenderFlex overflow (those surface as taken exceptions).
        expect(tester.takeException(), isNull);
        expect(find.text('新建待办'), findsOneWidget);
        // Two segmented groups: time/schedule and attributes.
        expect(find.byType(AppSegmentedColumn), findsNWidgets(2));
      },
    );
  }

  testWidgets('title and note are borderless fields in one input card',
      (tester) async {
    await pumpEditor(tester, const Size(360, 640));

    final fields = tester.widgetList<TextField>(find.byType(TextField)).toList();
    expect(fields, hasLength(2));
    for (final field in fields) {
      expect(field.decoration?.border, InputBorder.none);
    }
    expect(find.text('准备做什么？'), findsOneWidget);
    expect(find.text('添加备注、要求或步骤（可选）…'), findsOneWidget);
  });

  testWidgets('quick time capsules share one horizontal row', (tester) async {
    await pumpEditor(tester, const Size(360, 640));

    const labels = ['今天 22:00', '明天 18:00', '周日 23:59', '自定义'];
    final tops = <double>[];
    for (final label in labels) {
      expect(find.text(label), findsOneWidget);
      tops.add(tester.getRect(find.text(label)).top);
    }
    // One row of chips: every label sits on the same line.
    expect(tops.toSet().length, 1);

    // The redundant explanatory copy is gone.
    expect(find.textContaining('提醒时间用于'), findsNothing);
  });

  testWidgets('category is picked with capsules, not a dropdown',
      (tester) async {
    await pumpEditor(tester, const Size(360, 640));

    expect(find.byWidgetPredicate((w) => w is DropdownButtonFormField), findsNothing);
    expect(find.widgetWithText(FilterChip, '无'), findsOneWidget);
    expect(find.text('分类'), findsOneWidget);
  });

  testWidgets('four priority capsules toggle their selection', (tester) async {
    await pumpEditor(tester, const Size(360, 640));

    expect(find.byType(ChoiceChip), findsNWidgets(4));
    final low = find.widgetWithText(ChoiceChip, '低');
    final normal = find.widgetWithText(ChoiceChip, '普通');
    expect(tester.widget<ChoiceChip>(normal).selected, isTrue);
    expect(tester.widget<ChoiceChip>(low).selected, isFalse);

    await tester.ensureVisible(low);
    await tester.pumpAndSettle();
    await tester.tap(low);
    await tester.pumpAndSettle();

    expect(tester.widget<ChoiceChip>(low).selected, isTrue);
    expect(tester.widget<ChoiceChip>(normal).selected, isFalse);
  });

  group('todo list', () {
    EntityRow category(String id, String name) => EntityRow(
          entityType: EntityTypes.category,
          entityId: id,
          revision: 1,
          payload: {'id': id, 'name': name, 'color': null, 'revision': 1},
        );

    EntityRow todo(String id, String title, String categoryId) => EntityRow(
          entityType: EntityTypes.todo,
          entityId: id,
          revision: 1,
          payload: {
            'id': id,
            'title': title,
            'type': 'one_off',
            'status': 'todo',
            'categoryId': categoryId,
            'priority': 'normal',
            'createdAt': '2026-09-01T00:00:00Z',
            'revision': 1,
          },
        );

    testWidgets('each category is a segmented card with a count badge',
        (tester) async {
      final snapshot = EntitiesSnapshot(
        rows: [
          category('c-work', '工作'),
          category('c-life', '生活'),
          todo('w1', '写周报', 'c-work'),
          todo('w2', '改稿', 'c-work'),
          todo('l1', '买菜', 'c-life'),
          todo('l2', '交房租', 'c-life'),
        ],
        pendingOps: const [],
        conflicts: const [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionControllerProvider.overrideWith(FakeSession.new),
            userTimeProvider.overrideWithValue(UserTime.tryCreate('Asia/Shanghai')!),
            snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
          ],
          child: const MaterialApp(home: TodoPage()),
        ),
      );
      await tester.pumpAndSettle();

      // One segmented card per category, rows no longer bare ListTiles.
      expect(find.byType(AppSegmentedColumn), findsNWidgets(2));
      expect(find.byType(ListTile), findsNothing);

      expect(
        tester.widget<Text>(find.byKey(const ValueKey('todo-group-count-工作'))).data,
        '2',
      );
      expect(
        tester.widget<Text>(find.byKey(const ValueKey('todo-group-count-生活'))).data,
        '2',
      );

      for (final title in ['写周报', '改稿', '买菜', '交房租']) {
        expect(find.text(title), findsOneWidget);
        expect(
          find.ancestor(
            of: find.text(title),
            matching: find.byType(AppSegmentedColumn),
          ),
          findsOneWidget,
        );
      }
    });
  });
}
