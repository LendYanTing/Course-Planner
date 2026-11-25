import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/todo.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/todo_sorting.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:course_planner/state/todo_controller.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

/// The todo page's logic now lives in `lib/state/todo_controller.dart`: the
/// derived board (filter → group → sort) and the filter/sort selection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

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
    List<String> tagIds = const [],
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
          'tagIds': tagIds,
          'createdAt': '2026-09-01T00:00:00Z',
          'revision': 1,
        },
      );

  final snapshot = EntitiesSnapshot(
    rows: [
      category('c-work', '工作'),
      category('c-life', '生活'),
      todo('w-far', '远端', categoryId: 'c-work', deadlineAt: '2026-09-20T01:00:00Z'),
      todo('w-near', '近端', categoryId: 'c-work', deadlineAt: '2026-09-10T01:00:00Z', priority: 'low'),
      todo('l-urgent', '紧急无截止', categoryId: 'c-life', priority: 'urgent', tagIds: ['t1']),
      todo('done', '已完成', categoryId: 'c-work', status: 'completed', deadlineAt: '2026-09-01T01:00:00Z'),
    ],
    pendingOps: const [],
    conflicts: const [],
  );

  Future<ProviderContainer> boot() async {
    final container = ProviderContainer(
      overrides: [snapshotProvider.overrideWith((ref) => Stream.value(snapshot))],
    );
    addTearDown(container.dispose);
    container.listen(snapshotProvider, (_, _) {});
    await pumpEventQueue();
    return container;
  }

  List<String> groupTitles(TodoBoard board) =>
      [for (final g in board.groups) g.id ?? 'none'];

  List<String> groupRows(TodoBoard board, String? id) => [
        for (final live
            in board.groups.firstWhere((g) => g.id == id).items)
          live.value.title,
      ];

  test('groups by category, sorted by deadline across the whole page', () async {
    final container = await boot();
    final board = container.read(todoBoardProvider);

    // 工作 holds the nearest deadline, so it leads; 生活 (no deadline) sinks.
    expect(groupTitles(board), ['c-work', 'c-life']);
    expect(groupRows(board, 'c-work'), ['近端', '远端']);
    // Completed items never join the open groups.
    expect(board.done.map((e) => e.value.title), ['已完成']);
  });

  test('the sort selection reorders rows and groups', () async {
    final container = await boot();
    final controller = container.read(todoControllerProvider.notifier);

    controller.setSortKey(TodoSortKey.priorityDesc);
    var board = container.read(todoBoardProvider);
    expect(groupTitles(board), ['c-life', 'c-work'],
        reason: 'the urgent group must lead for the whole-page scope');
    expect(groupRows(board, 'c-work'), ['远端', '近端'],
        reason: 'equal priority falls back to input order');

    controller.setSortScope(TodoSortScope.withinGroup);
    board = container.read(todoBoardProvider);
    expect(groupTitles(board), ['c-work', 'c-life'],
        reason: 'within-group keeps the category order');
  });

  test('the tag filter drops non-matching rows and the completed tail', () async {
    final container = await boot();
    final controller = container.read(todoControllerProvider.notifier);

    controller.toggleTagFilter('t1');
    final board = container.read(todoBoardProvider);

    expect(board.groups.expand((g) => g.items), hasLength(1));
    expect(groupTitles(board), ['c-life']);
    expect(board.done, isEmpty);

    controller.toggleTagFilter('t1');
    expect(container.read(todoBoardProvider).done, isNotEmpty);
  });

  test('a dangling or missing category lands in the uncategorised group', () async {
    final orphanSnapshot = EntitiesSnapshot(
      rows: [
        category('c-work', '工作'),
        // Points at a category that no longer exists.
        todo('a', '悬空分类', categoryId: 'missing'),
        // No category at all.
        todo('b', '无分类'),
      ],
      pendingOps: const [],
      conflicts: const [],
    );
    final container = ProviderContainer(
      overrides: [snapshotProvider.overrideWith((ref) => Stream.value(orphanSnapshot))],
    );
    addTearDown(container.dispose);
    container.listen(snapshotProvider, (_, _) {});
    await pumpEventQueue();

    final board = container.read(todoBoardProvider);
    expect(groupTitles(board), ['none']);
    expect(groupRows(board, null), ['悬空分类', '无分类']);
  });

  test('showCompleted is view state, not part of the derived board', () async {
    final container = await boot();
    final controller = container.read(todoControllerProvider.notifier);

    expect(container.read(todoControllerProvider).showCompleted, isFalse);
    controller.setShowCompleted(true);
    expect(container.read(todoControllerProvider).showCompleted, isTrue);
    // The board always carries the completed tail; the page decides to show it.
    expect(container.read(todoBoardProvider).done, hasLength(1));
  });

  // ---- one-stop Todo + TodoBlock creation (phase-4 task UX) ---------------

  group('saveTodo blocks', () {
    final userTime = UserTime.tryCreate('Asia/Shanghai')!;

    // 2026-09-07 10:00–11:00 Asia/Shanghai (+08).
    final start = userTime.utcFromLocalParts(2026, 9, 7, 10, 0);
    final end = userTime.utcFromLocalParts(2026, 9, 7, 11, 0);

    late AppDatabase db;
    late SyncStore store;
    late EntityRepo repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = SyncStore(db);
      repo = EntityRepo(db, store);
    });

    tearDown(() async {
      await db.close();
    });

    test('block snapshots carry todoId, window, note and scheduled status', () {
      final snapshots = TodoController.buildBlockSnapshots(
        todoId: 't1',
        blocks: [(startUtc: start, endUtc: end, blockNote: '写第三章')],
        userTime: userTime,
      );

      final snapshot = snapshots.single;
      expect(snapshot['todoId'], 't1');
      expect(snapshot['startAt'], start);
      expect(snapshot['endAt'], end);
      expect(snapshot['blockNote'], '写第三章');
      expect(snapshot['status'], BlockStatus.scheduled.wire);
    });

    test('cross-midnight and non-forward windows are skipped, not written', () {
      final snapshots = TodoController.buildBlockSnapshots(
        todoId: 't1',
        blocks: [
          // 23:30 -> 00:30 next local day.
          (
            startUtc: userTime.utcFromLocalParts(2026, 9, 7, 23, 30),
            endUtc: userTime.utcFromLocalParts(2026, 9, 8, 0, 30),
            blockNote: null,
          ),
          // end == start.
          (startUtc: start, endUtc: start, blockNote: null),
        ],
        userTime: userTime,
      );

      expect(snapshots, isEmpty);
    });

    test('writes the todo and its blocks locally; 2 blocks upgrade to project',
        () async {
      final singleId = await TodoController.writeTodoWithBlocks(
        repo: repo,
        userTime: userTime,
        existingId: null,
        title: '只有一个时间块',
        type: TodoType.oneOff,
        description: null,
        categoryId: null,
        tagIds: const [],
        priority: TodoPriority.normal,
        deadlineAt: null,
        estimatedMinutes: null,
        newBlocks: [(startUtc: start, endUtc: end, blockNote: null)],
      );

      final single = await store.entityRow(EntityTypes.todo, singleId);
      expect(single!.payload['type'], TodoType.oneOff.wire);
      final singleBlocks = (await store.entitiesOfType(EntityTypes.todoBlock))
          .where((b) => b.payload['todoId'] == singleId)
          .toList();
      expect(singleBlocks, hasLength(1));
      expect(singleBlocks.single.payload['status'], BlockStatus.scheduled.wire);

      final projectId = await TodoController.writeTodoWithBlocks(
        repo: repo,
        userTime: userTime,
        existingId: null,
        title: '两个时间块',
        // The caller's type is overridden: more than one window is a project.
        type: TodoType.oneOff,
        description: null,
        categoryId: null,
        tagIds: const [],
        priority: TodoPriority.high,
        deadlineAt: null,
        estimatedMinutes: 90,
        newBlocks: [
          (startUtc: start, endUtc: end, blockNote: '第一段'),
          (
            startUtc: userTime.utcFromLocalParts(2026, 9, 8, 14, 0),
            endUtc: userTime.utcFromLocalParts(2026, 9, 8, 16, 0),
            blockNote: '第二段',
          ),
        ],
      );

      final project = await store.entityRow(EntityTypes.todo, projectId);
      expect(project!.payload['type'], TodoType.project.wire);
      final projectBlocks = (await store.entitiesOfType(EntityTypes.todoBlock))
          .where((b) => b.payload['todoId'] == projectId)
          .toList();
      expect(projectBlocks, hasLength(2));

      // Every create is queued for the sync engine (no explicit syncNow call).
      final ops = await store.pendingOps();
      expect(ops.where((o) => o.entityType == EntityTypes.todo), hasLength(2));
      expect(ops.where((o) => o.entityType == EntityTypes.todoBlock), hasLength(3));
    });

    test('editing an existing todo adds blocks without a second todo', () async {
      final id = await TodoController.writeTodoWithBlocks(
        repo: repo,
        userTime: userTime,
        existingId: null,
        title: '已有待办',
        type: TodoType.oneOff,
        description: null,
        categoryId: null,
        tagIds: const [],
        priority: TodoPriority.normal,
        deadlineAt: null,
        estimatedMinutes: null,
        newBlocks: const [],
      );

      await TodoController.writeTodoWithBlocks(
        repo: repo,
        userTime: userTime,
        existingId: id,
        title: '已有待办',
        type: TodoType.oneOff,
        description: null,
        categoryId: null,
        tagIds: const [],
        priority: TodoPriority.normal,
        deadlineAt: null,
        estimatedMinutes: null,
        newBlocks: [(startUtc: start, endUtc: end, blockNote: null)],
      );

      expect(await store.entitiesOfType(EntityTypes.todo), hasLength(1));
      expect(await store.entitiesOfType(EntityTypes.todoBlock), hasLength(1));
    });
  });

  testWidgets('quick chip 今天 22:00 sets the reminder in the user timezone',
      (tester) async {
    final userTime = UserTime.tryCreate('Asia/Shanghai')!;
    await tester.pumpWidget(ProviderScope(
      overrides: [userTimeProvider.overrideWithValue(userTime)],
      child: const MaterialApp(
        home: Scaffold(body: TodoEditorSheet(tags: [], categories: [])),
      ),
    ));

    await tester.tap(find.text('今天 22:00'));
    await tester.pump();

    // The reminder button echoes the picked wall clock (one-off wording).
    // `OutlinedButton.icon` builds a subclass, hence the predicate.
    final label = tester.widget<Text>(find.descendant(
      of: find.byWidgetPredicate((w) => w is OutlinedButton),
      matching: find.byType(Text),
    ));
    expect(label.data, contains('提醒'));
    expect(label.data, contains('22:00'));
  });
}
