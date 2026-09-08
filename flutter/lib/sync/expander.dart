import 'package:timezone/timezone.dart' as tz;

import '../core/time/user_time.dart';
import '../domain/calendar.dart';
import '../domain/course.dart';
import '../domain/entities.dart';
import '../domain/override.dart';
import '../domain/schedule.dart';

/// One materialised occurrence of a course meeting or recurring schedule.
class Occurrence {
  const Occurrence({
    required this.sourceType,
    required this.sourceId,
    required this.courseId,
    required this.localDate,
    required this.startUtc,
    required this.endUtc,
    this.title,
    this.color,
    this.teacher,
    this.location,
    this.notes,
    this.periodStart = 0,
    this.periodEnd = 0,
    this.week = 0,
    this.overridden = false,
    this.cancelled = false,
  });

  final String sourceType; // EntityTypes.courseMeeting | recurringSchedule
  final String sourceId;
  final String? courseId;
  final String localDate; // YYYY-MM-DD
  final DateTime startUtc;
  final DateTime endUtc;
  final String? title;
  final String? color;
  final String? teacher;
  final String? location;
  final String? notes;
  final int periodStart;
  final int periodEnd;
  final int week;
  final bool overridden;
  final bool cancelled;
}

/// Resolved period minutes per calendar: periodNo -> (startMinute, endMinute).
typedef PeriodMinutes = Map<int, ({int start, int end})>;

/// Local expansion of course meetings + recurring schedules + todo blocks +
/// deadlines into [Occurrence]/event candidates, mirroring the server
/// projection (server/internal/event). Pure functions — no I/O.
///
/// All date arithmetic is in the fixed user timezone.
class EventExpander {
  EventExpander(this.userTime);

  final UserTime userTime;

  /// Week number (1-based) of [localDate] within the calendar starting at
  /// [firstDay] (assumed to be a Monday).
  int weekOf(String firstDay, String localDate) {
    final fd = userTime.parseLocalDate(firstDay);
    final ld = userTime.parseLocalDate(localDate);
    if (fd == null || ld == null) return 0;
    final diff = ld.difference(fd).inDays;
    if (diff < 0) return 0;
    return diff ~/ 7 + 1;
  }

  /// Local date string of (week, isoWeekday) in a calendar that starts at
  /// [firstDay] (Monday of week 1).
  String? localDateOfOccurrence(String firstDay, int week, int weekday) {
    final fd = userTime.parseLocalDate(firstDay);
    if (fd == null) return null;
    final day = tz.TZDateTime(userTime.location, fd.year, fd.month, fd.day + (week - 1) * 7 + (weekday - 1));
    return userTime.localDateString(day);
  }

  /// Builds period minute tables from period templates of all calendars.
  PeriodMinutes periodMinutesFor(List<PeriodTemplate> periods) {
    final map = <int, ({int start, int end})>{};
    for (final p in periods) {
      map[p.periodNo] = (start: p.startMinute, end: p.endMinute);
    }
    return map;
  }

  /// Materialises course occurrences overlapping [startUtc, endUtc).
  List<Occurrence> expandCourseMeetings({
    required List<AcademicCalendar> calendars,
    required Map<String, List<PeriodTemplate>> periodsByCalendar,
    required Map<String, List<Course>> coursesByCalendar,
    required Map<String, List<CourseMeeting>> meetingsByCourse,
    required List<OccurrenceOverride> overrides,
    required DateTime startUtc,
    required DateTime endUtc,
  }) {
    final out = <Occurrence>[];
    final overrideIndex = <String, List<OccurrenceOverride>>{};
    for (final ov in overrides.where((o) => o.seriesType == SeriesTypes.courseMeeting)) {
      overrideIndex.putIfAbsent(ov.seriesId, () => []).add(ov);
    }
    for (final cal in calendars) {
      final periods = periodsByCalendar[cal.id] ?? const [];
      final pm = periodMinutesFor(periods);
      for (final course in coursesByCalendar[cal.id] ?? const <Course>[]) {
        for (final meeting in meetingsByCourse[course.id] ?? const <CourseMeeting>[]) {
          final occs = _expandOneMeeting(
            meeting: meeting,
            course: course,
            calendar: cal,
            periodMinutes: pm,
            overrides: overrideIndex[meeting.id] ?? const [],
            startUtc: startUtc,
            endUtc: endUtc,
          );
          out.addAll(occs);
        }
      }
    }
    return out;
  }

  List<Occurrence> _expandOneMeeting({
    required CourseMeeting meeting,
    required Course course,
    required AcademicCalendar calendar,
    required PeriodMinutes periodMinutes,
    required List<OccurrenceOverride> overrides,
    required DateTime startUtc,
    required DateTime endUtc,
  }) {
    final overByDate = <String, OccurrenceOverride>{};
    for (final o in overrides) {
      overByDate[o.occurrenceDateLocal] = o;
    }
    final weeks = meeting.weekRule.isEmpty
        ? List.generate(calendar.totalWeeks, (i) => i + 1)
        : meeting.weekRule.weeks(calendar.totalWeeks);
    final out = <Occurrence>[];
    for (final week in weeks) {
      final dateStr = localDateOfOccurrence(calendar.firstDay, week, meeting.weekday);
      if (dateStr == null) continue;
      final pStart = periodMinutes[meeting.periodStart];
      final pEnd = periodMinutes[meeting.periodEnd];
      if (pStart == null || pEnd == null) continue;

      var title = course.name;
      var color = course.color;
      var teacher = course.teacher;
      var location = course.location;
      var notes = course.notes;
      var startMin = pStart.start;
      var endMin = pEnd.end;
      var overridden = false;
      var cancelled = false;

      final ov = overByDate[dateStr];
      DateTime? movedStart;
      DateTime? movedEnd;
      if (ov != null) {
        overridden = true;
        final md = ov.metadata;
        final mt = md['title'];
        if (mt is String) title = mt;
        final mc = md['color'];
        if (mc is String) color = mc;
        final tc = md['teacher'];
        if (tc is String) teacher = tc;
        final lc = md['location'];
        if (lc is String) location = lc;
        final nt = md['notes'];
        if (nt is String) notes = nt;
        if (ov.action == OverrideAction.cancel) {
          cancelled = true;
        } else if (ov.action == OverrideAction.move) {
          movedStart = ov.replacementStartAt;
          movedEnd = ov.replacementEndAt;
        }
      }
      if (cancelled) continue;

      if (movedStart != null && movedEnd != null) {
        final occ = _makeOccurrence(
          sourceType: EntityTypes.courseMeeting,
          sourceId: meeting.id,
          courseId: course.id,
          dateStr: dateStr,
          week: week,
          startUtc: movedStart,
          endUtc: movedEnd,
          title: title,
          color: color,
          teacher: teacher,
          location: location,
          notes: notes,
          periodStart: meeting.periodStart,
          periodEnd: meeting.periodEnd,
          overridden: true,
        );
        if (_intersects(occ, startUtc, endUtc)) out.add(occ);
        continue;
      }

      final startLocal = _localFromMinutes(dateStr, startMin);
      final endLocal = _localFromMinutes(dateStr, endMin);
      final occ = Occurrence(
        sourceType: EntityTypes.courseMeeting,
        sourceId: meeting.id,
        courseId: course.id,
        localDate: dateStr,
        startUtc: startLocal.toUtc(),
        endUtc: endLocal.toUtc(),
        title: title,
        color: color,
        teacher: teacher,
        location: location,
        notes: notes,
        periodStart: meeting.periodStart,
        periodEnd: meeting.periodEnd,
        week: week,
        overridden: overridden,
      );
      if (_intersects(occ, startUtc, endUtc)) out.add(occ);
    }
    return out;
  }

  /// Materialises recurring schedule occurrences overlapping [start, end).
  List<Occurrence> expandRecurringSchedules({
    required List<RecurringSchedule> schedules,
    required List<AcademicCalendar> calendars,
    required Map<String, List<PeriodTemplate>> periodsByCalendar,
    required List<OccurrenceOverride> overrides,
    required DateTime startUtc,
    required DateTime endUtc,
  }) {
    final out = <Occurrence>[];
    final calById = {for (final c in calendars) c.id: c};
    final overrideIndex = <String, List<OccurrenceOverride>>{};
    for (final ov in overrides.where((o) => o.seriesType == SeriesTypes.recurringSchedule)) {
      overrideIndex.putIfAbsent(ov.seriesId, () => []).add(ov);
    }
    for (final rs in schedules) {
      out.addAll(_expandOneSchedule(
        rs,
        calById,
        periodsByCalendar,
        overrideIndex[rs.id] ?? const [],
        startUtc,
        endUtc,
      ));
    }
    return out;
  }

  List<Occurrence> _expandOneSchedule(
    RecurringSchedule rs,
    Map<String, AcademicCalendar> calById,
    Map<String, List<PeriodTemplate>> periodsByCalendar,
    List<OccurrenceOverride> overrides,
    DateTime startUtc,
    DateTime endUtc,
  ) {
    final overByDate = <String, OccurrenceOverride>{};
    for (final o in overrides) {
      overByDate[o.occurrenceDateLocal] = o;
    }
    final rule = rs.rule;
    final out = <Occurrence>[];
    final dateBounds = <String, ({int startMin, int endMin, int week})>{};

    switch (rule.kind) {
      case ScheduleRuleKind.daily:
      case ScheduleRuleKind.weekly:
        final dateStart = rule.dateStart;
        final dateEnd = rule.dateEnd;
        final startLocal = rule.startLocal;
        final endLocal = rule.endLocal;
        if (dateStart == null || dateEnd == null || startLocal == null || endLocal == null) {
          return out;
        }
        final dStart = userTime.parseLocalDate(dateStart);
        final dEnd = userTime.parseLocalDate(dateEnd);
        if (dStart == null || dEnd == null) return out;
        final sm = _hhmmMinutes(startLocal);
        final em = _hhmmMinutes(endLocal);
        final endInclusive = tz.TZDateTime(userTime.location, dEnd.year, dEnd.month, dEnd.day + 1);
        for (final d in userTime.localDatesBetween(dStart, endInclusive)) {
          final dateStr = userTime.localDateString(d);
          if (rule.kind == ScheduleRuleKind.weekly && !rule.weekdays.contains(userTime.isoWeekday(d))) {
            continue;
          }
          dateBounds[dateStr] = (startMin: sm, endMin: em, week: 0);
        }
        break;
      case ScheduleRuleKind.byAcademicWeek:
        final calId = rule.calendarId;
        final cal = calId == null ? null : calById[calId];
        if (cal == null) return out;
        final weeks = rule.weekRule == null || rule.weekRule!.isEmpty
            ? List.generate(cal.totalWeeks, (i) => i + 1)
            : rule.weekRule!.weeks(cal.totalWeeks);
        final usePeriods = rule.periodStart > 0;
        final pm = periodMinutesFor(periodsByCalendar[cal.id] ?? const []);
        for (final weekday in rule.weekdays) {
          for (final week in weeks) {
            final dateStr = localDateOfOccurrence(cal.firstDay, week, weekday);
            if (dateStr == null) continue;
            if (usePeriods) {
              final ps = pm[rule.periodStart];
              final pe = pm[rule.periodEnd];
              if (ps == null || pe == null) continue;
              dateBounds[dateStr] = (startMin: ps.start, endMin: pe.end, week: week);
            } else {
              final sm = _hhmm(rule.startLocal);
              final em = _hhmm(rule.endLocal);
              if (sm == null || em == null) continue;
              dateBounds[dateStr] = (startMin: sm, endMin: em, week: week);
            }
          }
        }
    }

    for (final entry in dateBounds.entries) {
      final dateStr = entry.key;
      final bounds = entry.value;

      var title = rs.title;
      var color = rs.color;
      var notes = rs.notes;
      var startMin = bounds.startMin;
      var endMin = bounds.endMin;
      var week = bounds.week;
      var overridden = false;
      var cancelled = false;

      final ov = overByDate[dateStr];
      DateTime? movedStart;
      DateTime? movedEnd;
      if (ov != null) {
        overridden = true;
        final md = ov.metadata;
        final mt = md['title'];
        if (mt is String) title = mt;
        final mc = md['color'];
        if (mc is String) color = mc;
        final nt = md['notes'];
        if (nt is String) notes = nt;
        if (ov.action == OverrideAction.cancel) {
          cancelled = true;
        } else if (ov.action == OverrideAction.move) {
          movedStart = ov.replacementStartAt;
          movedEnd = ov.replacementEndAt;
        }
      }
      if (cancelled) continue;

      if (movedStart != null && movedEnd != null) {
        final occ = _makeOccurrence(
          sourceType: EntityTypes.recurringSchedule,
          sourceId: rs.id,
          courseId: null,
          dateStr: dateStr,
          week: week,
          startUtc: movedStart,
          endUtc: movedEnd,
          title: title,
          color: color,
          notes: notes,
          overridden: true,
        );
        if (_intersects(occ, startUtc, endUtc)) out.add(occ);
        continue;
      }

      final startLocal = _localFromMinutes(dateStr, startMin);
      final endLocal = _localFromMinutes(dateStr, endMin);
      final occ = Occurrence(
        sourceType: EntityTypes.recurringSchedule,
        sourceId: rs.id,
        courseId: null,
        localDate: dateStr,
        startUtc: startLocal.toUtc(),
        endUtc: endLocal.toUtc(),
        title: title,
        color: color,
        notes: notes,
        periodStart: rule.periodStart,
        periodEnd: rule.periodEnd,
        week: week,
        overridden: overridden,
      );
      if (_intersects(occ, startUtc, endUtc)) out.add(occ);
    }
    return out;
  }

  Occurrence _makeOccurrence({
    required String sourceType,
    required String sourceId,
    required String? courseId,
    required String dateStr,
    required int week,
    required DateTime startUtc,
    required DateTime endUtc,
    required String? title,
    required String? color,
    String? teacher,
    String? location,
    String? notes,
    int periodStart = 0,
    int periodEnd = 0,
    required bool overridden,
  }) =>
      Occurrence(
        sourceType: sourceType,
        sourceId: sourceId,
        courseId: courseId,
        localDate: dateStr,
        startUtc: startUtc,
        endUtc: endUtc,
        title: title,
        color: color,
        teacher: teacher,
        location: location,
        notes: notes,
        periodStart: periodStart,
        periodEnd: periodEnd,
        week: week,
        overridden: overridden,
      );

  bool _intersects(Occurrence occ, DateTime startUtc, DateTime endUtc) =>
      occ.endUtc.isAfter(startUtc) && occ.startUtc.isBefore(endUtc);

  /// Local wall-clock instant for [dateStr] at [minuteOfDay].
  tz.TZDateTime _localFromMinutes(String dateStr, int minuteOfDay) {
    final local = userTime.parseLocalDate(dateStr)!;
    return tz.TZDateTime(
      userTime.location,
      local.year,
      local.month,
      local.day,
      minuteOfDay ~/ 60,
      minuteOfDay % 60,
    );
  }

  int? _hhmm(String? s) {
    if (s == null) return null;
    final p = s.split(':');
    if (p.length != 2) return null;
    final h = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    if (h == null || m == null) return null;
    return h * 60 + m;
  }

  int _hhmmMinutes(String s) {
    final p = s.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }
}
