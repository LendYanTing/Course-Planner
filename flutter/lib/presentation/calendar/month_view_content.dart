import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../domain/calendar_event.dart';
import '../../state/event_projection.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../sync/expander.dart';
import '../adaptive/adaptive.dart';
import '../widgets/calendar_background.dart';

/// Fills the blank gutter left of the weekday row: the month(s) the week spans.
String weekGutterLabel(List<DateTime> days) {
  if (days.isEmpty) return '';
  final first = days.first;
  final last = days.last;
  return first.month == last.month
      ? '${first.month}月'
      : '${first.month}/${last.month}月';
}

/// Buckets events by their local calendar day, keyed exactly like
/// [UserTime.localDateString] (zero-padded `YYYY-MM-DD`) so the month grid's
/// lookup matches. Using unpadded fields here silently emptied every day cell.
Map<String, List<UiEvent>> groupEventsByLocalDay(
  List<UiEvent> events,
  UserTime userTime,
) {
  final byDay = <String, List<UiEvent>>{};
  for (final e in events) {
    final localDate = userTime.localFromUtc(e.startUtc);
    byDay.putIfAbsent(userTime.localDateString(localDate), () => []).add(e);
  }
  return byDay;
}

/// The month grid body (`‹ 今天 ›` + weekday header + cells), reusable by the
/// standalone [MonthPage] and the 日程 page's 「月」 mode.
///
/// The anchor month is owned by the parent: this widget derives everything from
/// [anchorUtc] and reports navigation through [onShiftMonth]. Tapping a day
/// opens the day's detail sheet here and then additionally reports the local
/// day through [onSelectDate], so a host can jump to that day's week.
class MonthViewContent extends ConsumerStatefulWidget {
  const MonthViewContent({
    super.key,
    required this.anchorUtc,
    required this.onShiftMonth,
    required this.onSelectDate,
    this.cellHeight,
    this.showNavRow = true,
    this.paintBackground = true,
  });

  /// Any instant whose local date is inside the displayed month.
  final DateTime anchorUtc;

  /// Step months: -1 = previous, +1 = next.
  final void Function(int delta) onShiftMonth;

  /// The local calendar day that was tapped.
  final void Function(DateTime localDay) onSelectDate;

  /// Row height in dp; null → watch [monthCellHeightProvider].
  final double? cellHeight;

  /// Whether to draw the internal `‹ 今天 ›` row. A host that already pins its
  /// own navigation row (the week page) turns this off.
  final bool showNavRow;

  /// Whether to paint the user's [CalendarBackground] behind the grid. The
  /// standalone month page leaves this on (its Scaffold is transparent); the
  /// week page's 月 mode turns it off because the page body already paints one.
  final bool paintBackground;

  @override
  ConsumerState<MonthViewContent> createState() => _MonthViewContentState();
}

class _MonthViewContentState extends ConsumerState<MonthViewContent> {
  @override
  Widget build(BuildContext context) {
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) {
      return _wrapBackground(
        const Center(child: CircularProgressIndicator()),
      );
    }

    final local = userTime.localFromUtc(widget.anchorUtc);
    final firstOfMonth = tz.TZDateTime(userTime.location, local.year, local.month, 1);
    final monthEnd = tz.TZDateTime(userTime.location, local.year, local.month + 1, 1);
    final window = localWindowToUtc(userTime, firstOfMonth, monthEnd);

    final snap = ref.watch(snapshotProvider).value;
    List<UiEvent> events = const [];
    if (snap != null) {
      events = EventProjection(EventExpander(userTime))
          .project(snap, startUtc: window.start, endUtc: window.end)
          .events;
    }
    final byDay = groupEventsByLocalDay(events, userTime);

    final today = ref.read(serverNowProvider).value;
    final todayLocal = today == null ? null : userTime.localFromUtc(today);
    final double cellHeight = widget.cellHeight ?? ref.watch(monthCellHeightProvider);

    return _wrapBackground(
      Column(
        children: [
          if (widget.showNavRow)
            Row(
              children: [
                IconButton(
                  onPressed: () => widget.onShiftMonth(-1),
                  icon: const Icon(Icons.chevron_left),
                ),
                TextButton(
                  onPressed: () => _goToday(userTime),
                  child: const Text('今天'),
                ),
                IconButton(
                  onPressed: () => widget.onShiftMonth(1),
                  icon: const Icon(Icons.chevron_right),
                ),
                const Spacer(),
              ],
            ),
          Row(
            children: [
              for (final w in ['一', '二', '三', '四', '五', '六', '日'])
                Expanded(
                  child: Center(
                    child: Text(w, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                  ),
                ),
            ],
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              // The floating nav bar overlaps the viewport (extendBody), so the
              // month's last rows must be able to scroll clear of it.
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              child: _MonthGrid(
                userTime: userTime,
                month: firstOfMonth,
                byDay: byDay,
                cellHeight: cellHeight,
                todayLocal: todayLocal == null
                    ? null
                    : tz.TZDateTime(
                        userTime.location, todayLocal.year, todayLocal.month, todayLocal.day),
                onDayTap: (day) => _onDayTap(day, byDay[userTime.localDateString(day)] ?? const [], userTime),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The wallpaper layer, or the plain content when the host already paints it.
  Widget _wrapBackground(Widget child) =>
      widget.paintBackground ? CalendarBackground(child: child) : child;

  /// 「今天」: step straight to the month containing now. Within the displayed
  /// month there is nothing to shift, so report the day itself instead.
  void _goToday(UserTime userTime) {
    final now = ref.read(serverNowProvider).value ?? DateTime.now().toUtc();
    final today = userTime.localFromUtc(now);
    final local = userTime.localFromUtc(widget.anchorUtc);
    final delta = (today.year - local.year) * 12 + (today.month - local.month);
    if (delta == 0) {
      widget.onSelectDate(tz.TZDateTime(userTime.location, today.year, today.month, today.day));
    } else {
      widget.onShiftMonth(delta);
    }
  }

  void _onDayTap(DateTime day, List<UiEvent> events, UserTime userTime) {
    widget.onSelectDate(day);
    showAppBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (ctx) => _DaySheet(day: day, events: events, userTime: userTime),
    );
  }
}

class _MonthGrid extends StatelessWidget {
  const _MonthGrid({
    required this.userTime,
    required this.month,
    required this.byDay,
    required this.todayLocal,
    required this.onDayTap,
    required this.cellHeight,
  });

  final UserTime userTime;
  final DateTime month;
  final Map<String, List<UiEvent>> byDay;
  final DateTime? todayLocal;
  final void Function(DateTime day) onDayTap;

  /// Row height in dp (a local preference, see [monthCellHeightProvider]).
  final double cellHeight;

  @override
  Widget build(BuildContext context) {
    final leading = userTime.isoWeekday(month); // 1..7 for the 1st
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final cells = <Widget>[];
    for (var i = 1; i < leading; i++) {
      cells.add(const SizedBox.shrink());
    }
    for (var d = 1; d <= daysInMonth; d++) {
      final date = tz.TZDateTime(userTime.location, month.year, month.month, d);
      final key = userTime.localDateString(date);
      final tl = todayLocal;
      cells.add(_DayCell(
        date: date,
        events: byDay[key] ?? const [],
        isToday: tl != null &&
            tl.year == date.year &&
            tl.month == date.month &&
            tl.day == date.day,
        onTap: () => onDayTap(date),
        userTime: userTime,
      ));
    }
    // Height is the user's choice, so derive the aspect ratio from the actual
    // column width instead of hard-coding one.
    return LayoutBuilder(builder: (context, constraints) {
      final cellWidth = constraints.maxWidth / 7;
      return GridView.count(
        crossAxisCount: 7,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        childAspectRatio: cellWidth / cellHeight,
        children: cells,
      );
    });
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.events,
    required this.isToday,
    required this.onTap,
    required this.userTime,
  });

  final DateTime date;
  final List<UiEvent> events;
  final bool isToday;
  final VoidCallback onTap;
  final UserTime userTime;

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor.withValues(alpha: 0.6);
    final deadlines = events.where((e) => e.type == EventType.deadline).toList()
      ..sort((a, b) => a.startUtc.compareTo(b.startUtc));
    final chips = events.where((e) => e.type != EventType.deadline).toList();
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(border: Border.all(color: border, width: 0.5)),
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              alignment: Alignment.center,
              decoration: isToday ? BoxDecoration(color: Theme.of(context).colorScheme.primary, shape: BoxShape.circle) : null,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 11,
                  color: isToday ? Colors.white : null,
                  fontWeight: isToday ? FontWeight.bold : null,
                ),
              ),
            ),
            const SizedBox(height: 1),
            // A non-scrolling list clips instead of overflowing, so cells stay
            // valid at any window size even with multi-line chips.
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  // Reminders/deadlines first: they are single moments and get
                  // drowned out when a day is full of course blocks.
                  if (deadlines.isNotEmpty) _DeadlineLine(events: deadlines, userTime: userTime),
                  for (final e in chips)
                    _MiniChip(event: e, meta: eventMeta(e)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Secondary line for a month cell chip: classroom/teacher for classes, the
/// block note for todo blocks. Null when there is nothing to show — the
/// requirement is to leave it blank, never print a placeholder.
String? eventMeta(UiEvent e) {
  switch (e.type) {
    case EventType.course:
      final parts = <String>[
        if (e.location != null && e.location!.isNotEmpty) e.location!,
        if (e.teacher != null && e.teacher!.isNotEmpty) e.teacher!,
      ];
      return parts.isEmpty ? null : parts.join(' · ');
    case EventType.todoBlock:
      final note = e.note;
      return (note != null && note.isNotEmpty) ? note : null;
    case EventType.recurringSchedule:
    case EventType.deadline:
      return null;
  }
}

String _hhmmLocal(DateTime utc, UserTime userTime) {
  final local = userTime.localFromUtc(utc);
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

/// Whether two local wall-clock instants fall on the same calendar day.
bool _isSameDayLocal(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

/// Deadline marker for a day cell: the actual due **time** (not just a flag),
/// plus a `+N` when the day holds more than one deadline.
class _DeadlineLine extends StatelessWidget {
  const _DeadlineLine({required this.events, required this.userTime});

  final List<UiEvent> events;
  final UserTime userTime;

  @override
  Widget build(BuildContext context) {
    final first = events.first;
    final extra = events.length - 1;
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(
        color: AppTheme.deadlineColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        children: [
          const Icon(Icons.flag, size: 10, color: AppTheme.deadlineColor),
          const SizedBox(width: 2),
          Expanded(
            child: Text(
              '${first.title} ${_hhmmLocal(first.startUtc, userTime)}'
              '${extra > 0 ? ' +$extra' : ''}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 9, color: AppTheme.deadlineColor),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.event, this.meta});

  final UiEvent event;
  final String? meta;

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.parseHex(event.color) ??
        switch (event.type) {
          EventType.course => AppTheme.courseColor,
          EventType.recurringSchedule => AppTheme.scheduleColor,
          EventType.todoBlock => AppTheme.blockColor,
          EventType.deadline => AppTheme.deadlineColor,
        };
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(2)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(width: 4, height: 4, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 2),
              Expanded(
                child: Text(
                  event.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 9),
                ),
              ),
            ],
          ),
          if (meta != null)
            Padding(
              padding: const EdgeInsets.only(left: 6, top: 1),
              child: Text(
                meta!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 8, color: Colors.black54),
              ),
            ),
        ],
      ),
    );
  }
}

class _DaySheet extends StatelessWidget {
  const _DaySheet({required this.day, required this.events, required this.userTime});

  final DateTime day;
  final List<UiEvent> events;
  final UserTime userTime;

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('HH:mm');
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      builder: (context, controller) {
        final sorted = [...events]..sort((a, b) {
            // Same ordering as the day cell: reminders/deadlines on top.
            final ad = a.type == EventType.deadline ? 0 : 1;
            final bd = b.type == EventType.deadline ? 0 : 1;
            if (ad != bd) return ad - bd;
            return a.startUtc.compareTo(b.startUtc);
          });
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                '${day.month}月${day.day}日 · ${sorted.length} 项',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                controller: controller,
                itemCount: sorted.length,
                itemBuilder: (context, i) {
                  final e = sorted[i];
                  final color = AppTheme.parseHex(e.color) ??
                      switch (e.type) {
                        EventType.course => AppTheme.courseColor,
                        EventType.recurringSchedule => AppTheme.scheduleColor,
                        EventType.todoBlock => AppTheme.blockColor,
                        EventType.deadline => AppTheme.deadlineColor,
                      };
                  final startLocal = userTime.localFromUtc(e.startUtc);
                  final endLocal = userTime.localFromUtc(e.endUtc);
                  final startText = fmt.format(startLocal);
                  final endText = fmt.format(endLocal);
                  // Deadlines show their actual due time, not a bare "截止".
                  final showTime = e.type == EventType.deadline
                      ? '${e.reminder ? '提醒' : '截止'} $startText'
                      : '${_isSameDayLocal(startLocal, endLocal) ? '' : '${endLocal.month}/${endLocal.day} '}'
                          '$startText-$endText';
                  final meta = eventMeta(e);
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.circle, size: 12, color: color),
                    title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: meta == null
                        ? null
                        : Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 11, color: Colors.black54)),
                    trailing: Text(showTime, style: TextStyle(fontSize: 12, color: e.type == EventType.deadline ? AppTheme.deadlineColor : Colors.grey)),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
