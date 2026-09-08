import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/domain/calendar.dart';
import 'package:course_planner/domain/course.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/override.dart';
import 'package:course_planner/domain/schedule.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:course_planner/sync/expander.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;
  final expander = EventExpander(ut);

  final calendar = AcademicCalendar(
    id: 'cal1',
    name: '2026秋',
    firstDay: '2026-09-07', // Monday
    totalWeeks: 16,
    revision: 1,
  );
  final periods = [
    PeriodTemplate(id: 'p1', calendarId: 'cal1', periodNo: 1, startLocal: '08:00', endLocal: '08:45', revision: 1),
    PeriodTemplate(id: 'p2', calendarId: 'cal1', periodNo: 2, startLocal: '08:55', endLocal: '09:40', revision: 1),
    PeriodTemplate(id: 'p3', calendarId: 'cal1', periodNo: 3, startLocal: '10:00', endLocal: '10:45', revision: 1),
  ];
  final course = Course(id: 'c1', calendarId: 'cal1', name: '高等数学', revision: 1);
  final meeting = CourseMeeting(
    id: 'm1',
    courseId: 'c1',
    weekday: 1,
    periodStart: 1,
    periodEnd: 2,
    weekRule: const WeekRule([WeekSegment(start: 1, end: 16)]),
    revision: 1,
  );

  DateTime utc(String iso) => DateTime.parse(iso).toUtc();

  group('expandCourseMeetings', () {
    test('merges period 1-2 into one block Mon 08:00-09:40 local', () {
      final occs = expander.expandCourseMeetings(
        calendars: [calendar],
        periodsByCalendar: {'cal1': periods},
        coursesByCalendar: {'cal1': [course]},
        meetingsByCourse: {'c1': [meeting]},
        overrides: const [],
        startUtc: utc('2026-09-07T00:00:00Z'),
        endUtc: utc('2026-09-14T00:00:00Z'),
      );
      expect(occs, hasLength(1));
      final o = occs.single;
      expect(o.localDate, '2026-09-07');
      expect(o.startUtc, utc('2026-09-07T00:00:00Z')); // 08:00 +08
      expect(o.endUtc, utc('2026-09-07T01:40:00Z')); // 09:40 +08
      expect(o.week, 1);
    });

    test('parity + cancel/move overrides respected', () {
      final meetingOdd = CourseMeeting(
        id: 'm1',
        courseId: 'c1',
        weekday: 1,
        periodStart: 1,
        periodEnd: 1,
        weekRule: const WeekRule([WeekSegment(start: 1, end: 3, parity: WeekParity.odd)]),
        revision: 1,
      );
      final overrides = [
        OccurrenceOverride(
          id: 'o1',
          seriesType: EntityTypes.courseMeeting,
          seriesId: 'm1',
          occurrenceDateLocal: '2026-09-14',
          action: OverrideAction.cancel,
          revision: 1,
        ),
      ];
      final occs = expander.expandCourseMeetings(
        calendars: [calendar],
        periodsByCalendar: {'cal1': periods},
        coursesByCalendar: {'cal1': [course]},
        meetingsByCourse: {'c1': [meetingOdd]},
        overrides: overrides,
        startUtc: utc('2026-09-07T00:00:00Z'),
        endUtc: utc('2026-09-22T00:00:00Z'),
      );
      // weeks 1 (9/7) and 3 (9/21); week 2 (9/14) cancelled by override.
      expect(occs.map((o) => o.localDate).toList(), ['2026-09-07', '2026-09-21']);
    });

    test('MOVE override replaces the window and updates metadata', () {
      final overrides = [
        OccurrenceOverride(
          id: 'o2',
          seriesType: EntityTypes.courseMeeting,
          seriesId: 'm1',
          occurrenceDateLocal: '2026-09-14',
          action: OverrideAction.move,
          replacementStartAt: utc('2026-09-14T02:00:00Z'), // 10:00 local
          replacementEndAt: utc('2026-09-14T03:00:00Z'), // 11:00 local
          metadata: const {'title': '高数调课'},
          revision: 1,
        ),
      ];
      final occs = expander.expandCourseMeetings(
        calendars: [calendar],
        periodsByCalendar: {'cal1': periods},
        coursesByCalendar: {'cal1': [course]},
        meetingsByCourse: {'c1': [meeting]},
        overrides: overrides,
        startUtc: utc('2026-09-14T00:00:00Z'),
        endUtc: utc('2026-09-15T00:00:00Z'),
      );
      expect(occs, hasLength(1));
      expect(occs.single.startUtc, utc('2026-09-14T02:00:00Z'));
      expect(occs.single.title, '高数调课');
      expect(occs.single.overridden, isTrue);
    });
  });

  group('expandRecurringSchedules', () {
    test('weekly schedule on weekdays', () {
      final rs = RecurringSchedule(
        id: 'r1',
        title: '英语角',
        rule: const ScheduleRule(
          kind: ScheduleRuleKind.weekly,
          startLocal: '09:00',
          endLocal: '10:00',
          weekdays: [2, 4],
          dateStart: '2026-09-01',
          dateEnd: '2026-09-30',
        ),
        revision: 1,
      );
      final occs = expander.expandRecurringSchedules(
        schedules: [rs],
        calendars: const [],
        periodsByCalendar: const {},
        overrides: const [],
        startUtc: utc('2026-09-07T00:00:00Z'),
        endUtc: utc('2026-09-15T00:00:00Z'),
      );
      // Tue 9/8 & Thu 9/10 within window.
      expect(occs.map((o) => o.localDate).toList(), ['2026-09-08', '2026-09-10']);
      expect(occs.first.startUtc, utc('2026-09-08T01:00:00Z'));
    });

    test('by_academic_week uses calendar period times', () {
      final rs = RecurringSchedule(
        id: 'r2',
        title: '班会',
        rule: ScheduleRule(
          kind: ScheduleRuleKind.byAcademicWeek,
          calendarId: 'cal1',
          weekdays: [5],
          periodStart: 3,
          periodEnd: 3,
          weekRule: const WeekRule([WeekSegment(start: 1, end: 4)]),
        ),
        revision: 1,
      );
      final occs = expander.expandRecurringSchedules(
        schedules: [rs],
        calendars: [calendar],
        periodsByCalendar: {'cal1': periods},
        overrides: const [],
        startUtc: utc('2026-09-07T00:00:00Z'),
        endUtc: utc('2026-10-05T00:00:00Z'),
      );
      // Fridays of weeks 1-4: 9/11, 9/18, 9/25, 10/2.
      expect(occs, hasLength(4));
      expect(occs.first.localDate, '2026-09-11');
      expect(occs.first.startUtc, utc('2026-09-11T02:00:00Z')); // 10:00 +08
    });
  });
}
