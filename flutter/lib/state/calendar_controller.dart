import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error/api_exception.dart';
import '../core/time/user_time.dart';
import '../data/local/view_models.dart';
import '../domain/calendar.dart';
import '../domain/calendar_event.dart';
import '../domain/entities.dart';
import '../domain/override.dart';
import '../domain/todo.dart';
import 'event_projection.dart';
import '../sync/expander.dart';
import 'app_services.dart';
import 'providers.dart';
import 'sync_controller.dart';

// The calendar's business layer: the week/month event projection, the semester
// week lookup, and every write the week view performs (the 课表 grid shares the
// block-note write). Gesture handling and grid geometry stay in the widgets.

/// Which week of which semester the given local Monday falls in.
///
/// Returns null when the week is outside every known semester, which the header
/// then renders as 「不在本学期」 rather than guessing a number.
({int week, String calendarId})? semesterWeekFor(
  List<AcademicCalendar> calendars,
  UserTime userTime,
  DateTime weekMondayLocal,
) {
  final dateStr = userTime.localDateString(weekMondayLocal);
  final expander = EventExpander(userTime);
  for (final c in calendars) {
    final n = expander.weekOf(c.firstDay, dateStr);
    if (n >= 1 && n <= c.totalWeeks) return (week: n, calendarId: c.id);
  }
  return null;
}

/// Outcome of the latest calendar mutation. No page reads it yet (each call
/// site surfaces its own snackbar); it lets a future UI show a busy indicator
/// without new plumbing.
class CalendarMutationState {
  const CalendarMutationState({this.busy = false});

  final bool busy;
}

/// `seriesApply` payload for moving one occurrence of a course or recurring
/// schedule, with the exact wire shape the server expects.
Map<String, dynamic> seriesMoveOperation({
  required DateTime startUtc,
  required DateTime endUtc,
}) =>
    {
      'type': SeriesOperations.move,
      'startAt': isoInstant(startUtc),
      'endAt': isoInstant(endUtc),
    };

/// RFC3339 in UTC with second precision — the shape the server accepted from
/// the drag path before (and accepts alongside millisecond variants).
String isoInstant(DateTime d) {
  final u = d.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${u.year.toString().padLeft(4, '0')}-${two(u.month)}-${two(u.day)}'
      'T${two(u.hour)}:${two(u.minute)}:${two(u.second)}Z';
}

/// Local `YYYY-MM-DD` of [instant] in the user's fixed timezone: how a series
/// occurrence is addressed on the wire.
String occurrenceLocalDate(UserTime userTime, DateTime instant) =>
    userTime.localDateString(userTime.localFromUtc(instant));

/// Owns every calendar write: block moves (local-first) and course / recurring
/// occurrence edits (server series apply), plus quick creation and deletion.
///
/// Methods return the [ApiException] to display, or null on success, so each
/// call site keeps its own wording.
class CalendarController extends Notifier<CalendarMutationState> {
  @override
  CalendarMutationState build() => const CalendarMutationState();

  /// Moves or resizes one event.
  ///
  /// * todo block → local-first update, no network needed;
  /// * course / recurring schedule occurrence → server series apply, so it
  ///   requires connectivity.
  Future<ApiException?> moveEvent({
    required UiEvent event,
    required DateTime startUtc,
    required DateTime endUtc,
  }) async {
    final services = ref.read(servicesProvider);
    if (event.sourceType == EntityTypes.todoBlock) {
      await services.repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: event.sourceId,
        changes: {'startAt': startUtc, 'endAt': endUtc},
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
      return null;
    }
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return null;
    return _seriesApply(
      event: event,
      // The occurrence is identified by its (new) local start date — the same
      // anchor both the drag path and the event sheet used before.
      occurrenceDateLocal: occurrenceLocalDate(userTime, startUtc),
      operation: seriesMoveOperation(startUtc: startUtc, endUtc: endUtc),
    );
  }

  /// Deletes one occurrence (deadlines are not deletable).
  Future<ApiException?> deleteEvent(UiEvent event) async {
    if (event.type == EventType.deadline) return null;
    final services = ref.read(servicesProvider);
    if (event.sourceType == EntityTypes.todoBlock) {
      await services.repo.localDelete(
        entityType: EntityTypes.todoBlock,
        entityId: event.sourceId,
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
      return null;
    }
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return null;
    return _seriesApply(
      event: event,
      // Deleting refers to the occurrence the user tapped, not a new start.
      occurrenceDateLocal: occurrenceLocalDate(userTime, event.startUtc),
      operation: {'type': SeriesOperations.cancel},
    );
  }

  /// Creates a todo (when [todoId] is null) plus its time block at [startMinute]
  /// on [day], both local-first.
  Future<ApiException?> createQuickBlock({
    required DateTime day,
    required int startMinute,
    required int durationMinutes,
    required String title,
    String? todoId,
  }) async {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return null;
    final services = ref.read(servicesProvider);
    final blockStart = userTime.fromLocalParts(
      day.year,
      day.month,
      day.day,
      startMinute ~/ 60,
      startMinute % 60,
    );
    final blockEnd = blockStart.add(Duration(minutes: durationMinutes));
    try {
      String? targetTodoId = todoId;
      targetTodoId ??= await services.repo.localCreate(
        entityType: EntityTypes.todo,
        snapshot: {
          'title': title,
          'type': TodoType.oneOff.wire,
          'priority': TodoPriority.normal.wire,
          'status': TodoStatus.todo.wire,
          'tagIds': <String>[],
        },
      );
      await services.repo.localCreate(
        entityType: EntityTypes.todoBlock,
        snapshot: {
          'todoId': targetTodoId,
          'startAt': blockStart.toUtc(),
          'endAt': blockEnd.toUtc(),
          'status': BlockStatus.scheduled.wire,
        },
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
      return null;
    } on ApiException catch (e) {
      return e;
    }
  }

  /// Writes a block note on a todo block (local-first).
  Future<void> updateBlockNote({
    required String blockId,
    required String note,
  }) async {
    final services = ref.read(servicesProvider);
    await services.repo.localUpdate(
      entityType: EntityTypes.todoBlock,
      entityId: blockId,
      changes: {'blockNote': note.isEmpty ? null : note},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  /// Shared course / recurring-schedule path: one occurrence through the
  /// server's series endpoint, then a push.
  Future<ApiException?> _seriesApply({
    required UiEvent event,
    required String occurrenceDateLocal,
    required Map<String, dynamic> operation,
  }) async {
    state = const CalendarMutationState(busy: true);
    final services = ref.read(servicesProvider);
    try {
      await services.dataApi.seriesApply(
        seriesType: event.sourceType == EntityTypes.courseMeeting
            ? SeriesTypes.courseMeeting
            : SeriesTypes.recurringSchedule,
        seriesId: event.sourceId,
        scope: SeriesScopes.thisOne,
        occurrenceDateLocal: occurrenceDateLocal,
        operation: operation,
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
      return null;
    } on ApiException catch (e) {
      return e;
    } finally {
      // Always clear: a non-ApiException escaping must not leave the flag on.
      state = const CalendarMutationState();
    }
  }
}

final calendarControllerProvider =
    NotifierProvider<CalendarController, CalendarMutationState>(
  CalendarController.new,
);

/// Projected events for one visible UTC window.
///
/// The projection walks the whole mirror (courses, schedules, blocks,
/// deadlines), so it is derived once per window instead of on every build.
final calendarEventsProvider = Provider.autoDispose
    .family<List<UiEvent>, ({DateTime startUtc, DateTime endUtc})>(
  (ref, window) {
    final snap = ref.watch(snapshotProvider).value;
    final userTime = ref.watch(userTimeProvider);
    if (snap == null || userTime == null) return const <UiEvent>[];
    return EventProjection(EventExpander(userTime))
        .project(snap, startUtc: window.startUtc, endUtc: window.endUtc)
        .events;
  },
);

/// Semester/week lookup for the week header (第N周), keyed by the shown local
/// Monday.
final semesterWeekProvider = Provider.autoDispose
    .family<({int week, String calendarId})?, DateTime>(
  (ref, mondayLocal) {
    final snap = ref.watch(snapshotProvider).value;
    final userTime = ref.watch(userTimeProvider);
    if (snap == null || userTime == null) return null;
    return semesterWeekFor(
      liveCalendars(snap).map((e) => e.value).toList(),
      userTime,
      mondayLocal,
    );
  },
);
