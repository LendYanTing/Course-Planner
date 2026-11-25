import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error/api_exception.dart';
import '../core/time/user_time.dart';
import '../data/local/view_models.dart';
import '../domain/calendar.dart';
import '../domain/calendar_event.dart';
import '../domain/entities.dart';
import '../domain/local_series_service.dart';
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

/// Owns every calendar write: block moves (local-first), course / recurring
/// occurrence edits (local series service) and quick creation / deletion.
///
/// Methods return the [ApiException] to display, or null on success, so each
/// call site keeps its own wording.
class CalendarController extends Notifier<CalendarMutationState> {
  @override
  CalendarMutationState build() => const CalendarMutationState();

  /// Moves or resizes one event.
  ///
  /// * todo block → local-first update, no network needed;
  /// * course / recurring schedule occurrence → a local `occurrence_override`
  ///   (`LocalSeriesService.moveOccurrence`), also fully offline.
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
      return null;
    }
    final userTime = ref.read(userTimeProvider);
    final snapshot = ref.read(snapshotProvider).value;
    if (userTime == null || snapshot == null) return null;
    state = const CalendarMutationState(busy: true);
    try {
      await LocalSeriesService(
        repo: services.repo,
        userTime: userTime,
      ).moveOccurrence(
        snapshot: snapshot,
        seriesType: _seriesTypeFor(event),
        seriesId: event.sourceId,
        // The displayed start is the anchor: for an occurrence already moved
        // this is the existing override's replacementStartAt, so a second drag
        // updates that override instead of adding another one.
        originalStartUtc: event.startUtc,
        newStartUtc: startUtc,
        newEndUtc: endUtc,
      );
      // Kept for now; the sync trigger is converged separately (Step 4).
      return null;
    } on ApiException catch (e) {
      return e;
    } finally {
      // Always clear: a non-ApiException escaping must not leave the flag on.
      state = const CalendarMutationState();
    }
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
      return null;
    }
    final userTime = ref.read(userTimeProvider);
    final snapshot = ref.read(snapshotProvider).value;
    if (userTime == null || snapshot == null) return null;
    state = const CalendarMutationState(busy: true);
    try {
      await LocalSeriesService(
        repo: services.repo,
        userTime: userTime,
      ).cancelOccurrence(
        snapshot: snapshot,
        seriesType: _seriesTypeFor(event),
        seriesId: event.sourceId,
        // Deleting refers to the occurrence the user tapped.
        originalStartUtc: event.startUtc,
      );
      // Kept for now; the sync trigger is converged separately (Step 4).
      return null;
    } on ApiException catch (e) {
      return e;
    } finally {
      state = const CalendarMutationState();
    }
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
  }

  /// Shared course / recurring-schedule path is now
  /// [LocalSeriesService] (local overrides + weekly splits), so no server
  /// endpoint remains here.
  String _seriesTypeFor(UiEvent event) =>
      event.sourceType == EntityTypes.courseMeeting
          ? SeriesTypes.courseMeeting
          : SeriesTypes.recurringSchedule;
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
