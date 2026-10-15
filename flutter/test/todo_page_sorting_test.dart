import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ticket #3: the AppBar sorter reorders the open list in place — default
/// deadline (near→far) across the whole page, and switching key reorders the
/// category groups too.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  EntityRow category(String id, String name) => EntityRow(
        entityType: EntityTypes.category,
        entityId: id,
        revision: 1,
        payload: {'id': id, 'name': name, 'color': null, 'revision': 1},
      );

  EntityRow todo(
    String id,
    String title, {
    String? categoryId,
    String? deadlineAt,
    String priority = 'normal',
    String status = 'todo',
  }) =>
      EntityRow(
        entityType: EntityTypes.todo,
        entityId: id,
        revision: 1,
        payload: {
          'id': id,
          'title': title,
          'type': 'one_off',
          'status': status,
          'categoryId': categoryId,
          'priority': priority,
          'deadlineAt': deadlineAt,
          'createdAt': '2026-09-01T00:00:00Z',
          'revision': 1,
        },
      );

  // One-off todos: the same deadlineAt the sorter reads. The list only needs
  // titles to assert order, so the reminder/deadline wording is not asserted.
  final snapshot = EntitiesSnapshot(
    rows: [
      category('c-work', '工作'),
      category('c-life', '生活'),
      todo('w-far', '远端', categoryId: 'c-work', deadlineAt: '2026-09-20T01:00:00Z'),
      todo('w-near', '近端', categoryId: 'c-work', deadlineAt: '2026-09-10T01:00:00Z', priority: 'low'),
      todo('l-urgent', '紧急无截止', categoryId: 'c-life', priority: 'urgent'),
    ],
    pendingOps: const [],
    conflicts: const [],
  );

  Future<void> pumpPage(
    WidgetTester tester, {
    EntitiesSnapshot? snap,
    bool withUserTime = true,
  }) async {
    // The page renders deadlines in the fixed user timezone (watched in
    // build), so pin it instead of booting the session/services graph. Set
    // [withUserTime] false to model "not signed in / profile not rehydrated".
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          userTimeProvider.overrideWithValue(
              withUserTime ? UserTime.tryCreate('Asia/Shanghai')! : null),
          snapshotProvider.overrideWith((ref) => Stream.value(snap ?? snapshot)),
        ],
        child: const MaterialApp(home: TodoPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  double dy(WidgetTester tester, String title) =>
      tester.getTopLeft(find.text(title)).dy;

  testWidgets('defaults to deadline (near→far) across the whole page',
      (tester) async {
    await pumpPage(tester);

    // "工作" holds the nearest deadline, so it leads; the deadline-less
    // "生活" group sinks; rows read near → far.
    expect(dy(tester, '近端') < dy(tester, '远端'), isTrue);
    expect(dy(tester, '远端') < dy(tester, '紧急无截止'), isTrue);

    // The sorter control is present alongside the sync action.
    expect(find.byIcon(Icons.sort), findsOneWidget);
  });

  testWidgets('choosing priority (high→low) reorders rows and groups',
      (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, '优先级（高→低）'));
    await tester.pumpAndSettle();

    // The urgent row now leads; the whole-page scope also lifts its group
    // ("生活") above "工作".
    expect(dy(tester, '紧急无截止') < dy(tester, '远端'), isTrue);
    expect(dy(tester, '紧急无截止') < dy(tester, '近端'), isTrue);
  });

  testWidgets('within-group scope keeps the category order', (tester) async {
    await pumpPage(tester);

    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, '优先级（高→低）'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(CheckedPopupMenuItem<Object>, '仅组内'));
    await tester.pumpAndSettle();

    // Category order is preserved (工作 before 生活) even though 生活 holds the
    // highest-priority row.
    expect(dy(tester, '远端') < dy(tester, '紧急无截止'), isTrue);
  });

  testWidgets('the 已完成 section stays the fixed trailing block', (tester) async {
    // The completed todo has the nearest deadline, so a sorter that fed the
    // 已完成 section through itself would lift it to the top. It must not.
    final withCompleted = EntitiesSnapshot(
      rows: [
        category('c-work', '工作'),
        todo('w-far', '远端', categoryId: 'c-work', deadlineAt: '2026-09-20T01:00:00Z'),
        todo('done-near', '已完成最早', deadlineAt: '2026-09-01T01:00:00Z', status: 'completed'),
      ],
      pendingOps: const [],
      conflicts: const [],
    );
    await pumpPage(tester, snap: withCompleted);

    // Overflow menu -> 包含已完成.
    await tester.tap(find.descendant(
      of: find.byType(AppBar),
      matching: find.byType(PopupMenuButton<String>),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('包含已完成'));
    await tester.pumpAndSettle();

    expect(find.text('已完成'), findsOneWidget); // the section header
    expect(dy(tester, '远端') < dy(tester, '已完成最早'), isTrue);
  });

  testWidgets('with no user timezone the list prints no deadline wall clock',
      (tester) async {
    // 2026-09-20T01:00Z is 09:00 Asia/Shanghai; with no user timezone there is
    // no honest wall clock, so neither the correct nor the UTC clock appears.
    final withDeadline = EntitiesSnapshot(
      rows: [todo('t', '无时区待办', deadlineAt: '2026-09-20T01:00:00Z')],
      pendingOps: const [],
      conflicts: const [],
    );
    await pumpPage(tester, snap: withDeadline, withUserTime: false);

    expect(find.text('无时区待办'), findsOneWidget);
    expect(find.textContaining('截止'), findsNothing);
    expect(find.textContaining('09:00'), findsNothing);
    expect(find.textContaining('01:00'), findsNothing);
  });
}
