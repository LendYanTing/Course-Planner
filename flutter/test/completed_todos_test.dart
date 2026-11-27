import 'dart:async';

import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/todo.dart';
import 'package:course_planner/presentation/todo/completed_todos_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:course_planner/state/todo_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// In-memory mirror the page reads: status/delete mutations re-emit a snapshot
/// so the list reacts exactly as it would against the local drift store.
class _FakeStore {
  _FakeStore(List<EntityRow> rows) : _rows = [...rows];

  final List<EntityRow> _rows;
  final StreamController<EntitiesSnapshot> _updates =
      StreamController<EntitiesSnapshot>.broadcast();

  final List<(String, TodoStatus)> statusCalls = [];
  final List<String> deleteCalls = [];

  Stream<EntitiesSnapshot> get updates => _updates.stream;

  EntitiesSnapshot snapshot() => EntitiesSnapshot(
        rows: List<EntityRow>.unmodifiable(_rows),
        pendingOps: const [],
        conflicts: const [],
      );

  void setStatus(String id, TodoStatus status) {
    final index = _rows.indexWhere(
      (r) => r.entityType == EntityTypes.todo && r.entityId == id,
    );
    if (index < 0) return;
    final row = _rows[index];
    _rows[index] = EntityRow(
      entityType: row.entityType,
      entityId: row.entityId,
      revision: row.revision,
      payload: {...row.payload, 'status': status.wire},
      updatedAt: row.updatedAt,
      deletedAt: row.deletedAt,
    );
    statusCalls.add((id, status));
    _updates.add(snapshot());
  }

  void delete(String id) {
    _rows.removeWhere(
      (r) => r.entityType == EntityTypes.todo && r.entityId == id,
    );
    deleteCalls.add(id);
    _updates.add(snapshot());
  }

  Future<void> dispose() => _updates.close();
}

/// Routes the page's writes to [_FakeStore] instead of the real service graph.
class _RecordingTodoController extends TodoController {
  _RecordingTodoController(this._store);

  final _FakeStore _store;

  @override
  Future<void> setStatus(Todo todo, TodoStatus status) async {
    _store.setStatus(todo.id, status);
  }

  @override
  Future<void> delete(Todo todo) async {
    _store.delete(todo.id);
  }
}

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
    String status = 'completed',
    String? categoryId,
    String? deadlineAt,
    String? createdAt = '2026-08-01T00:00:00Z',
    String? description,
    String priority = 'normal',
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
          'description': description,
          'priority': priority,
          'deadlineAt': deadlineAt,
          'createdAt': createdAt,
          'revision': 1,
        },
      );

  Future<_FakeStore> pumpPage(
    WidgetTester tester,
    List<EntityRow> rows, {
    Map<String, String>? prefs,
  }) async {
    final store = _FakeStore(rows);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs(prefs)),
          userTimeProvider.overrideWithValue(
            UserTime.tryCreate('Asia/Shanghai')!,
          ),
          snapshotProvider.overrideWith((ref) async* {
            yield store.snapshot();
            yield* store.updates;
          }),
          todoControllerProvider.overrideWith(
            () => _RecordingTodoController(store),
          ),
        ],
        child: const MaterialApp(home: CompletedTodosPage()),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('shows only completed todos, capped at the default 100',
      (tester) async {
    final base = DateTime.utc(2026, 1, 1);
    final rows = <EntityRow>[
      category('c-work', '工作'),
      category('c-life', '生活'),
      category('c-study', '学习'),
      for (var i = 1; i <= 120; i++)
        todo(
          'done-$i',
          '已完成 ${i.toString().padLeft(3, '0')}',
          categoryId: 'c-work',
          deadlineAt: base.add(Duration(days: i)).toIso8601String(),
        ),
      todo('open-1', '未完成一', status: 'todo', categoryId: 'c-life'),
      todo('open-2', '未完成二', status: 'in_progress', categoryId: 'c-study'),
    ];

    await pumpPage(tester, rows);

    expect(find.text('未完成一'), findsNothing);
    expect(find.text('未完成二'), findsNothing);
    expect(find.textContaining('共 120 条 · 显示最近 100 条'), findsOneWidget);
    expect(find.byType(ListTile), findsNWidgets(100));
    // Newest deadline first: the oldest 20 rows are cut off.
    expect(find.text('已完成 120'), findsOneWidget);
    expect(find.text('已完成 001'), findsNothing);
  });

  testWidgets('a stored limit of 0 shows the whole history', (tester) async {
    final base = DateTime.utc(2026, 1, 1);
    final rows = <EntityRow>[
      category('c-work', '工作'),
      for (var i = 1; i <= 120; i++)
        todo(
          'done-$i',
          '已完成 ${i.toString().padLeft(3, '0')}',
          categoryId: 'c-work',
          deadlineAt: base.add(Duration(days: i)).toIso8601String(),
        ),
    ];

    await pumpPage(tester, rows, prefs: {'completed_history_limit': '0'});

    expect(find.text('共 120 条'), findsOneWidget);
    expect(find.textContaining('显示最近'), findsNothing);
    expect(find.byType(ListTile), findsNWidgets(120));
    expect(find.text('已完成 001'), findsOneWidget);
  });

  testWidgets('keyword filters title and description case-insensitively',
      (tester) async {
    await pumpPage(tester, [
      todo('a', '写报告', categoryId: 'c-work'),
      todo('b', '买菜', categoryId: 'c-life', description: '记得买牛奶'),
      todo('c', '整理笔记', categoryId: 'c-study', description: '报告素材'),
      category('c-work', '工作'),
      category('c-life', '生活'),
      category('c-study', '学习'),
    ]);

    await tester.enterText(find.byType(TextField), '报告');
    await tester.pumpAndSettle();

    expect(find.text('写报告'), findsOneWidget);
    expect(find.text('整理笔记'), findsOneWidget);
    expect(find.text('买菜'), findsNothing);

    await tester.enterText(find.byType(TextField), '牛奶');
    await tester.pumpAndSettle();

    expect(find.text('买菜'), findsOneWidget);
    expect(find.text('写报告'), findsNothing);
  });

  testWidgets('category chips filter the history', (tester) async {
    await pumpPage(tester, [
      category('c-work', '工作'),
      category('c-life', '生活'),
      todo('w', '工作报告', categoryId: 'c-work'),
      todo('l', '打扫房间', categoryId: 'c-life'),
    ]);

    await tester.tap(find.widgetWithText(FilterChip, '工作'));
    await tester.pumpAndSettle();

    expect(find.text('工作报告'), findsOneWidget);
    expect(find.text('打扫房间'), findsNothing);
  });

  testWidgets('long press selects, 全选 selects all and restore reopens items',
      (tester) async {
    final store = await pumpPage(tester, [
      category('c-work', '工作'),
      todo('a', '已完成甲', categoryId: 'c-work'),
      todo('b', '已完成乙', categoryId: 'c-work'),
      todo('c', '已完成丙', categoryId: 'c-work'),
    ]);

    await tester.longPress(find.text('已完成甲'));
    await tester.pumpAndSettle();
    expect(find.text('已选 1'), findsOneWidget);

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选 3'), findsOneWidget);

    await tester.tap(find.text('恢复为待办 (3)'));
    await tester.pumpAndSettle();

    expect(find.text('已完成甲'), findsNothing);
    expect(find.text('已完成乙'), findsNothing);
    expect(find.text('已完成丙'), findsNothing);
    expect(store.statusCalls, hasLength(3));
    expect(store.statusCalls.every((c) => c.$2 == TodoStatus.todo), isTrue);
  });

  testWidgets('delete asks for confirmation and only removes on confirm',
      (tester) async {
    final store = await pumpPage(tester, [
      category('c-work', '工作'),
      todo('del-1', '待删除', categoryId: 'c-work'),
    ]);

    await tester.longPress(find.text('待删除'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('删除 (1)'));
    await tester.pumpAndSettle();
    expect(
      find.text('删除 1 个已完成任务？删除后无法恢复。'),
      findsOneWidget,
    );

    await tester.tap(find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(TextButton, '取消'),
    ));
    await tester.pumpAndSettle();
    expect(find.text('待删除'), findsOneWidget);
    expect(store.deleteCalls, isEmpty);

    await tester.tap(find.text('删除 (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '删除'));
    await tester.pumpAndSettle();

    expect(find.text('待删除'), findsNothing);
    expect(store.deleteCalls, ['del-1']);
  });

  testWidgets('time range control starts at 全部时间 with no clear action',
      (tester) async {
    await pumpPage(tester, [
      category('c-work', '工作'),
      todo('a', '已完成', categoryId: 'c-work'),
    ]);

    expect(find.widgetWithText(OutlinedButton, '全部时间'), findsOneWidget);
    expect(find.byIcon(Icons.date_range), findsOneWidget);
    // The clear icon only exists once a range has been picked.
    expect(find.byIcon(Icons.close), findsNothing);
  });
}
