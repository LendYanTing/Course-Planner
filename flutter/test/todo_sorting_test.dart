import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/domain/todo.dart';
import 'package:course_planner/presentation/todo/todo_sorting.dart';
import 'package:flutter_test/flutter_test.dart';

/// Ticket #3: the todo page's open list orders its category groups and their
/// rows by a user-chosen key, defaulting to deadline (near→far) across the
/// whole page.
Todo todo(
  String id, {
  DateTime? deadline,
  TodoPriority priority = TodoPriority.normal,
  DateTime? createdAt,
}) =>
    Todo(
      id: id,
      title: id,
      type: TodoType.oneOff,
      priority: priority,
      status: TodoStatus.todo,
      revision: 1,
      deadlineAt: deadline,
      createdAt: createdAt,
    );

Live<Todo> live(Todo t) => Live(t);

TodoGroup section(String? id, List<Live<Todo>> items) => (id: id, items: items);

List<String> ids(List<Live<Todo>> items) => [for (final e in items) e.value.id];

List<String?> groupIds(List<TodoGroup> groups) => [for (final g in groups) g.id];

void main() {
  group('deadline ascending (default)', () {
    test('near to far, items without a deadline sink to the bottom', () {
      final items = [
        live(todo('none')),
        live(todo('late', deadline: DateTime.utc(2026, 9, 20))),
        live(todo('soon', deadline: DateTime.utc(2026, 9, 10))),
      ];

      expect(ids(sortTodos(items, TodoSortKey.deadlineAsc)), [
        'soon',
        'late',
        'none',
      ]);
    });

    test('ties keep their input order', () {
      final items = [
        live(todo('b', deadline: DateTime.utc(2026, 9, 10))),
        live(todo('a', deadline: DateTime.utc(2026, 9, 10))),
        live(todo('c', deadline: DateTime.utc(2026, 9, 10))),
      ];

      expect(ids(sortTodos(items, TodoSortKey.deadlineAsc)), ['b', 'a', 'c']);
    });
  });

  group('deadline descending', () {
    test('far to near, items without a deadline still sink', () {
      final items = [
        live(todo('none')),
        live(todo('soon', deadline: DateTime.utc(2026, 9, 10))),
        live(todo('late', deadline: DateTime.utc(2026, 9, 20))),
      ];

      expect(ids(sortTodos(items, TodoSortKey.deadlineDesc)), [
        'late',
        'soon',
        'none',
      ]);
    });
  });

  group('priority descending', () {
    test('urgent first, low last, deadline is ignored', () {
      final items = [
        live(todo('low', priority: TodoPriority.low)),
        live(todo('urgent', priority: TodoPriority.urgent)),
        live(todo('normal')),
        live(todo('high', priority: TodoPriority.high)),
      ];

      expect(ids(sortTodos(items, TodoSortKey.priorityDesc)), [
        'urgent',
        'high',
        'normal',
        'low',
      ]);
    });

    test('a deadline-less item is not treated specially', () {
      final items = [
        live(todo('dated', deadline: DateTime.utc(2026, 9, 10))),
        live(todo('undated', priority: TodoPriority.urgent)),
      ];

      expect(ids(sortTodos(items, TodoSortKey.priorityDesc)), [
        'undated',
        'dated',
      ]);
    });
  });

  group('created descending', () {
    test('newest first, a missing creation time counts as newest', () {
      final items = [
        live(todo('old', createdAt: DateTime.utc(2026, 9, 1))),
        live(todo('brand-new')),
        live(todo('newer', createdAt: DateTime.utc(2026, 9, 5))),
      ];

      expect(ids(sortTodos(items, TodoSortKey.createdDesc)), [
        'brand-new',
        'newer',
        'old',
      ]);
    });
  });

  group('tie-break', () {
    test('equal keys fall back to higher priority first', () {
      final d = DateTime.utc(2026, 9, 10);
      final items = [
        live(todo('low', deadline: d, priority: TodoPriority.low)),
        live(todo('urgent', deadline: d, priority: TodoPriority.urgent)),
        live(todo('high', deadline: d, priority: TodoPriority.high)),
      ];

      expect(ids(sortTodos(items, TodoSortKey.deadlineAsc)), [
        'urgent',
        'high',
        'low',
      ]);
    });

    test('equal key and equal priority keep their input order', () {
      final d = DateTime.utc(2026, 9, 10);
      final items = [
        live(todo('first', deadline: d, priority: TodoPriority.high)),
        live(todo('second', deadline: d, priority: TodoPriority.high)),
        live(todo('third', deadline: d, priority: TodoPriority.high)),
      ];

      expect(ids(sortTodos(items, TodoSortKey.deadlineAsc)), [
        'first',
        'second',
        'third',
      ]);
    });
  });

  group('scope', () {
    test('withinGroup sorts each group but keeps the category order', () {
      final groups = [
        section('work', [
          live(todo('w-late', deadline: DateTime.utc(2026, 9, 20))),
          live(todo('w-soon', deadline: DateTime.utc(2026, 9, 10))),
        ]),
        section(null, [
          live(todo('none')),
          live(todo('u-soon', deadline: DateTime.utc(2026, 9, 12))),
        ]),
      ];

      final out = sortTodoGroups(
        groups,
        const TodoSort(scope: TodoSortScope.withinGroup),
      );

      expect(groupIds(out), ['work', null]);
      expect(ids(out[0].items), ['w-soon', 'w-late']);
      expect(ids(out[1].items), ['u-soon', 'none']);
    });

    test('wholePage orders groups by their first item under the same key', () {
      final groups = [
        section('work', [live(todo('w', deadline: DateTime.utc(2026, 9, 20)))]),
        section('life', [live(todo('l', deadline: DateTime.utc(2026, 9, 11)))]),
        section(null, [live(todo('u'))]),
      ];

      // Default: deadlineAsc over the whole page.
      final out = sortTodoGroups(groups, TodoSort.initialDeadlineWholePage);

      // "life" has the nearest deadline; the deadline-less group sinks.
      expect(groupIds(out), ['life', 'work', null]);
    });

    test('wholePage ranks a group by its earliest item, not its first row', () {
      final groups = [
        section('work', [
          live(todo('w-late', deadline: DateTime.utc(2026, 9, 20))),
          live(todo('w-soon', deadline: DateTime.utc(2026, 9, 9))),
        ]),
        section('life', [live(todo('l', deadline: DateTime.utc(2026, 9, 15)))]),
      ];

      final out = sortTodoGroups(groups, TodoSort.initialDeadlineWholePage);

      expect(groupIds(out), ['work', 'life']);
      expect(ids(out[0].items), ['w-soon', 'w-late']);
    });

    test('wholePage with priority reads the key from the top down', () {
      final groups = [
        section('low', [live(todo('low', priority: TodoPriority.low))]),
        section('urgent', [live(todo('urgent', priority: TodoPriority.urgent))]),
      ];

      final out = sortTodoGroups(
        groups,
        const TodoSort(key: TodoSortKey.priorityDesc),
      );

      expect(groupIds(out), ['urgent', 'low']);
    });

    test('wholePage with created orders groups newest first', () {
      final groups = [
        section('old', [live(todo('old', createdAt: DateTime.utc(2026, 9, 1)))]),
        section('new', [live(todo('new', createdAt: DateTime.utc(2026, 9, 8)))]),
      ];

      final out = sortTodoGroups(
        groups,
        const TodoSort(key: TodoSortKey.createdDesc),
      );

      expect(groupIds(out), ['new', 'old']);
    });

    test('does not mutate the input groups or their item lists', () {
      final items = [
        live(todo('b', deadline: DateTime.utc(2026, 9, 20))),
        live(todo('a', deadline: DateTime.utc(2026, 9, 10))),
      ];
      final before = ids(items);
      final groups = [section('c', items)];

      sortTodoGroups(groups, TodoSort.initialDeadlineWholePage);

      expect(ids(items), before);
      expect(groups.single.items, same(items));
    });
  });

  // Issue #3 §5: every sort key × sort scope cell. The two groups disagree on
  // every key, so the scope is tellable apart: wholePage swaps the groups,
  // withinGroup leaves their category order alone.
  group('key × scope', () {
    List<TodoGroup> groups() => [
          section('first', [
            live(todo('a-bottom',
                deadline: DateTime.utc(2026, 9, 20),
                createdAt: DateTime.utc(2026, 9, 1),
                priority: TodoPriority.low)),
            live(todo('a-top',
                deadline: DateTime.utc(2026, 9, 10),
                createdAt: DateTime.utc(2026, 9, 9),
                priority: TodoPriority.urgent)),
          ]),
          section('second', [
            live(todo('b',
                deadline: DateTime.utc(2026, 9, 5),
                createdAt: DateTime.utc(2026, 9, 20),
                priority: TodoPriority.high)),
          ]),
        ];

    // Inside a group, a-top beats a-bottom on every key.
    const withinGroup = {
      TodoSortKey.deadlineAsc: ['a-top', 'a-bottom'],
      TodoSortKey.deadlineDesc: ['a-bottom', 'a-top'],
      TodoSortKey.priorityDesc: ['a-top', 'a-bottom'],
      TodoSortKey.createdDesc: ['a-top', 'a-bottom'],
    };

    // Across groups (wholePage), the leading group differs by key.
    const wholePage = {
      TodoSortKey.deadlineAsc: ['second', 'first'],
      TodoSortKey.deadlineDesc: ['first', 'second'],
      TodoSortKey.priorityDesc: ['first', 'second'],
      TodoSortKey.createdDesc: ['second', 'first'],
    };

    for (final key in TodoSortKey.values) {
      test('$key withinGroup sorts rows but keeps the category order', () {
        final out = sortTodoGroups(
          groups(),
          TodoSort(key: key, scope: TodoSortScope.withinGroup),
        );
        expect(groupIds(out), ['first', 'second']);
        expect(ids(out[0].items), withinGroup[key]);
      });

      test('$key wholePage orders the groups too', () {
        final out = sortTodoGroups(
          groups(),
          TodoSort(key: key, scope: TodoSortScope.wholePage),
        );
        expect(groupIds(out), wholePage[key]);
      });
    }

    test('createdDesc ranks an unacked local create (no createdAt) newest', () {
      // Server never sets createdAt on a local create still pending upload;
      // "no createdAt" therefore means "created just now".
      final out = sortTodoGroups(
        [
          section('g', [
            live(todo('server', createdAt: DateTime.utc(2026, 9, 8))),
            live(todo('unacked')),
          ]),
        ],
        const TodoSort(
            key: TodoSortKey.createdDesc, scope: TodoSortScope.withinGroup),
      );
      expect(ids(out.single.items), ['unacked', 'server']);
    });
  });
}
