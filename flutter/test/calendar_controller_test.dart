import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/state/event_projection.dart';
import 'package:course_planner/state/calendar_controller.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

/// The week view's derived data now lives in `lib/state/calendar_controller.dart`:
/// the window projection and the semester-week lookup. The mutations
/// themselves are local-first and covered by `test/local_series_service_test.dart`
/// (they need the DB-backed service graph).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  final snapshot = EntitiesSnapshot(
    rows: [
      EntityRow(
        entityType: EntityTypes.calendar,
        entityId: 'cal1',
        revision: 1,
        payload: {
          'id': 'cal1',
          'name': '2026 Autumn',
          'firstDay': '2026-09-07',
          'totalWeeks': 16,
          'revision': 1,
        },
      ),
      EntityRow(
        entityType: EntityTypes.period,
        entityId: 'p1',
        revision: 1,
        payload: {
          'id': 'p1',
          'calendarId': 'cal1',
          'periodNo': 1,
          'startLocal': '08:00',
          'endLocal': '08:45',
          'revision': 1,
        },
      ),
      EntityRow(
        entityType: EntityTypes.course,
        entityId: 'c1',
        revision: 1,
        payload: {
          'id': 'c1',
          'calendarId': 'cal1',
          'name': '高等数学',
          'location': '12-209',
          'revision': 1,
        },
      ),
      EntityRow(
        entityType: EntityTypes.courseMeeting,
        entityId: 'm1',
        revision: 1,
        payload: {
          'id': 'm1',
          'courseId': 'c1',
          'weekday': 1,
          'periodStart': 1,
          'periodEnd': 1,
          'revision': 1,
        },
      ),
    ],
    pendingOps: const [],
    conflicts: const [],
  );

  Future<ProviderContainer> boot() async {
    final container = ProviderContainer(
      overrides: [
        snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
        userTimeProvider.overrideWithValue(ut),
      ],
    );
    addTearDown(container.dispose);
    container.listen(snapshotProvider, (_, _) {});
    await pumpEventQueue();
    return container;
  }

  test('projects the shown window exactly once per window', () async {
    final container = await boot();
    final monday = tz.TZDateTime(ut.location, 2026, 9, 7);
    final nextMonday = tz.TZDateTime(ut.location, 2026, 9, 14);
    final window = localWindowToUtc(ut, monday, nextMonday);

    final events = container.read(
      calendarEventsProvider((startUtc: window.start, endUtc: window.end)),
    );

    expect(events, hasLength(1));
    expect(events.single.type, EventType.course);
    expect(events.single.title, '高等数学');

    // A week outside the semester (16 weeks from 2026-09-07) projects to
    // nothing.
    final later = container.read(calendarEventsProvider((
      startUtc: tz.TZDateTime(ut.location, 2027, 3, 1).toUtc(),
      endUtc: tz.TZDateTime(ut.location, 2027, 3, 8).toUtc(),
    )));
    expect(later, isEmpty);
  });

  test('resolves the semester week for a local Monday', () async {
    final container = await boot();

    final first = container.read(
      semesterWeekProvider(tz.TZDateTime(ut.location, 2026, 9, 7)),
    );
    expect(first, (week: 1, calendarId: 'cal1'));

    final second = container.read(
      semesterWeekProvider(tz.TZDateTime(ut.location, 2026, 9, 14)),
    );
    expect(second, (week: 2, calendarId: 'cal1'));

    final outside = container.read(
      semesterWeekProvider(tz.TZDateTime(ut.location, 2027, 3, 1)),
    );
    expect(outside, isNull);
  });

  test('a missing user timezone yields no projection and no semester week', () async {
    final container = ProviderContainer(
      overrides: [
        snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
        userTimeProvider.overrideWithValue(null),
      ],
    );
    addTearDown(container.dispose);
    container.listen(snapshotProvider, (_, _) {});
    await pumpEventQueue();

    final window = localWindowToUtc(
      ut,
      tz.TZDateTime(ut.location, 2026, 9, 7),
      tz.TZDateTime(ut.location, 2026, 9, 14),
    );
    expect(
      container.read(calendarEventsProvider((startUtc: window.start, endUtc: window.end))),
      isEmpty,
    );
    expect(
      container.read(semesterWeekProvider(tz.TZDateTime(ut.location, 2026, 9, 7))),
      isNull,
    );
  });
}
