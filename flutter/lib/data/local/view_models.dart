import '../../domain/calendar.dart';
import '../../domain/course.dart';
import '../../domain/entities.dart';
import '../../domain/override.dart';
import '../../domain/schedule.dart';
import '../../domain/todo.dart';
import 'entities_snapshot.dart';

/// Decoders turning the effective mirror into typed domain models, used by
/// every feature page. Pending (unacked) local state is represented by the
/// `pending` flag on the returned records so the UI can show chips.

class Live<T> {
  const Live(this.value, {this.pending = false});
  final T value;
  final bool pending;
}

List<Live<Todo>> liveTodos(EntitiesSnapshot s) => _map(s, EntityTypes.todo, Todo.fromJson);

List<Live<TodoBlock>> liveBlocks(EntitiesSnapshot s, {String? todoId}) {
  final out = <Live<TodoBlock>>[];
  for (final e in effectiveFor(s, EntityTypes.todoBlock)) {
    if (e.locallyDeleted) continue;
    final block = TodoBlock.fromJson(e.payload);
    if (todoId != null && block.todoId != todoId) continue;
    out.add(Live(block, pending: e.hasPendingOp));
  }
  out.sort((a, b) => a.value.startAt.compareTo(b.value.startAt));
  return out;
}

List<Live<Tag>> liveTags(EntitiesSnapshot s) => _map(s, EntityTypes.tag, Tag.fromJson);

List<Live<Category>> liveCategories(EntitiesSnapshot s) =>
    _map(s, EntityTypes.category, Category.fromJson);

List<Live<AcademicCalendar>> liveCalendars(EntitiesSnapshot s) =>
    _map(s, EntityTypes.calendar, AcademicCalendar.fromJson);

List<Live<PeriodTemplate>> livePeriods(EntitiesSnapshot s, {String? calendarId}) {
  final out = <Live<PeriodTemplate>>[];
  for (final e in effectiveFor(s, EntityTypes.period)) {
    if (e.locallyDeleted) continue;
    final p = PeriodTemplate.fromJson(e.payload);
    if (calendarId != null && p.calendarId != calendarId) continue;
    out.add(Live(p, pending: e.hasPendingOp));
  }
  out.sort((a, b) => a.value.periodNo.compareTo(b.value.periodNo));
  return out;
}

List<Live<Course>> liveCourses(EntitiesSnapshot s, {String? calendarId}) {
  final out = <Live<Course>>[];
  for (final e in effectiveFor(s, EntityTypes.course)) {
    if (e.locallyDeleted) continue;
    final c = Course.fromJson(e.payload);
    if (calendarId != null && c.calendarId != calendarId) continue;
    out.add(Live(c, pending: e.hasPendingOp));
  }
  out.sort((a, b) => a.value.name.compareTo(b.value.name));
  return out;
}

List<Live<CourseMeeting>> liveMeetings(EntitiesSnapshot s, {String? courseId}) {
  final out = <Live<CourseMeeting>>[];
  for (final e in effectiveFor(s, EntityTypes.courseMeeting)) {
    if (e.locallyDeleted) continue;
    final m = CourseMeeting.fromJson(e.payload);
    if (courseId != null && m.courseId != courseId) continue;
    out.add(Live(m, pending: e.hasPendingOp));
  }
  out.sort((a, b) {
    final c = a.value.weekday.compareTo(b.value.weekday);
    if (c != 0) return c;
    return a.value.periodStart.compareTo(b.value.periodStart);
  });
  return out;
}

List<Live<RecurringSchedule>> liveSchedules(EntitiesSnapshot s) =>
    _map(s, EntityTypes.recurringSchedule, RecurringSchedule.fromJson);

List<Live<OccurrenceOverride>> liveOverrides(EntitiesSnapshot s, {String? seriesType}) {
  final out = <Live<OccurrenceOverride>>[];
  for (final e in effectiveFor(s, EntityTypes.override)) {
    if (e.locallyDeleted) continue;
    final o = OccurrenceOverride.fromJson(e.payload);
    if (seriesType != null && o.seriesType != seriesType) continue;
    out.add(Live(o, pending: e.hasPendingOp));
  }
  return out;
}

List<Live<T>> _map<T>(
  EntitiesSnapshot s,
  String type,
  T Function(Map<String, dynamic>) decode,
) {
  final out = <Live<T>>[];
  for (final e in effectiveFor(s, type)) {
    if (e.locallyDeleted) continue;
    out.add(Live(decode(e.payload), pending: e.hasPendingOp));
  }
  return out;
}
