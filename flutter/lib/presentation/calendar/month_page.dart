import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../domain/calendar_event.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../sync/expander.dart';
import 'event_projection.dart';

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

/// Month grid (docs/ui-interaction.md §11). One range query worth of data is
/// indexed locally per local calendar day (docs/flutter-agent §Month).
class MonthPage extends ConsumerStatefulWidget {
  const MonthPage({super.key});

  @override
  ConsumerState<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends ConsumerState<MonthPage> {
  late DateTime _month; // any instant inside the displayed month (local)

  @override
  void initState() {
    super.initState();
    final now = DateTime.now().toUtc();
    _month = now;
  }

  void _shiftMonth(int delta) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    final local = userTime.localFromUtc(_month);
    setState(() {
      _month = tz.TZDateTime(userTime.location, local.year, local.month + delta, 1);
    });
  }

  @override
  Widget build(BuildContext context) {
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('月视图')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final snap = ref.watch(snapshotProvider).value;
    final syncState = ref.watch(syncCoordinatorProvider);

    final local = userTime.localFromUtc(_month);
    final firstOfMonth = tz.TZDateTime(userTime.location, local.year, local.month, 1);
    final monthEnd = tz.TZDateTime(userTime.location, local.year, local.month + 1, 1);
    final window = localWindowToUtc(userTime, firstOfMonth, monthEnd);

    List<UiEvent> events = const [];
    if (snap != null) {
      events = EventProjection(EventExpander(userTime))
          .project(snap, startUtc: window.start, endUtc: window.end)
          .events;
    }
    final byDay = groupEventsByLocalDay(events, userTime);

    final today = ref.read(serverNowProvider).value;
    final todayLocal = today == null ? null : userTime.localFromUtc(today);

    return Scaffold(
      appBar: AppBar(
        // Tapping the title jumps to any date; swiping left/right steps a month.
        title: InkWell(
          onTap: () => _pickDate(userTime),
          child: Text('${local.year}年${local.month}月'),
        ),
        actions: [
          IconButton(
            onPressed: syncState.syncing
                ? null
                : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
            icon: syncState.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: GestureDetector(
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 120) return;
          _shiftMonth(v < 0 ? 1 : -1);
        },
        child: Column(
        children: [
          Row(
            children: [
              IconButton(onPressed: () => _shiftMonth(-1), icon: const Icon(Icons.chevron_left)),
              TextButton(
                onPressed: () {
                  final n = ref.read(serverNowProvider).value ?? DateTime.now().toUtc();
                  setState(() => _month = n);
                },
                child: const Text('今天'),
              ),
              IconButton(onPressed: () => _shiftMonth(1), icon: const Icon(Icons.chevron_right)),
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
              child: _MonthGrid(
                userTime: userTime,
                month: firstOfMonth,
                byDay: byDay,
                cellHeight: ref.watch(monthCellHeightProvider),
                todayLocal: todayLocal == null ? null : tz.TZDateTime(userTime.location, todayLocal.year, todayLocal.month, todayLocal.day),
                onDayTap: (day) => _showDay(day, byDay[userTime.localDateString(day)] ?? const [], userTime),
              ),
            ),
          ),
        ],
        ),
      ),
    );
  }

  /// Jump to a specific month (the header is the entry point).
  Future<void> _pickDate(UserTime userTime) async {
    final local = userTime.localFromUtc(_month);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(local.year, local.month, 1),
      firstDate: DateTime(local.year - 5),
      lastDate: DateTime(local.year + 5),
    );
    if (picked == null || !mounted) return;
    setState(() => _month = tz.TZDateTime(userTime.location, picked.year, picked.month, 1));
  }

  void _showDay(DateTime day, List<UiEvent> events, UserTime userTime) {
    showModalBottomSheet<void>(
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
                  for (final e in chips)
                    _MiniChip(event: e, meta: eventMeta(e)),
                  if (deadlines.isNotEmpty) _DeadlineLine(events: deadlines, userTime: userTime),
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
        final sorted = [...events]..sort((a, b) => a.startUtc.compareTo(b.startUtc));
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
                      ? '截止 $startText'
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
