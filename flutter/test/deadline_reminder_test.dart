import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/sync/expander.dart';
import 'package:flutter_test/flutter_test.dart';

/// A one-off todo's time point is worded as a reminder (that is what it is:
/// “take out the trash at 18:00”), while a project's stays a deadline. Both are
/// the same `deadlineAt` field, so the flag has to come from the todo type.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  EntitiesSnapshot snapshotWith(String type) => EntitiesSnapshot(
        rows: [
          EntityRow(
            entityType: EntityTypes.todo,
            entityId: 't-$type',
            revision: 1,
            payload: {
              'id': 't-$type',
              'title': type == 'one_off' ? '扔垃圾' : '生化大作业',
              'type': type,
              'status': 'todo',
              // 2026-09-10 18:00 local (+08) == 10:00Z
              'deadlineAt': '2026-09-10T10:00:00Z',
              'revision': 1,
            },
          ),
        ],
        pendingOps: const [],
        conflicts: const [],
      );

  List<UiEvent> deadlinesFor(String type) =>
      EventProjection(EventExpander(ut))
          .project(
            snapshotWith(type),
            startUtc: DateTime.utc(2026, 9, 7),
            endUtc: DateTime.utc(2026, 9, 14),
          )
          .events
          .where((e) => e.type == EventType.deadline)
          .toList();

  test('a one-off todo deadline is flagged as a reminder', () {
    final events = deadlinesFor('one_off');
    expect(events, hasLength(1));
    expect(events.single.title, '扔垃圾');
    expect(events.single.reminder, isTrue);
    // Same instant regardless of wording.
    expect(events.single.startUtc, DateTime.utc(2026, 9, 10, 10, 0));
  });

  test('a project todo deadline is not a reminder', () {
    final events = deadlinesFor('project');
    expect(events, hasLength(1));
    expect(events.single.reminder, isFalse);
  });
}
