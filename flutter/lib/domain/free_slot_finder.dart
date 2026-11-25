import 'package:timezone/timezone.dart' as tz;

import '../core/time/user_time.dart';
import '../core/util/clock_utils.dart';
import '../core/util/json_utils.dart';
import '../data/local/entities_snapshot.dart';
import '../state/event_projection.dart';
import '../sync/expander.dart';
import 'calendar_event.dart';

/// A free time window inside one local natural day (docs/plans/v1/
/// phase-5-builtin-agent.md Step 1).
class FreeSlot {
  const FreeSlot({
    required this.dateLocal,
    required this.startUtc,
    required this.endUtc,
    required this.displayStartLocal,
    required this.displayEndLocal,
    required this.durationMinutes,
  });

  /// Local `YYYY-MM-DD` of the day the slot belongs to.
  final String dateLocal;

  /// Canonical UTC bounds; the range is half-open (`[startUtc, endUtc)`).
  final DateTime startUtc;
  final DateTime endUtc;

  /// `HH:mm` wall clock in the user timezone.
  final String displayStartLocal;
  final String displayEndLocal;

  final int durationMinutes;

  Map<String, dynamic> toJson() => {
    'dateLocal': dateLocal,
    'startUtc': formatUtc(startUtc),
    'endUtc': formatUtc(endUtc),
    'displayStartLocal': displayStartLocal,
    'displayEndLocal': displayEndLocal,
    'durationMinutes': durationMinutes,
  };
}

/// Local port of the server free-slot service (server/internal/freeslot).
///
/// Busy time is the course / recurring-schedule / todo-block projection, so the
/// finder never reports a gap that overlaps a real occupation. The result is
/// additionally clipped to a plausible waking window per local day
/// (`[dayStartMinute, dayEndMinute)`) and to the caller's UTC range.
class FreeSlotFinder {
  const FreeSlotFinder(this.userTime);

  final UserTime userTime;

  /// Default daily planning window: 08:00–22:30.
  static const defaultDayStartMinute = 8 * 60;
  static const defaultDayEndMinute = 22 * 60 + 30;

  /// Returns free slots in `[fromUtc, toUtc)`, ordered by start.
  ///
  /// [minDurationMinutes] filters out gaps too short to schedule into.
  /// [dayStartMinute] / [dayEndMinute] bound the daily window; an inverted
  /// window (start >= end) is treated as a defensive empty result.
  List<FreeSlot> find({
    required EntitiesSnapshot snapshot,
    required DateTime fromUtc,
    required DateTime toUtc,
    int minDurationMinutes = 30,
    int dayStartMinute = defaultDayStartMinute,
    int dayEndMinute = defaultDayEndMinute,
  }) {
    final from = fromUtc.toUtc();
    final to = toUtc.toUtc();
    if (!to.isAfter(from)) return const [];

    final dayStart = dayStartMinute.clamp(0, 1440);
    final dayEnd = dayEndMinute.clamp(0, 1440);
    if (dayEnd <= dayStart) return const [];
    final minimum = minDurationMinutes < 1 ? 1 : minDurationMinutes;

    // Project once for the whole range. Deadlines are points, never busy time.
    final events = EventProjection(EventExpander(userTime))
        .project(snapshot, startUtc: from, endUtc: to, includeDeadlines: false)
        .events
        .where((e) => e.type != EventType.deadline)
        .toList(growable: false);

    final out = <FreeSlot>[];
    final firstLocal = userTime.localFromUtc(from);
    final toLocal = userTime.localFromUtc(to);
    var day = tz.TZDateTime(
      userTime.location,
      firstLocal.year,
      firstLocal.month,
      firstLocal.day,
    );

    void emit(DateTime start, DateTime end) {
      if (!end.isAfter(start)) return;
      final minutes = end.difference(start).inMinutes;
      if (minutes < minimum) return;
      final startLocal = userTime.localFromUtc(start);
      final endLocal = userTime.localFromUtc(end);
      out.add(
        FreeSlot(
          dateLocal: userTime.localDateString(startLocal),
          startUtc: _plainUtc(start),
          endUtc: _plainUtc(end),
          displayStartLocal: _hhmm(startLocal),
          displayEndLocal: _hhmm(endLocal),
          durationMinutes: minutes,
        ),
      );
    }

    while (day.isBefore(toLocal)) {
      final windowStart = _atMinuteOfDay(day, dayStart);
      final windowEnd = _atMinuteOfDay(day, dayEnd);
      // Clip to the caller's half-open range.
      final rangeStart = windowStart.isAfter(from) ? windowStart : from;
      final rangeEnd = windowEnd.isBefore(to) ? windowEnd : to;

      if (rangeEnd.isAfter(rangeStart)) {
        final busy = <_Span>[];
        for (final e in events) {
          final eventEnd = e.endUtc;
          final eventStart = e.startUtc;
          if (!intervalsOverlap(eventStart, eventEnd, rangeStart, rangeEnd)) {
            continue;
          }
          // Cross-midnight events contribute only the part inside this day
          // window; an event spanning the whole window clips to all of it.
          final clippedStart = eventStart.isBefore(rangeStart)
              ? rangeStart
              : eventStart;
          final clippedEnd = eventEnd.isAfter(rangeEnd) ? rangeEnd : eventEnd;
          if (clippedEnd.isAfter(clippedStart)) {
            busy.add(_Span(clippedStart, clippedEnd));
          }
        }
        busy.sort((a, b) => a.start.compareTo(b.start));

        // Merge overlapping and adjacent spans, then emit the gaps.
        var cursor = rangeStart;
        var busyEnd = rangeStart;
        for (final span in busy) {
          if (span.start.isAfter(busyEnd)) {
            emit(cursor, span.start);
            cursor = span.start;
          }
          if (span.end.isAfter(busyEnd)) busyEnd = span.end;
          if (busyEnd.isAfter(cursor)) cursor = busyEnd;
        }
        emit(cursor, rangeEnd);
      }

      day = tz.TZDateTime(userTime.location, day.year, day.month, day.day + 1);
    }
    return out;
  }

  /// Local instant of [minute] minutes past midnight on [day].
  tz.TZDateTime _atMinuteOfDay(tz.TZDateTime day, int minute) {
    if (minute >= 1440) {
      return tz.TZDateTime(userTime.location, day.year, day.month, day.day + 1);
    }
    return tz.TZDateTime(
      userTime.location,
      day.year,
      day.month,
      day.day,
      minute ~/ 60,
      minute % 60,
    );
  }
}

class _Span {
  const _Span(this.start, this.end);
  final DateTime start;
  final DateTime end;
}

DateTime _plainUtc(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.millisecondsSinceEpoch,
  isUtc: true,
);

String _hhmm(DateTime local) =>
    '${local.hour.toString().padLeft(2, '0')}:'
    '${local.minute.toString().padLeft(2, '0')}';
