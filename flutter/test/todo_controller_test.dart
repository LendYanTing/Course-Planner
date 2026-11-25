import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/state/todo_sorting.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:course_planner/state/todo_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The todo page's logic now lives in `lib/state/todo_controller.dart`: the
/// derived board (filter → group → sort) and the filter/sort selection.
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
}
