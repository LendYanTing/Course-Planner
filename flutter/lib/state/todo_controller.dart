import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/local/view_models.dart';
import '../domain/entities.dart';
import '../domain/todo.dart';
import 'todo_sorting.dart';
import 'app_services.dart';
import 'sync_controller.dart';

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
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  /// Deletes a todo and its queued work (the mirror keeps the tombstone).
  Future<void> delete(Todo todo) async {
    final services = ref.read(servicesProvider);
    await services.repo.localDelete(entityType: EntityTypes.todo, entityId: todo.id);
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  /// Inline "new category" from the editor. Returns the new id.
  Future<String> createCategory({required String name, String? color}) async {
    final services = ref.read(servicesProvider);
    final id = await services.repo.localCreate(
      entityType: EntityTypes.category,
      snapshot: {'name': name, 'color': color},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    return id;
  }

  /// Inline "new tag" from the editor. Returns the new id.
  Future<String> createTag({required String name, String? color}) async {
    final services = ref.read(servicesProvider);
    final id = await services.repo.localCreate(
      entityType: EntityTypes.tag,
      snapshot: {'name': name, 'color': color},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    return id;
  }

  /// Writes the editor sheet: creates when [existingId] is null, updates
  /// otherwise, then pushes. Wire keys stay here, not in the widget.
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
  }) async {
    final services = ref.read(servicesProvider);
    final changes = <String, dynamic>{
      'title': title,
      'type': type.wire,
      'description': description,
      'categoryId': categoryId,
      'tagIds': tagIds.toList(),
      'priority': priority.wire,
      // Both types store it in deadlineAt; only the wording differs.
      'deadlineAt': deadlineAt,
    };
    if (estimatedMinutes != null) {
      changes['estimatedMinutes'] = estimatedMinutes;
    }
    if (existingId == null) {
      await services.repo.localCreate(
        entityType: EntityTypes.todo,
        snapshot: {...changes, 'status': TodoStatus.todo.wire},
      );
    } else {
      await services.repo.localUpdate(
        entityType: EntityTypes.todo,
        entityId: existingId,
        changes: changes,
      );
    }
    ref.read(syncCoordinatorProvider.notifier).syncNow();
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
