import 'package:course_planner/core/error/api_exception.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/local_series_service.dart';
import 'package:course_planner/domain/override.dart';
import 'package:course_planner/domain/schedule.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:course_planner/state/event_projection.dart';
import 'package:course_planner/sync/expander.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'helpers/host_sqlite.dart';

/// Local series editing (docs/plans/v1/phase-1-local-first.md Step 2): every
/// move / cancel / split is written through [EntityRepo] and immediately
/// visible to [EventProjection], with no server call involved.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  late AppDatabase db;
  late SyncStore store;
  late EntityRepo repo;
  late LocalSeriesService service;

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  // 2026-09-07 is a Monday; the semester runs 16 weeks.
  const firstDay = '2026-09-07';

  late String calendarId;
  late String courseId;
  late String meetingId;
  late String scheduleId;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
    repo = EntityRepo(db, store);
    service = LocalSeriesService(repo: repo, userTime: ut);

    calendarId = await repo.localCreate(
      entityType: EntityTypes.calendar,
      snapshot: {'name': '2026 Autumn', 'firstDay': firstDay, 'totalWeeks': 16},
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 1,
        'startLocal': '08:00',
        'endLocal': '08:45',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 2,
        'startLocal': '08:55',
        'endLocal': '09:40',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 3,
        'startLocal': '10:00',
        'endLocal': '10:45',
      },
    );
    await repo.localCreate(
      entityType: EntityTypes.period,
      snapshot: {
        'calendarId': calendarId,
        'periodNo': 4,
        'startLocal': '10:55',
        'endLocal': '11:40',
      },
    );
    courseId = await repo.localCreate(
      entityType: EntityTypes.course,
      snapshot: {
        'calendarId': calendarId,
        'name': '高等数学',
        'location': '12-209',
      },
    );
    meetingId = await repo.localCreate(
      entityType: EntityTypes.courseMeeting,
      snapshot: {
        'courseId': courseId,
        'weekday': 1,
        'periodStart': 1,
        'periodEnd': 2,
        'weekRule': const WeekRule([WeekSegment(start: 1, end: 16)]).toJson(),
      },
    );
    scheduleId = await repo.localCreate(
      entityType: EntityTypes.recurringSchedule,
      snapshot: {
        'title': '班会',
        'rule': ScheduleRule(
          kind: ScheduleRuleKind.byAcademicWeek,
          calendarId: calendarId,
          weekdays: const [1],
          periodStart: 1,
          periodEnd: 2,
          weekRule: const WeekRule([WeekSegment(start: 1, end: 16)]),
        ).toJson(),
      },
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<EntitiesSnapshot> snap() async => EntitiesSnapshot(
    rows: await store.allEntities(),
    pendingOps: await store.pendingOps(),
    conflicts: await store.conflicts(),
  );

  /// Projects the local week [week] (1-based) and returns the events of
  /// [type] only.
  List<UiEvent> projectWeek(
    EntitiesSnapshot snapshot,
    int week, {
    EventType type = EventType.course,
  }) {
    final monday = tz.TZDateTime(ut.location, 2026, 9, 7 + (week - 1) * 7);
    final nextMonday = tz.TZDateTime(ut.location, 2026, 9, 14 + (week - 1) * 7);
    final window = localWindowToUtc(ut, monday, nextMonday);
    return EventProjection(EventExpander(ut))
        .project(snapshot, startUtc: window.start, endUtc: window.end)
        .events
        .where((e) => e.type == type)
        .toList();
  }

  /// Matches an instant regardless of `DateTime` implementation
  /// (`TZDateTime` vs plain UTC `DateTime`).
  Matcher atUtc(int year, int month, int day, [int hour = 0, int minute = 0]) =>
      predicate<DateTime>(
        (dt) =>
            dt.isAtSameMomentAs(DateTime.utc(year, month, day, hour, minute)),
        'is $year-$month-$day $hour:$minute UTC',
      );

  test('moveOccurrence moves only the projected week', () async {
    // Week 1 Monday periods 1-2 = 08:00-09:40 local = 00:00-01:40Z.
    final original = DateTime.utc(2026, 9, 7, 0, 0);
    expect(
      projectWeek(await snap(), 1).single.startUtc,
      atUtc(2026, 9, 7),
      reason: 'baseline: Monday 08:00 local',
    );

    // Move to week 1 Tuesday periods 3-4 = 10:00-11:40 local = 02:00-03:40Z.
    await service.moveOccurrence(
      snapshot: await snap(),
      seriesType: SeriesTypes.courseMeeting,
      seriesId: meetingId,
      originalStartUtc: original,
      newStartUtc: DateTime.utc(2026, 9, 8, 2, 0),
      newEndUtc: DateTime.utc(2026, 9, 8, 3, 40),
    );

    final after = await snap();
    final week1 = projectWeek(after, 1).single;
    expect(week1.startUtc, atUtc(2026, 9, 8, 2, 0));
    expect(week1.endUtc, atUtc(2026, 9, 8, 3, 40));

    // Week 2 is untouched: still Monday 08:00-09:40 local.
    final week2 = projectWeek(after, 2).single;
    expect(week2.startUtc, atUtc(2026, 9, 14));
    expect(week2.endUtc, atUtc(2026, 9, 14, 1, 40));

    final overrides = await store.entitiesOfType(EntityTypes.override);
    expect(overrides, hasLength(1));
    expect(overrides.single.payload['seriesType'], SeriesTypes.courseMeeting);
    expect(overrides.single.payload['seriesId'], meetingId);
    expect(overrides.single.payload['occurrenceDateLocal'], '2026-09-07');
    expect(overrides.single.payload['action'], OverrideAction.move.wire);
  });

  test('moving the same occurrence twice updates one override', () async {
    await service.moveOccurrence(
      snapshot: await snap(),
      seriesType: SeriesTypes.courseMeeting,
      seriesId: meetingId,
      originalStartUtc: DateTime.utc(2026, 9, 7, 0, 0),
      newStartUtc: DateTime.utc(2026, 9, 8, 2, 0),
      newEndUtc: DateTime.utc(2026, 9, 8, 3, 40),
    );

    // The second drag starts from the moved occurrence, so the controller
    // passes the override's replacementStartAt as originalStartUtc.
    await service.moveOccurrence(
      snapshot: await snap(),
      seriesType: SeriesTypes.courseMeeting,
      seriesId: meetingId,
      originalStartUtc: DateTime.utc(2026, 9, 8, 2, 0),
      newStartUtc: DateTime.utc(2026, 9, 9, 2, 0),
      newEndUtc: DateTime.utc(2026, 9, 9, 3, 40),
    );

    final after = await snap();
    final overrides = await store.entitiesOfType(EntityTypes.override);
    expect(overrides, hasLength(1), reason: 'update in place, not a new row');

    final live = liveOverrides(after).map((e) => e.value).toList();
    expect(live, hasLength(1));
    expect(live.single.occurrenceDateLocal, '2026-09-07');
    expect(live.single.replacementStartAt, atUtc(2026, 9, 9, 2, 0));

    final week1 = projectWeek(after, 1).single;
    expect(week1.startUtc, atUtc(2026, 9, 9, 2, 0));
  });

  test('cancelOccurrence hides only that week', () async {
    await service.cancelOccurrence(
      snapshot: await snap(),
      seriesType: SeriesTypes.courseMeeting,
      seriesId: meetingId,
      originalStartUtc: DateTime.utc(2026, 9, 7, 0, 0),
    );

    final after = await snap();
    expect(projectWeek(after, 1), isEmpty);
    expect(projectWeek(after, 2), hasLength(1));

    final overrides = await store.entitiesOfType(EntityTypes.override);
    expect(overrides, hasLength(1));
    expect(overrides.single.payload['action'], OverrideAction.cancel.wire);
  });

  test('THIS_AND_FUTURE splits a course meeting at the given week', () async {
    // Week 5 Monday is 2026-10-05.
    await service.applySeriesEdit(
      snapshot: await snap(),
      seriesType: SeriesTypes.courseMeeting,
      seriesId: meetingId,
      scope: SeriesScopes.thisAndFuture,
      occurrenceDateLocal: '2026-10-05',
      operationType: SeriesOperations.move,
      newWeekday: 3,
      newPeriodStart: 3,
      newPeriodEnd: 4,
    );

    final after = await snap();

    // Week 4 still uses the original Monday period 1-2.
    final week4 = projectWeek(after, 4).single;
    expect(week4.startUtc, atUtc(2026, 9, 28));

    // Week 5 onwards is Wednesday period 3-4 (10:00-11:40 local = 02:00Z).
    final week5 = projectWeek(after, 5).single;
    expect(week5.startUtc, atUtc(2026, 10, 7, 2, 0));
    expect(week5.endUtc, atUtc(2026, 10, 7, 3, 40));

    // The series is now head 1-4 (Monday 1-2) + tail 5-16 (Wednesday 3-4).
    final meetings = liveMeetings(
      after,
      courseId: courseId,
    ).map((e) => e.value).toList();
    expect(meetings, hasLength(2));
    final head = meetings.firstWhere((m) => m.weekRule.weeks(16).contains(1));
    final tail = meetings.firstWhere((m) => m.weekRule.weeks(16).contains(5));
    expect(head.weekRule.weeks(16), [1, 2, 3, 4]);
    expect(head.weekday, 1);
    expect(head.periodStart, 1);
    expect(tail.weekRule.weeks(16), [
      5,
      6,
      7,
      8,
      9,
      10,
      11,
      12,
      13,
      14,
      15,
      16,
    ]);
    expect(tail.weekday, 3);
    expect(tail.periodStart, 3);
    expect(tail.periodEnd, 4);
    expect(tail.courseId, courseId);
  });

  test(
    'THIS_AND_FUTURE splits a recurring schedule at the given week',
    () async {
      await service.applySeriesEdit(
        snapshot: await snap(),
        seriesType: SeriesTypes.recurringSchedule,
        seriesId: scheduleId,
        scope: SeriesScopes.thisAndFuture,
        occurrenceDateLocal: '2026-10-05',
        operationType: SeriesOperations.move,
        newWeekday: 5,
        newPeriodStart: 3,
        newPeriodEnd: 4,
      );

      final after = await snap();

      final week4 = projectWeek(
        after,
        4,
        type: EventType.recurringSchedule,
      ).single;
      expect(week4.startUtc, atUtc(2026, 9, 28));

      final week5 = projectWeek(
        after,
        5,
        type: EventType.recurringSchedule,
      ).single;
      expect(week5.startUtc, atUtc(2026, 10, 9, 2, 0));

      final schedules = liveSchedules(after).map((e) => e.value).toList();
      expect(schedules, hasLength(2));
      final tail = schedules.firstWhere(
        (s) => (s.rule.weekRule?.weeks(16) ?? const []).contains(5),
      );
      expect(tail.rule.weekdays, [5]);
      expect(tail.rule.periodStart, 3);
      expect(tail.rule.periodEnd, 4);
    },
  );

  test('a move across local midnight is rejected', () async {
    // 23:30 -> 00:30 Asia/Shanghai crosses the natural day even though the
    // UTC instants are both on 2026-09-07.
    await expectLater(
      service.moveOccurrence(
        snapshot: await snap(),
        seriesType: SeriesTypes.courseMeeting,
        seriesId: meetingId,
        originalStartUtc: DateTime.utc(2026, 9, 7, 0, 0),
        newStartUtc: DateTime.utc(2026, 9, 7, 15, 30),
        newEndUtc: DateTime.utc(2026, 9, 7, 16, 30),
      ),
      throwsA(
        isA<ApiException>()
            .having((e) => e.code, 'code', ApiErrorCodes.crossMidnight)
            .having((e) => e.message, 'message', '单个日程不能跨午夜'),
      ),
    );
    expect(await store.entitiesOfType(EntityTypes.override), isEmpty);
  });

  group('WeekRule split helpers', () {
    test('restrictBefore / restrictFrom keep parity segments', () {
      final rule = WeekRule([
        const WeekSegment(start: 1, end: 5),
        const WeekSegment(start: 7, end: 11, parity: WeekParity.odd),
        const WeekSegment(start: 12, end: 16, parity: WeekParity.even),
      ]);

      final head = rule.restrictBefore(10)!;
      expect(head.describe(), '1-5、7-9单');
      expect(head.weeks(16), [1, 2, 3, 4, 5, 7, 9]);

      final tail = rule.restrictFrom(10)!;
      expect(tail.describe(), '10-11单、12-16双');
      expect(tail.weeks(16), [11, 12, 14, 16]);
    });

    test('an empty (every-week) rule clips against full bounds', () {
      expect(const WeekRule().restrictBefore(1), isNull);
      expect(const WeekRule().restrictBefore(5)!.weeks(16), [1, 2, 3, 4]);
      expect(const WeekRule().restrictFrom(5)!.weeks(16).first, 5);
    });

    test('a clipping without matching parity yields null', () {
      final evenFromTwo = WeekRule([
        const WeekSegment(start: 2, end: 8, parity: WeekParity.even),
      ]);
      // Clip at 3 leaves only week 2 (even) — kept.
      expect(evenFromTwo.restrictBefore(3)!.weeks(8), [2]);
      // Odd start with even parity: week 3..3 contains no even week.
      final oddStart = WeekRule([
        const WeekSegment(start: 3, end: 8, parity: WeekParity.even),
      ]);
      expect(oddStart.restrictBefore(4), isNull);
    });
  });
}
