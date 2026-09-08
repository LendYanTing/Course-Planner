import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../domain/calendar_event.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../sync/expander.dart';
import 'event_projection.dart';

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
    final byDay = <String, List<UiEvent>>{};
    for (final e in events) {
      final localDate = userTime.localFromUtc(e.startUtc);
      byDay.putIfAbsent(
        '${localDate.year}-${localDate.month}-${localDate.day}',
        () => [],
      ).add(e);
    }

    final today = ref.read(serverNowProvider).value;
    final todayLocal = today == null ? null : userTime.localFromUtc(today);

    return Scaffold(
      appBar: AppBar(
        title: Text('${local.year}年${local.month}月'),
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
      body: Column(
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
                todayLocal: todayLocal == null ? null : tz.TZDateTime(userTime.location, todayLocal.year, todayLocal.month, todayLocal.day),
                onDayTap: (day) => _showDay(day, byDay[userTime.localDateString(day)] ?? const [], userTime),
              ),
            ),
          ),
        ],
      ),
    );
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
  });

  final UserTime userTime;
  final DateTime month;
  final Map<String, List<UiEvent>> byDay;
  final DateTime? todayLocal;
  final void Function(DateTime day) onDayTap;

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
      ));
    }
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      childAspectRatio: 0.78,
      children: cells,
    );
  }
}

class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.date,
    required this.events,
    required this.isToday,
    required this.onTap,
  });

  final DateTime date;
  final List<UiEvent> events;
  final bool isToday;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor.withValues(alpha: 0.6);
    final deadlineCount = events.where((e) => e.type == EventType.deadline).length;
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
            for (final e in events.where((e) => e.type != EventType.deadline).take(3))
              _MiniChip(event: e),
            if (deadlineCount > 0)
              Row(children: [
                const Icon(Icons.flag, size: 11, color: AppTheme.deadlineColor),
                const SizedBox(width: 2),
                Text('$deadlineCount', style: const TextStyle(fontSize: 10, color: AppTheme.deadlineColor)),
              ]),
          ],
        ),
      ),
    );
  }
}

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.event});

  final UiEvent event;

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
      child: Row(
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
                  final showTime = e.type == EventType.deadline
                      ? '截止'
                      : (startText == endText ? startText : '$startText-$endText');
                  return ListTile(
                    dense: true,
                    leading: Icon(Icons.circle, size: 12, color: color),
                    title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
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
