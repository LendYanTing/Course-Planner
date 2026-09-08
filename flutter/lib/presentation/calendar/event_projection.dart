import 'package:timezone/timezone.dart' as tz;

import '../../../core/time/user_time.dart';
import '../../../data/local/entities_snapshot.dart';
import '../../../data/local/view_models.dart';
import '../../../domain/calendar.dart';
import '../../../domain/calendar_event.dart';
import '../../../domain/course.dart';
import '../../../domain/entities.dart';
import '../../../sync/expander.dart';

/// A UI-ready event placed on week/month grids, produced from the local
/// mirror (docs/domain-model.md §14). No server call involved — the whole
/// range is projected locally so offline views behave identically.
class UiEvent {
  const UiEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.startUtc,
    required this.endUtc,
    required this.sourceType,
    required this.sourceId,
    required this.conflict,
    this.color,
    this.location,
    this.teacher,
    this.note,
    this.pending = false,
  });

  final String id;
  final EventType type;
  final String title;
  final DateTime startUtc;
  final DateTime endUtc;
  final String sourceType;
  final String sourceId;
  final ConflictState conflict;
  final String? color;
  final String? location;
  final String? teacher;
  final String? note;
  final bool pending;
}

class EventProjectionResult {
  const EventProjectionResult({required this.events, required this.allDayEvents});
  final List<UiEvent> events;
  final List<UiEvent> allDayEvents;
}

/// Projection result of the whole week/month window. The caller requests a
/// UTC [start, end) covering exactly the local dates it renders.
class EventProjection {
  const EventProjection(this.expander);

  final EventExpander expander;

  EventProjectionResult project(
    EntitiesSnapshot snapshot, {
    required DateTime startUtc,
    required DateTime endUtc,
    bool includeDeadlines = true,
  }) {
    final calendars = liveCalendars(snapshot).map((e) => e.value).toList();
    final periods = livePeriods(snapshot);
    final periodsByCalendar = <String, List<PeriodTemplate>>{};
    for (final p in periods) {
      periodsByCalendar.putIfAbsent(p.value.calendarId, () => []).add(p.value);
    }
    final courses = liveCourses(snapshot).map((e) => e.value).toList();
    final coursesByCalendar = <String, List<Course>>{};
    for (final c in courses) {
      coursesByCalendar.putIfAbsent(c.calendarId, () => []).add(c);
    }
    final meetings = liveMeetings(snapshot).map((e) => e.value).toList();
    final meetingsByCourse = <String, List<CourseMeeting>>{};
    for (final m in meetings) {
      meetingsByCourse.putIfAbsent(m.courseId, () => []).add(m);
    }
    final schedules = liveSchedules(snapshot).map((e) => e.value).toList();
    final overrides = liveOverrides(snapshot).map((e) => e.value).toList();
    final blocks = liveBlocks(snapshot).map((e) => e.value).toList();
    final todos = liveTodos(snapshot).map((e) => e.value).toList();

    final courseOccs = expander.expandCourseMeetings(
      calendars: calendars,
      periodsByCalendar: periodsByCalendar,
      coursesByCalendar: coursesByCalendar,
      meetingsByCourse: meetingsByCourse,
      overrides: overrides,
      startUtc: startUtc,
      endUtc: endUtc,
    );
    final scheduleOccs = expander.expandRecurringSchedules(
      schedules: schedules,
      calendars: calendars,
      periodsByCalendar: periodsByCalendar,
      overrides: overrides,
      startUtc: startUtc,
      endUtc: endUtc,
    );

    final events = <UiEvent>[];

    // Courses with hard-conflict detection (identical series never clashes).
    for (var i = 0; i < courseOccs.length; i++) {
      final occ = courseOccs[i];
      var conflict = ConflictState.none;
      for (var j = 0; j < courseOccs.length; j++) {
        if (i == j) continue;
        final other = courseOccs[j];
        if (other.sourceId == occ.sourceId) continue;
        if (occ.endUtc.isAfter(other.startUtc) && occ.startUtc.isBefore(other.endUtc)) {
          conflict = ConflictState.hard;
          break;
        }
      }
      events.add(_courseEvent(occ, conflict));
    }

    for (final occ in scheduleOccs) {
      var conflict = ConflictState.none;
      for (final c in courseOccs) {
        if (occ.endUtc.isAfter(c.startUtc) && occ.startUtc.isBefore(c.endUtc)) {
          conflict = ConflictState.soft;
          break;
        }
      }
      events.add(UiEvent(
        id: 'recurring:${occ.sourceId}:${occ.localDate}',
        type: EventType.recurringSchedule,
        title: occ.title ?? '日程',
        startUtc: occ.startUtc,
        endUtc: occ.endUtc,
        sourceType: EntityTypes.recurringSchedule,
        sourceId: occ.sourceId,
        conflict: conflict,
        color: occ.color,
        note: occ.notes,
      ));
    }

    final todosById = {for (final t in todos) t.id: t};
    for (final b in blocks) {
      final todo = todosById[b.todoId];
      if (todo == null) continue;
      var conflict = ConflictState.none;
      for (final c in courseOccs) {
        if (b.endAt.isAfter(c.startUtc) && b.startAt.isBefore(c.endUtc)) {
          conflict = ConflictState.soft;
          break;
        }
      }
      events.add(UiEvent(
        id: 'todo_block:${b.id}',
        type: EventType.todoBlock,
        title: todo.title,
        startUtc: b.startAt,
        endUtc: b.endAt,
        sourceType: EntityTypes.todoBlock,
        sourceId: b.id,
        conflict: conflict,
        color: todo.color,
        note: b.blockNote,
      ));
    }

    if (includeDeadlines) {
      for (final t in todos) {
        final dl = t.deadlineAt;
        if (dl == null) continue;
        if (!dl.isBefore(endUtc) || dl.isBefore(startUtc)) continue;
        events.add(UiEvent(
          id: 'deadline:${t.id}',
          type: EventType.deadline,
          title: t.title,
          startUtc: dl,
          endUtc: dl,
          sourceType: EntityTypes.todo,
          sourceId: t.id,
          conflict: ConflictState.none,
          color: t.color,
          note: 'deadline:${dl.toIso8601String()}',
        ));
      }
    }

    events.sort((a, b) {
      final c = a.startUtc.compareTo(b.startUtc);
      if (c != 0) return c;
      return a.id.compareTo(b.id);
    });
    return EventProjectionResult(events: events, allDayEvents: const []);
  }

  UiEvent _courseEvent(Occurrence occ, ConflictState conflict) => UiEvent(
        id: 'course:${occ.sourceId}:${occ.localDate}',
        type: EventType.course,
        title: occ.title ?? '课程',
        startUtc: occ.startUtc,
        endUtc: occ.endUtc,
        sourceType: EntityTypes.courseMeeting,
        sourceId: occ.sourceId,
        conflict: conflict,
        color: occ.color,
        location: occ.location,
        teacher: occ.teacher,
        note: occ.notes,
      );
}

/// Computes a UTC window covering exactly [fromLocal]..[toLocalExclusive]
/// local calendar days.
({DateTime start, DateTime end}) localWindowToUtc(
  UserTime userTime,
  DateTime fromLocal,
  DateTime toLocalExclusive,
) {
  final start = tz.TZDateTime(userTime.location, fromLocal.year, fromLocal.month, fromLocal.day);
  final end = tz.TZDateTime(userTime.location, toLocalExclusive.year, toLocalExclusive.month, toLocalExclusive.day);
  return (start: start.toUtc(), end: end.toUtc());
}
