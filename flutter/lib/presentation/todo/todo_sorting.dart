import '../../data/local/view_models.dart';
import '../../domain/todo.dart';

/// Ordering for the todo page's open list (ticket #3).
///
/// The page already groups open todos by category; this module decides the
/// order *within* each group and, when asked, the order *between* groups. It is
/// deliberately independent of `liveTodos` (the shared decode layer the
/// week/month views also consume) so the ordering never leaks out of the todo
/// feature.

/// One category section of the open list: its category id (`null` for the
/// trailing "uncategorised" group) and the items it holds.
typedef TodoGroup = ({String? id, List<Live<Todo>> items});

/// The key the sorter menu offers.
enum TodoSortKey {
  /// Nearest deadline first. The default. Items without a deadline sink.
  deadlineAsc,

  /// Farthest deadline first. Items without a deadline still sink.
  deadlineDesc,

  /// Highest priority first.
  priorityDesc,

  /// Most recently created first.
  createdDesc,
}

/// Whether the key also orders the category groups themselves, or only the
/// rows inside each group.
enum TodoSortScope {
  /// Groups are ordered by their own first item under the key.
  wholePage,

  /// Groups keep their category order; only their rows are sorted.
  withinGroup,
}

/// The page's in-memory sorter selection (not persisted across restarts).
class TodoSort {
  const TodoSort({
    this.key = TodoSortKey.deadlineAsc,
    this.scope = TodoSortScope.wholePage,
  });

  final TodoSortKey key;
  final TodoSortScope scope;

  /// Deadline (near→far) over the whole page, per ticket #3.
  static const TodoSort initial = TodoSort();

  TodoSort copyWith({TodoSortKey? key, TodoSortScope? scope}) =>
      TodoSort(key: key ?? this.key, scope: scope ?? this.scope);
}

/// Sorts one group's items by [key], with a stable tie-break: equal keys fall
/// back to higher priority first, then to the input order.
List<Live<Todo>> sortTodos(List<Live<Todo>> items, TodoSortKey key) {
  final indexed = [
    for (var i = 0; i < items.length; i++) (index: i, item: items[i]),
  ];
  indexed.sort((a, b) {
    final c = _compareItems(a.item.value, b.item.value, key);
    if (c != 0) return c;
    return a.index.compareTo(b.index);
  });
  return [for (final e in indexed) e.item];
}

/// Sorts every [groups] item list by [sort].key and, for
/// [TodoSortScope.wholePage], reorders the groups themselves by their first
/// item under the same key. Input order and the input lists are never mutated.
List<TodoGroup> sortTodoGroups(List<TodoGroup> groups, TodoSort sort) {
  final sorted = [
    for (final g in groups) (id: g.id, items: sortTodos(g.items, sort.key)),
  ];
  if (sort.scope == TodoSortScope.withinGroup) return sorted;

  final indexed = [
    for (var i = 0; i < sorted.length; i++) (index: i, group: sorted[i]),
  ];
  indexed.sort((a, b) {
    final c = _compareGroupFirst(a.group, b.group, sort.key);
    if (c != 0) return c;
    return a.index.compareTo(b.index);
  });
  return [for (final e in indexed) e.group];
}

int _compareGroupFirst(TodoGroup a, TodoGroup b, TodoSortKey key) {
  final aFirst = a.items.isEmpty ? null : a.items.first.value;
  final bFirst = b.items.isEmpty ? null : b.items.first.value;
  if (aFirst == null && bFirst == null) return 0;
  if (aFirst == null) return 1; // empty groups settle last
  if (bFirst == null) return -1;
  return _compareItems(aFirst, bFirst, key);
}

int _compareItems(Todo a, Todo b, TodoSortKey key) {
  final primary = _comparePrimary(a, b, key);
  if (primary != 0) return primary;
  return _priorityRank(b.priority) - _priorityRank(a.priority);
}

int _comparePrimary(Todo a, Todo b, TodoSortKey key) {
  switch (key) {
    case TodoSortKey.deadlineAsc:
      return _compareDeadline(a.deadlineAt, b.deadlineAt, ascending: true);
    case TodoSortKey.deadlineDesc:
      return _compareDeadline(a.deadlineAt, b.deadlineAt, ascending: false);
    case TodoSortKey.priorityDesc:
      return _priorityRank(b.priority) - _priorityRank(a.priority);
    case TodoSortKey.createdDesc:
      return _compareCreatedDesc(a.createdAt, b.createdAt);
  }
}

/// Deadline order with "no deadline" always sinking, in both directions.
int _compareDeadline(DateTime? a, DateTime? b, {required bool ascending}) {
  if (a == null && b == null) return 0;
  if (a == null) return 1;
  if (b == null) return -1;
  return ascending ? a.compareTo(b) : b.compareTo(a);
}

/// Newest first. A missing creation time counts as newest: the only todos
/// without one are local creates not yet acknowledged by the server, which are
/// by definition the most recent.
int _compareCreatedDesc(DateTime? a, DateTime? b) {
  if (a == null && b == null) return 0;
  if (a == null) return -1;
  if (b == null) return 1;
  return b.compareTo(a);
}

int _priorityRank(TodoPriority p) => switch (p) {
      TodoPriority.low => 0,
      TodoPriority.normal => 1,
      TodoPriority.high => 2,
      TodoPriority.urgent => 3,
    };
