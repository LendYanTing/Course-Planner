import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/week_page_harness.dart';

/// The 时间轴 week view shows exactly seven local days. An event belongs to it
/// only when its local start date is one of them — the rule the 课表 (grid) mode
/// already applies. Deriving the column from `localStart.weekday - 1` instead
/// put any stray event in the matching weekday column, so a block from another
/// week appeared to be scheduled this week (and dragging or deleting it then hit
/// the other week's block).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('timeline shows this week\'s blocks and no other week\'s',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final today = ut.localFromUtc(DateTime.now().toUtc());
    final thisMonday = ut.addLocalDays(
      ut.fromLocalParts(today.year, today.month, today.day, 0, 0),
      -(ut.isoWeekday(today) - 1),
    );
    final lastMonday = ut.addLocalDays(thisMonday, -7);
    final lastSunday = ut.addLocalDays(lastMonday, -1);

    DateTime localDay(DateTime monday, int hour) =>
        ut.fromLocalParts(monday.year, monday.month, monday.day, hour, 0).toUtc();

    final snapshot = EntitiesSnapshot(
      rows: [
        _todo('t-this-week', '本周任务'),
        _todo('t-last-week', '上周任务'),
        _todo('t-spanning', '跨周任务'),
        _block('b-this-week', 't-this-week',
            localDay(thisMonday, 8), localDay(thisMonday, 9)),
        // Same weekday, previous week.
        _block('b-last-week', 't-last-week',
            localDay(lastMonday, 8), localDay(lastMonday, 9)),
        // Starts on the previous week's last day but runs into this week, so it
        // overlaps the rendered window and reaches the timeline.
        _block('b-spanning', 't-spanning',
            localDay(lastSunday, 23), localDay(thisMonday, 1)),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    await pumpWeekPage(tester, snapshot);

    expect(tester.takeException(), isNull);
    expect(find.text('本周任务'), findsOneWidget,
        reason: 'a block in the shown week must render');
    expect(find.text('上周任务'), findsNothing,
        reason: 'a block from another week must not render in this week');
    expect(find.text('跨周任务'), findsNothing,
        reason: 'an event starting outside the shown days must not be drawn '
            'in the matching weekday column either');
  });
}

EntityRow _todo(String id, String title) => EntityRow(
      entityType: EntityTypes.todo,
      entityId: id,
      revision: 1,
      payload: {
        'id': id,
        'title': title,
        'type': 'one_off',
        'status': 'todo',
        'revision': 1,
      },
    );

EntityRow _block(String id, String todoId, DateTime start, DateTime end) =>
    EntityRow(
      entityType: EntityTypes.todoBlock,
      entityId: id,
      revision: 1,
      payload: {
        'id': id,
        'todoId': todoId,
        'startAt': start.toIso8601String(),
        'endAt': end.toIso8601String(),
        'status': 'scheduled',
        'revision': 1,
      },
    );
