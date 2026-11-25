import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/time/user_time.dart';
import '../data/local/view_models.dart';
import '../data/repo/entity_repo.dart';
import '../domain/entities.dart';
import '../domain/todo.dart';
import 'providers.dart';
import 'todo_sorting.dart';
import 'app_services.dart';
import 'sync_controller.dart';

/// One execution window the editor wants written together with its todo
/// (phase-4 task UX). Times are UTC instants; the editor converts its
/// wall-clock picks through [UserTime.utcFromLocalParts].
typedef NewTodoBlock = ({DateTime startUtc, DateTime endUtc, String? blockNote});

// The todo page's business layer: the filter/sort selection, every write that
// used to sit inline in `todo_page.dart`, and the derived board the list
// renders. Widgets keep only transient view state (controllers, drag offsets,
// collapsed sections).

/// Filter/sort selection of the todo list.
///
/// In memory only, and scoped to the page: when the list is disposed the
/// selection starts over at [TodoSort.initialDeadlineWholePage] (the previous
/// page fields had the same lifetime).
class TodoQuery {
  const TodoQuery({
    this.sort = TodoSort.initialDeadlineWholePage,
    this.showCompleted = false,
    this.tagIds = const <String>{},
  });

  final TodoSort sort;
  final bool showCompleted;

  /// Selected tag filter; empty means "no filter".
  final Set<String> tagIds;

  TodoQuery copyWith({
    TodoSort? sort,
    bool? showCompleted,
    Set<String>? tagIds,
  }) =>
      TodoQuery(
        sort: sort ?? this.sort,
        showCompleted: showCompleted ?? this.showCompleted,
        tagIds: tagIds ?? this.tagIds,
      );
}

/// Everything the todo list derives from the mirror: the open items grouped by
/// category and sorted, the completed tail, and the lookup maps the tiles need.
class TodoBoard {
  const TodoBoard({
    required this.loaded,
    required this.todoCount,
    required this.tags,
    required this.done,
    required this.groups,
    required this.tagById,
    required this.categoryById,
    required this.blocksByTodo,
  });

  /// Whether the mirror has produced a snapshot yet (drives the empty state).
  final bool loaded;

  final int todoCount;
  final List<Live<Tag>> tags;
  final List<Live<Todo>> done;

  /// Open items, grouped by category, already sorted (todo_sorting.dart).
  final List<TodoGroup> groups;
  final Map<String, Tag> tagById;
  final Map<String, Category> categoryById;
  final Map<String, List<TodoBlock>> blocksByTodo;
}

/// Owns the todo list's filter/sort state and every write the page performs.
class TodoController extends Notifier<TodoQuery> {
  @override
  TodoQuery build() => const TodoQuery();

  void setSortKey(TodoSortKey key) =>
      state = state.copyWith(sort: state.sort.copyWith(key: key));

  void setSortScope(TodoSortScope scope) =>
      state = state.copyWith(sort: state.sort.copyWith(scope: scope));

  void setShowCompleted(bool show) => state = state.copyWith(showCompleted: show);

  /// Adds/removes one tag from the filter. The set is copied so listeners see a
  /// new value.
  void toggleTagFilter(String tagId) {
    final next = {...state.tagIds};
    if (!next.remove(tagId)) next.add(tagId);
    state = state.copyWith(tagIds: next);
  }

  /// Completes / reopens a todo (local-first, then a background push).
  Future<void> setStatus(Todo todo, TodoStatus status) async {
    final services = ref.read(servicesProvider);
    await services.repo.localUpdate(
      entityType: EntityTypes.todo,
      entityId: todo.id,
      changes: {'status': status.wire},
    );
  }

  /// Deletes a todo and its queued work (the mirror keeps the tombstone).
  Future<void> delete(Todo todo) async {
    final services = ref.read(servicesProvider);
    await services.repo.localDelete(entityType: EntityTypes.todo, entityId: todo.id);
  }

  /// Inline "new category" from the editor. Returns the new id.
  Future<String> createCategory({required String name, String? color}) async {
    final services = ref.read(servicesProvider);
    final id = await services.repo.localCreate(
      entityType: EntityTypes.category,
      snapshot: {'name': name, 'color': color},
    );
    return id;
  }

  /// Inline "new tag" from the editor. Returns the new id.
  Future<String> createTag({required String name, String? color}) async {
    final services = ref.read(servicesProvider);
    final id = await services.repo.localCreate(
      entityType: EntityTypes.tag,
      snapshot: {'name': name, 'color': color},
    );
    return id;
  }

  /// Writes the editor sheet: creates when [existingId] is null, updates
  /// otherwise, and writes any [newBlocks] in the same local transaction.
  /// Wire keys stay here, not in the widget.
  ///
  /// No explicit `syncNow()`: the snapshot listener schedules the push once
  /// the queued operations show up (Phase 1).
  Future<void> saveTodo({
    String? existingId,
    required String title,
    required TodoType type,
    required String? description,
    required String? categoryId,
    required Iterable<String> tagIds,
    required TodoPriority priority,
    required DateTime? deadlineAt,
    required int? estimatedMinutes,
    List<NewTodoBlock> newBlocks = const [],
  }) async {
    final services = ref.read(servicesProvider);
    await writeTodoWithBlocks(
      repo: services.repo,
      userTime: ref.read(userTimeProvider),
      existingId: existingId,
      title: title,
      type: type,
      description: description,
      categoryId: categoryId,
      tagIds: tagIds.toList(),
      priority: priority,
      deadlineAt: deadlineAt,
      estimatedMinutes: estimatedMinutes,
      newBlocks: newBlocks,
    );
  }

  /// Writes one todo plus its new blocks in a single local transaction and
  /// returns the todo id.
  ///
  /// Kept static and repo-injected so tests can drive it against an in-memory
  /// [EntityRepo] without building the whole [AppServices] graph.
  @visibleForTesting
  static Future<String> writeTodoWithBlocks({
    required EntityRepo repo,
    required UserTime? userTime,
    required String? existingId,
    required String title,
    required TodoType type,
    required String? description,
    required String? categoryId,
    required List<String> tagIds,
    required TodoPriority priority,
    required DateTime? deadlineAt,
    required int? estimatedMinutes,
    required List<NewTodoBlock> newBlocks,
  }) async {
    // A one-off is a single errand: it holds at most one block. More than one
    // block means a multi-stage task, so the type upgrades to project here —
    // the user should not have to reason about the type up front.
    final effectiveType =
        newBlocks.length > 1 ? TodoType.project : type;
    final changes = <String, dynamic>{
      'title': title,
      'type': effectiveType.wire,
      'description': description,
      'categoryId': categoryId,
      'tagIds': tagIds,
      'priority': priority.wire,
      // Both types store it in deadlineAt; only the wording differs.
      'deadlineAt': deadlineAt,
    };
    if (estimatedMinutes != null) {
      changes['estimatedMinutes'] = estimatedMinutes;
    }

    // `EntityRepo.localCreate` opens its own transaction; drift nests those as
    // savepoints, so this outer one still makes the todo + blocks atomic.
    late String todoId;
    await repo.db.transaction(() async {
      if (existingId == null) {
        todoId = await repo.localCreate(
          entityType: EntityTypes.todo,
          snapshot: {...changes, 'status': TodoStatus.todo.wire},
        );
      } else {
        todoId = existingId;
        await repo.localUpdate(
          entityType: EntityTypes.todo,
          entityId: existingId,
          changes: changes,
        );
      }
      for (final snapshot in buildBlockSnapshots(
        todoId: todoId,
        blocks: newBlocks,
        userTime: userTime,
      )) {
        await repo.localCreate(
          entityType: EntityTypes.todoBlock,
          snapshot: snapshot,
        );
      }
    });
    return todoId;
  }

  /// Create-op snapshots for the editor's `newBlocks`.
  ///
  /// An invalid block is skipped (with a debug log) instead of failing the
  /// whole save: the todo itself is still worth keeping when one draft window
  /// crosses midnight or ends before it starts. The server would reject such a
  /// block with `CROSS_MIDNIGHT_NOT_ALLOWED`, so it never reaches the queue.
  @visibleForTesting
  static List<Map<String, dynamic>> buildBlockSnapshots({
    required String todoId,
    required List<NewTodoBlock> blocks,
    required UserTime? userTime,
  }) {
    final snapshots = <Map<String, dynamic>>[];
    for (final b in blocks) {
      if (!b.endUtc.isAfter(b.startUtc)) {
        debugPrint('[todo] skipped block with end <= start: '
            '${b.startUtc.toIso8601String()}..${b.endUtc.toIso8601String()}');
        continue;
      }
      if (userTime == null || !userTime.sameLocalDay(b.startUtc, b.endUtc)) {
        debugPrint('[todo] skipped block outside one local day: '
            '${b.startUtc.toIso8601String()}..${b.endUtc.toIso8601String()}');
        continue;
      }
      snapshots.add({
        'todoId': todoId,
        'startAt': b.startUtc,
        'endAt': b.endUtc,
        'blockNote': b.blockNote,
        'status': BlockStatus.scheduled.wire,
      });
    }
    return snapshots;
  }
}

final todoControllerProvider =
    NotifierProvider.autoDispose<TodoController, TodoQuery>(TodoController.new);

/// The rendered todo board. Derived once per mirror/filter change instead of on
/// every `build`.
///
/// Auto-disposed with the page, so the filter/sort selection starts fresh next
/// time the list is opened (the previous page fields behaved the same way).
final todoBoardProvider = Provider.autoDispose<TodoBoard>((ref) {
  final snap = ref.watch(snapshotProvider).value;
  final query = ref.watch(todoControllerProvider);

  final todos = snap == null ? const <Live<Todo>>[] : liveTodos(snap);
  final tags = snap == null ? const <Live<Tag>>[] : liveTags(snap);
  final categories = snap == null ? const <Live<Category>>[] : liveCategories(snap);
  final blocks = snap == null ? const <Live<TodoBlock>>[] : liveBlocks(snap);

  bool matches(Todo t) =>
      query.tagIds.isEmpty || query.tagIds.any(t.tagIds.contains);

  final open = todos.where((t) => !t.value.isCompleted && matches(t.value)).toList();
  final done = todos.where((t) => t.value.isCompleted && matches(t.value)).toList();

  final tagById = {for (final t in tags) t.value.id: t.value};
  final categoryById = {for (final c in categories) c.value.id: c.value};
  final blocksByTodo = <String, List<TodoBlock>>{};
  for (final b in blocks) {
    blocksByTodo.putIfAbsent(b.value.todoId, () => []).add(b.value);
  }

  // Group by category so the list reads as collapsible sections instead of one
  // flat run. Uncategorised (or dangling-category) todos form one group whose
  // id is null. The sorter then orders the rows inside each group and, for the
  // whole-page scope, the groups themselves (todo_sorting.dart).
  final groups = sortTodoGroups(<TodoGroup>[
    for (final c in categories)
      if (open.any((t) => t.value.categoryId == c.value.id))
        (id: c.value.id, items: open.where((t) => t.value.categoryId == c.value.id).toList()),
    if (open.any((t) =>
        t.value.categoryId == null || !categoryById.containsKey(t.value.categoryId)))
      (
        id: null,
        items: open
            .where((t) => t.value.categoryId == null ||
                !categoryById.containsKey(t.value.categoryId))
            .toList(),
      ),
  ], query.sort);

  return TodoBoard(
    loaded: snap != null,
    todoCount: todos.length,
    tags: tags,
    done: done,
    groups: groups,
    tagById: tagById,
    categoryById: categoryById,
    blocksByTodo: blocksByTodo,
  );
});
