import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../core/error/api_exception.dart';
import '../../core/time/user_time.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/calendar_event.dart';
import '../../domain/entities.dart';
import '../../domain/override.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../sync/expander.dart';
import 'event_projection.dart';
import 'grid_view.dart';
import 'month_page.dart' show weekGutterLabel;

const double _hourPx = 48.0;
const double _timeGutter = 46.0;

/// Week tab view modes: continuous 7×24 timeline vs period Grid (纯课表).
enum WeekViewMode { timeline, grid }

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

/// 7-column × 24-hour week grid (docs/ui-interaction.md §1).
class WeekPage extends ConsumerStatefulWidget {
  const WeekPage({super.key});

  @override
  ConsumerState<WeekPage> createState() => _WeekPageState();
}

class _WeekPageState extends ConsumerState<WeekPage> {
  late DateTime _anchor; // any instant whose local date is inside the shown week
  bool _dragActive = false;

  @override
  void initState() {
    super.initState();
    _anchor = DateTime.now().toUtc();
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToTodayIfNeeded());
  }

  void _toggleViewMode() {
    _slideDir = 1;
    final next = ref.read(weekViewModeProvider) == WeekViewModeController.grid
        ? WeekViewModeController.timeline
        : WeekViewModeController.grid;
    ref.read(weekViewModeProvider.notifier).set(next);
  }

  void _jumpToTodayIfNeeded() {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    final local = userTime.localFromUtc(ref.read(serverNowProvider).value ?? DateTime.now().toUtc());
    final anchorLocal = userTime.localFromUtc(_anchor);
    if (_weekStart(local) != _weekStart(anchorLocal)) {
      setState(() => _anchor = local);
    }
  }

  tz.TZDateTime _weekStart(DateTime local) {
    final userTime = ref.read(userTimeProvider)!;
    final wd = userTime.isoWeekday(local);
    return tz.TZDateTime(userTime.location, local.year, local.month, local.day - (wd - 1));
  }

  /// Which way the last period change went, so the slide runs the right way.
  int _slideDir = 1;

  void _moveWeek(int deltaWeeks) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    if (deltaWeeks != 0) _slideDir = deltaWeeks > 0 ? 1 : -1;
    final local = userTime.localFromUtc(_anchor);
    setState(() => _anchor = userTime.addLocalDays(local, deltaWeeks * 7));
  }

  @override
  Widget build(BuildContext context) {
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('周视图')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final viewMode =
        ref.watch(weekViewModeProvider) == WeekViewModeController.grid
            ? WeekViewMode.grid
            : WeekViewMode.timeline;
    final noonBoundary = ref.watch(noonBoundaryProvider);
    final now = ref.read(serverNowProvider).value;
    final snap = ref.watch(snapshotProvider).value;
    final syncState = ref.watch(syncCoordinatorProvider);

    final weekStart = _weekStart(userTime.localFromUtc(_anchor));
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++)
        tz.TZDateTime(userTime.location, weekStart.year, weekStart.month, weekStart.day + i),
    ];
    final window = localWindowToUtc(userTime, days.first, userTime.addLocalDays(days.last, 1));

    List<UiEvent> events = const [];
    if (snap != null) {
      events = EventProjection(EventExpander(userTime))
          .project(snap, startUtc: window.start, endUtc: window.end)
          .events;
    }

    final calendars = snap == null
        ? const <AcademicCalendar>[]
        : liveCalendars(snap).map((e) => e.value).toList();
    final semesterWeek = semesterWeekFor(calendars, userTime, days.first);
    final rangeText = days.length == 7
        ? '${days.first.month}月${days.first.day}日 – ${days.last.month}月${days.last.day}日'
        : '';
    final semesterText =
        semesterWeek == null ? '不在本学期' : '第${semesterWeek.week}周';

    return Scaffold(
      appBar: AppBar(
        // Tapping the title jumps to any date (also reachable by swiping the
        // body left/right to step a week).
        title: InkWell(
          onTap: () => _pickDate(userTime),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(rangeText, style: const TextStyle(fontSize: 16)),
              Text(
                semesterText,
                style: TextStyle(
                  fontSize: 12,
                  color: semesterWeek == null
                      ? Theme.of(context).colorScheme.error
                      : Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: viewMode == WeekViewMode.timeline ? '切到课表视图' : '切到时间轴周视图',
            onPressed: _toggleViewMode,
            icon: Icon(
              viewMode == WeekViewMode.timeline
                  ? Icons.view_agenda_outlined
                  : Icons.view_day_outlined,
            ),
          ),
          IconButton(
            tooltip: '同步',
            onPressed: syncState.syncing ? null : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
            icon: syncState.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      // Swiping left/right steps a week (both view modes); vertical drags stay
      // with the scrollable inside.
      body: GestureDetector(
        onHorizontalDragEnd: (d) {
          final v = d.primaryVelocity ?? 0;
          if (v.abs() < 120) return;
          _moveWeek(v < 0 ? 1 : -1);
        },
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) {
            // The incoming page comes in from the swipe direction; the outgoing
            // one leaves the other way, otherwise both travel together.
            final incoming = child.key == ValueKey(_pageKey(days, viewMode));
            final dx = (incoming ? _slideDir : -_slideDir).toDouble();
            return ClipRect(
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: Offset(dx, 0),
                  end: Offset.zero,
                ).animate(animation),
                child: child,
              ),
            );
          },
          child: KeyedSubtree(
            key: ValueKey(_pageKey(days, viewMode)),
            child: Column(
        children: viewMode == WeekViewMode.grid
            ? [
                _WeekNavRow(
                  days: days,
                  onPrev: () => _moveWeek(-1),
                  onNext: () => _moveWeek(1),
                  onToday: () => setState(() => _anchor = now ?? DateTime.now().toUtc()),
                  // The course-drag switch lives with the period navigation.
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('课程可长按拖动', style: TextStyle(fontSize: 12)),
                      Switch(
                        value: ref.watch(courseEditableInCourseViewProvider),
                        onChanged: (v) => ref
                            .read(courseEditableInCourseViewProvider.notifier)
                            .set(v),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: GridViewContent(
                    userTime: userTime,
                    days: days,
                    events: events,
                    snapshot: snap,
                    nowUtc: now,
                    courseEditable: ref.watch(courseEditableInCourseViewProvider),
                    noonBoundaryMinutes: noonBoundary,
                    onCommitMove: _commitEventMove,
                  ),
                ),
              ]
            : [
                _WeekHeader(
                  days: days,
                  todayLocal: now == null ? null : userTime.localFromUtc(now),
                  onPrev: () => _moveWeek(-1),
                  onNext: () => _moveWeek(1),
                  onToday: () => setState(() => _anchor = now ?? DateTime.now().toUtc()),
                ),
                Expanded(child: _buildGrid(userTime, days, events, now)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Identity of the shown period (week + mode) so the switcher animates on a
  /// period change and stays still on unrelated rebuilds.
  String _pageKey(List<tz.TZDateTime> days, WeekViewMode mode) =>
      '${days.first.year}-${days.first.month}-${days.first.day}-${mode.name}';

  /// Jump straight to a date (the header is the entry point).
  Future<void> _pickDate(UserTime userTime) async {
    final current = userTime.localFromUtc(_anchor);
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(current.year, current.month, current.day),
      firstDate: DateTime(current.year - 3),
      lastDate: DateTime(current.year + 3),
    );
    if (picked == null || !mounted) return;
    setState(() => _anchor =
        userTime.fromLocalParts(picked.year, picked.month, picked.day, 12, 0).toUtc());
  }

  Widget _buildGrid(UserTime userTime, List<tz.TZDateTime> days, List<UiEvent> events, DateTime? now) {
    return LayoutBuilder(builder: (context, constraints) {
      final dayWidth = math.max(56.0, (constraints.maxWidth - _timeGutter) / 7);
      final totalHeight = _hourPx * 24;
      final nowLocal = now == null ? null : userTime.localFromUtc(now);

      // Everything (day columns, event layer, now line) lives inside ONE
      // scrollable at the same origin, so the background and the events always
      // scroll together. Keeping the event layer outside as a sibling Stack
      // child pinned it to the viewport while the columns scrolled away.
      //
      // The scrollable keeps the DEFAULT drag devices. Disabling them (an
      // earlier workaround so tiles would win their drags) also disables touch
      // scrolling entirely — there is no mouse wheel on a phone. Tiles use a
      // vertical-drag recogniser instead, which shares the scrollable's slop and
      // wins the arena because it is hit-tested first.
      return SingleChildScrollView(
        physics: _dragActive
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        child: SizedBox(
          width: constraints.maxWidth,
          height: totalHeight,
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: _timeGutter, child: _TimeAxis()),
                  for (var d = 0; d < 7; d++)
                    SizedBox(
                      width: dayWidth,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) {
                          final minute = (details.localPosition.dy / _hourPx * 60).floor().clamp(0, 23 * 60 + 55);
                          _onEmptySlotTap(days[d], minute);
                        },
                        child: _DayColumn(userTime: userTime, date: days[d], isToday: _isSameLocalDay(days[d], nowLocal)),
                      ),
                    ),
                ],
              ),
              // event layer, same coordinate origin as the day columns
              if (dayWidth > 0)
                Positioned(
                  left: _timeGutter,
                  top: 0,
                  width: dayWidth * 7,
                  height: totalHeight,
                  child: ClipRect(
                    child: Stack(children: [
                      for (final e in events)
                        if (e.type != EventType.deadline)
                          _PositionedEvent(
                            key: ValueKey('${e.id}:${e.sourceId}'),
                            event: e,
                            userTime: userTime,
                            dayWidth: dayWidth,
                            onDragChanged: (v) => setState(() => _dragActive = v),
                            onCommit: (start, end) => _commitEventMove(e, start, end),
                          ),
                      // deadline markers
                      for (final e in events)
                        if (e.type == EventType.deadline && _localDayOf(e.startUtc, userTime) != null)
                          _DeadlineMarker(
                            event: e,
                            userTime: userTime,
                            dayIndex: _dayIndexOf(days, e, userTime),
                            dayWidth: dayWidth,
                            totalHeight: totalHeight,
                          ),
                    ]),
                  ),
                ),
              // current-time line: isolated so the per-minute tick never
              // rebuilds the event grid above. [_NowTicker] returns its own
              // Positioned, so it must be a DIRECT child of this Stack —
              // wrapping it in another Positioned broke the parent data (the
              // outer geometry won and the line was laid out as a full-day
              // orange block covering the events).
              if (dayWidth > 0)
                _NowTicker(days: days, dayWidth: dayWidth, totalHeight: totalHeight),
            ],
          ),
        ),
      );
    });
  }

  int _dayIndexOf(List<tz.TZDateTime> days, UiEvent e, UserTime userTime) {
    final local = _localDayOf(e.startUtc, userTime);
    if (local == null) return 0;
    final idx = days.indexWhere((d) => _isSameLocalDay(d, local));
    return idx >= 0 ? idx : 0;
  }

  bool _isSameLocalDay(DateTime a, DateTime? b) {
    if (b == null) return false;
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  DateTime? _localDayOf(DateTime utc, UserTime userTime) {
    final l = userTime.localFromUtc(utc);
    return tz.TZDateTime(userTime.location, l.year, l.month, l.day);
  }

  // ---- interaction ----------------------------------------------------------

  Future<void> _onEmptySlotTap(DateTime day, int minute) async {
    final userTime = ref.read(userTimeProvider)!;
    final snapped = _snap(minute);
    final result = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      builder: (_) => _QuickCreateSheet(day: day, startMinute: snapped),
    );
    if (result == null || !mounted) return;
    final title = result['title'] as String? ?? '';
    final duration = (result['durationMinutes'] as num?)?.toInt() ?? 60;
    final todoId = result['todoId'] as String?;
    final blockStart = userTime.fromLocalParts(day.year, day.month, day.day, snapped ~/ 60, snapped % 60);
    final blockEnd = blockStart.add(Duration(minutes: duration));
    try {
      final services = ref.read(servicesProvider);
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
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: ${e.message}')));
      }
    }
  }

  int _snap(int minute) {
    // Default snap: 5 minutes (docs/ui-interaction.md §8). Period snapping is
    // offered in the dedicated editors.
    return (minute / 5).round() * 5;
  }

  Future<void> _commitEventMove(UiEvent event, DateTime newStartUtc, DateTime newEndUtc) async {
    final services = ref.read(servicesProvider);
    if (event.sourceType == EntityTypes.todoBlock) {
      final blockId = event.sourceId;
      await services.repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: blockId,
        changes: {
          'startAt': newStartUtc,
          'endAt': newEndUtc,
        },
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
      return;
    }
    // course / recurring schedule occurrence edits are server-owned (series
    // apply) and therefore need connectivity.
    try {
      final seriesType = event.sourceType == EntityTypes.courseMeeting
          ? SeriesTypes.courseMeeting
          : SeriesTypes.recurringSchedule;
      final userTime = ref.read(userTimeProvider)!;
      final local = userTime.localFromUtc(newStartUtc);
      final dateStr = userTime.localDateString(local);
      await services.dataApi.seriesApply(
        seriesType: seriesType,
        seriesId: event.sourceId,
        scope: SeriesScopes.thisOne,
        occurrenceDateLocal: dateStr,
        operation: {
          'type': SeriesOperations.move,
          'startAt': _fmt(newStartUtc),
          'endAt': _fmt(newEndUtc),
        },
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e is NetworkException ? '离线时无法修改课程/周期安排' : '修改失败: ${e.message}')),
        );
      }
    }
  }

  String _fmt(DateTime d) {
    final u = d.toUtc();
    final s = '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}'
        'T${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')}:${u.second.toString().padLeft(2, '0')}Z';
    return s;
  }
}

class _WeekNavRow extends StatelessWidget {
  const _WeekNavRow({
    required this.days,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    this.trailing,
  });

  final List<tz.TZDateTime> days;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
        TextButton(onPressed: onToday, child: const Text('今天')),
        IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
        const Spacer(),
        ?trailing,
      ],
    );
  }
}

class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.days,
    required this.todayLocal,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
  });

  final List<tz.TZDateTime> days;
  final DateTime? todayLocal;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;

  static const _weekDays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            IconButton(onPressed: onPrev, icon: const Icon(Icons.chevron_left)),
            TextButton(onPressed: onToday, child: const Text('今天')),
            IconButton(onPressed: onNext, icon: const Icon(Icons.chevron_right)),
          ],
        ),
        Row(
          children: [
            // The gutter over the time axis carries the month.
            SizedBox(
              width: _timeGutter,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text(
                  weekGutterLabel(days),
                  textAlign: TextAlign.right,
                  style: TextStyle(fontSize: 11, color: colors.outline),
                ),
              ),
            ),
            for (var i = 0; i < 7; i++)
              Expanded(
                child: _DayHeader(
                  label: '周${_weekDays[i]}',
                  date: '${days[i].month}/${days[i].day}',
                  isToday: days[i].year == todayLocal?.year &&
                      days[i].month == todayLocal?.month &&
                      days[i].day == todayLocal?.day,
                  color: colors.primary,
                ),
              ),
          ],
        ),
        const Divider(height: 1),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({required this.label, required this.date, required this.isToday, required this.color});

  final String label;
  final String date;
  final bool isToday;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          const SizedBox(height: 2),
          Container(
            padding: const EdgeInsets.all(4),
            decoration: isToday ? BoxDecoration(color: color, shape: BoxShape.circle) : null,
            child: Text(date,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: isToday ? Colors.white : Theme.of(context).colorScheme.onSurface,
                )),
          ),
        ],
      ),
    );
  }
}

class _TimeAxis extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var h = 0; h < 24; h++)
          SizedBox(
            height: _hourPx,
            child: Align(
              alignment: Alignment.topRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Text('${h.toString().padLeft(2, '0')}:00', style: const TextStyle(fontSize: 9, color: Colors.grey)),
              ),
            ),
          ),
      ],
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({required this.userTime, required this.date, required this.isToday});

  final UserTime userTime;
  final DateTime date;
  final bool isToday;

  @override
  Widget build(BuildContext context) {
    final border = Theme.of(context).dividerColor.withValues(alpha: 0.5);
    return Container(
      decoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: border, width: 0.5),
          bottom: BorderSide(color: border, width: 0.5),
        ),
        color: isToday ? Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.15) : null,
      ),
      child: Stack(children: [
        for (var h = 1; h < 24; h++)
          Positioned(
            top: h * _hourPx,
            left: 0,
            right: 0,
            child: Divider(height: 1, color: border.withValues(alpha: 0.4)),
          ),
      ]),
    );
  }
}

/// One visual event block with vertical drag-to-move.
class _PositionedEvent extends StatefulWidget {
  const _PositionedEvent({
    super.key,
    required this.event,
    required this.userTime,
    required this.dayWidth,
    required this.onDragChanged,
    required this.onCommit,
  });

  final UiEvent event;
  final UserTime userTime;
  final double dayWidth;
  final ValueChanged<bool> onDragChanged;
  final void Function(DateTime startUtc, DateTime endUtc) onCommit;

  @override
  State<_PositionedEvent> createState() => _PositionedEventState();
}

class _PositionedEventState extends State<_PositionedEvent> {
  late DateTime _dragStartUtc;
  late DateTime _dragEndUtc;
  bool _dragging = false;
  int _dragBaseMinute = 0;

  /// 0 = move the whole block, 1 = drag the top edge, 2 = drag the bottom edge.
  int _mode = 0;
  int _startMinute0 = 0;
  int _endMinute0 = 0;
  bool _crossMidnight = false;

  @override
  Widget build(BuildContext context) {
    final userTime = widget.userTime;
    final localStart = userTime.localFromUtc(_dragging ? _dragStartUtc : widget.event.startUtc);
    final localEnd = userTime.localFromUtc(_dragging ? _dragEndUtc : widget.event.endUtc);
    final dayIndex = localStart.weekday - 1;

    final startMinute = localStart.hour * 60 + localStart.minute;
    final durationMinutes = localEnd.difference(localStart).inMinutes;

    final color = AppTheme.parseHex(widget.event.color) ??
        switch (widget.event.type) {
          EventType.course => AppTheme.courseColor,
          EventType.recurringSchedule => AppTheme.scheduleColor,
          EventType.todoBlock => AppTheme.blockColor,
          EventType.deadline => AppTheme.deadlineColor,
        };

    return Positioned(
      left: dayIndex * widget.dayWidth + 2,
      top: startMinute / 1440 * (_hourPx * 24),
      width: widget.dayWidth - 4,
      height: math.max(14.0, durationMinutes / 1440 * (_hourPx * 24)),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openEditor(),
        // Long-press gating: a plain swipe must scroll (phones have no wheel),
        // so moving a block is initiated by a long press — a gesture the
        // enclosing scrollable never claims.
        onLongPressStart: (details) {
          final ls = userTime.localFromUtc(widget.event.startUtc);
          final le = userTime.localFromUtc(widget.event.endUtc);
          _startMinute0 = ls.hour * 60 + ls.minute;
          _endMinute0 = le.hour * 60 + le.minute;
          _dragBaseMinute = 0;
          _dragStartUtc = widget.event.startUtc;
          _dragEndUtc = widget.event.endUtc;
          _dragging = true;
          _crossMidnight = false;
          // A long press near an edge resizes that edge, anywhere else moves.
          final h = context.size?.height ?? 0;
          _mode = h < 26
              ? 0
              : details.localPosition.dy < 8
                  ? 1
                  : details.localPosition.dy > h - 8
                      ? 2
                      : 0;
          widget.onDragChanged(true);
        },
        onLongPressMoveUpdate: (details) {
          if (!_dragging) return;
          // Long-press details carry the TOTAL offset from the press origin
          // (no per-event delta), so this is an assignment, not an accumulate.
          _dragBaseMinute = (details.offsetFromOrigin.dy / _hourPx * 60).round();
          _applyDrag(userTime);
        },
        onLongPressEnd: (_) => _finishDrag(userTime),
        onLongPressCancel: () => _cancelDrag(userTime),
        child: _EventVisual(
          event: widget.event,
          color: color,
          dragOverlay: _dragging && _crossMidnight,
          // Edge handles only when there is room to grab them.
          showHandles: math.max(14.0, durationMinutes / 1440 * (_hourPx * 24)) >= 26,
        ),
      ),
    );
  }

  void _applyDrag(UserTime userTime) {
    final localDate = userTime.localFromUtc(widget.event.startUtc);
    int newStart;
    int newEnd;
    switch (_mode) {
      case 1: // top edge, snapped to 5 minutes
        newStart = _snap5((_startMinute0 + _dragBaseMinute).clamp(0, 1439));
        newEnd = _endMinute0;
        if (newEnd - newStart < 15) return;
      case 2: // bottom edge
        newStart = _startMinute0;
        newEnd = _snap5((_endMinute0 + _dragBaseMinute).clamp(0, 1440));
        if (newEnd - newStart < 15) return;
      default: // whole block
        newStart = (_startMinute0 + _dragBaseMinute).clamp(0, 1439);
        newEnd = (_endMinute0 + _dragBaseMinute).clamp(0, 1440);
    }
    final crosses = !_sameDayMinutes(newStart, newEnd);
    setState(() {
      _crossMidnight = crosses;
      if (!crosses) {
        _dragStartUtc = userTime
            .fromLocalParts(localDate.year, localDate.month, localDate.day, newStart ~/ 60, newStart % 60)
            .toUtc();
        _dragEndUtc = userTime
            .fromLocalParts(localDate.year, localDate.month, localDate.day, newEnd ~/ 60, newEnd % 60)
            .toUtc();
      }
    });
  }

  bool _sameDayMinutes(int a, int b) => a >= 0 && a <= 1440 && b >= 0 && b <= 1440 && a < b;

  int _snap5(int minute) => ((minute / 5).round() * 5).clamp(0, 1440);

  void _finishDrag(UserTime userTime) {
    if (!_dragging) return;
    widget.onDragChanged(false);
    if (_crossMidnight) {
      setState(() {
        _dragging = false;
        _crossMidnight = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('时间块不能跨午夜（用户时区）')),
      );
      return;
    }
    final start = _dragStartUtc;
    final end = _dragEndUtc;
    setState(() => _dragging = false);
    widget.onCommit(start, end);
  }

  void _cancelDrag(UserTime userTime) {
    if (!_dragging) return;
    widget.onDragChanged(false);
    setState(() => _dragging = false);
  }

  Future<void> _openEditor() async {
    final e = widget.event;
    if (e.type == EventType.deadline) return;
    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      builder: (ctx) => _EventSheet(event: e, userTime: widget.userTime),
    );
  }
}

class _EventVisual extends StatelessWidget {
  const _EventVisual({
    required this.event,
    required this.color,
    this.dragOverlay = false,
    this.showHandles = false,
  });

  final UiEvent event;
  final Color color;
  final bool dragOverlay;
  final bool showHandles;

  @override
  Widget build(BuildContext context) {
    final bg = color.withValues(alpha: 0.85);
    final conflict = event.conflict;
    final borderColor = conflict == ConflictState.hard
        ? Colors.red
        : conflict == ConflictState.soft
            ? Colors.orangeAccent
            : Colors.transparent;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: borderColor, width: conflict == ConflictState.none ? 0 : 1.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
      child: Stack(children: [
        Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            event.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600),
          ),
          if (event.location != null && event.location!.isNotEmpty)
            Text(event.location!, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 9)),
        ],
        ),
        if (showHandles) ...[
          Positioned(left: 0, right: 0, top: 0, height: 4,
              child: Container(color: Colors.white.withValues(alpha: 0.35))),
          Positioned(left: 0, right: 0, bottom: 0, height: 4,
              child: Container(color: Colors.white.withValues(alpha: 0.35))),
        ],
      ]),
    );
  }
}

/// Current-time orange line (docs/ui-interaction.md §14). Watches
/// [serverNowProvider] alone so its per-minute ticks rebuild only this small
/// overlay — never the grid or the event layer.
class _NowTicker extends ConsumerWidget {
  const _NowTicker({
    required this.days,
    required this.dayWidth,
    required this.totalHeight,
  });

  final List<tz.TZDateTime> days;
  final double dayWidth;
  final double totalHeight;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final now = ref.watch(serverNowProvider).value;
    if (now == null) return const SizedBox.shrink();
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) return const SizedBox.shrink();
    final local = userTime.localFromUtc(now);
    var dayIndex = -1;
    for (var i = 0; i < days.length; i++) {
      final d = days[i];
      if (d.year == local.year && d.month == local.month && d.day == local.day) {
        dayIndex = i;
        break;
      }
    }
    if (dayIndex < 0) return const SizedBox.shrink();
    final minute = local.hour * 60 + local.minute;
    return Positioned(
      // The gutter offset lives here: this widget is the Stack child itself.
      left: _timeGutter + dayIndex * dayWidth,
      top: minute / 1440 * totalHeight - 1,
      width: dayWidth,
      height: 2,
      child: Container(color: AppTheme.nowLineColor),
    );
  }
}

class _DeadlineMarker extends StatelessWidget {
  const _DeadlineMarker({
    required this.event,
    required this.userTime,
    required this.dayIndex,
    required this.dayWidth,
    required this.totalHeight,
  });

  final UiEvent event;
  final UserTime userTime;
  final int dayIndex;
  final double dayWidth;
  final double totalHeight;

  @override
  Widget build(BuildContext context) {
    final local = userTime.localFromUtc(event.startUtc);
    final minute = local.hour * 60 + local.minute;
    return Positioned(
      left: dayIndex * dayWidth,
      top: minute / 1440 * totalHeight - 1,
      width: dayWidth,
      child: Container(
        height: 2,
        color: AppTheme.deadlineColor,
        child: const SizedBox.shrink(),
      ),
    );
  }
}

/// Bottom sheet: create a new todo block in an empty slot.
class _QuickCreateSheet extends StatefulWidget {
  const _QuickCreateSheet({required this.day, required this.startMinute});

  final DateTime day;
  final int startMinute;

  @override
  State<_QuickCreateSheet> createState() => _QuickCreateSheetState();
}

class _QuickCreateSheetState extends State<_QuickCreateSheet> {
  final _title = TextEditingController();
  int _duration = 60;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('新建日程块 · ${DateFormat('HH:mm').format(DateTime(2000, 1, 1, widget.startMinute ~/ 60, widget.startMinute % 60))}',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _title,
            autofocus: true,
            decoration: const InputDecoration(labelText: '做什么？（留空则只安排时间块）'),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _duration,
            decoration: const InputDecoration(labelText: '时长'),
            items: [30, 45, 60, 90, 120, 150, 180]
                .map((m) => DropdownMenuItem(value: m, child: Text('$m 分钟')))
                .toList(),
            onChanged: (v) => setState(() => _duration = v ?? 60),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop({
                'title': _title.text.trim(),
                'durationMinutes': _duration,
                'todoId': null,
              });
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
  }
}

/// Bottom sheet: event detail + actions (edit time / scope / delete).
class _EventSheet extends ConsumerWidget {
  const _EventSheet({required this.event, required this.userTime});

  final UiEvent event;
  final UserTime userTime;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final start = userTime.localFromUtc(event.startUtc);
    final end = userTime.localFromUtc(event.endUtc);
    final fmt = DateFormat('M月d日 HH:mm');
    final color = AppTheme.parseHex(event.color) ??
        switch (event.type) {
          EventType.course => AppTheme.courseColor,
          EventType.recurringSchedule => AppTheme.scheduleColor,
          EventType.todoBlock => AppTheme.blockColor,
          EventType.deadline => AppTheme.deadlineColor,
        };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Container(width: 10, height: 10, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Expanded(child: Text(event.title, style: Theme.of(context).textTheme.titleMedium)),
            ]),
            const SizedBox(height: 8),
            Text('${fmt.format(start)} – ${fmt.format(end)}',
                style: const TextStyle(color: Colors.black54)),
            const SizedBox(height: 6),
            const Text('长按色块可拖动/缩放', style: TextStyle(fontSize: 11, color: Colors.grey)),
            if (event.type == EventType.todoBlock) ...[
              const SizedBox(height: 8),
              Text('待办事项时间块', style: Theme.of(context).textTheme.bodySmall),
            ] else if (event.type == EventType.course ||
                event.type == EventType.recurringSchedule) ...[
              const SizedBox(height: 8),
              Text(event.type == EventType.course ? '课程安排' : '周期安排',
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.edit_calendar_outlined),
                  label: const Text('修改时间'),
                  onPressed: () => _pickNewTime(context, ref),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('删除'),
                  onPressed: () => _delete(context, ref),
                ),
              ),
            ]),
            if (event.conflict != ConflictState.none) ...[
              const SizedBox(height: 12),
              Text(
                event.conflict == ConflictState.hard ? '⚠ 与另一门课程冲突' : '⚠ 与课程时间重叠',
                style: TextStyle(
                  color: event.conflict == ConflictState.hard ? Colors.red : Colors.orange.shade800,
                  fontSize: 12,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _pickNewTime(BuildContext context, WidgetRef ref) async {
    final start = userTime.localFromUtc(event.startUtc);
    final end = userTime.localFromUtc(event.endUtc);
    final pickedStart = await showTimePicker(context: context, initialTime: TimeOfDay(hour: start.hour, minute: start.minute));
    if (pickedStart == null || !context.mounted) return;
    final pickedEnd = await showTimePicker(context: context, initialTime: TimeOfDay(hour: end.hour, minute: end.minute));
    if (pickedEnd == null || !context.mounted) return;
    final newStart = userTime.fromLocalParts(start.year, start.month, start.day, pickedStart.hour, pickedStart.minute);
    final newEnd = userTime.fromLocalParts(start.year, start.month, start.day, pickedEnd.hour, pickedEnd.minute);
    if (!userTime.sameLocalDay(newStart, newEnd) || newEnd.isBefore(newStart)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('时间不合法（不能跨午夜）')));
      return;
    }
    Navigator.of(context).pop();
    await _commit(context, ref, newStart.toUtc(), newEnd.toUtc());
  }

  Future<void> _commit(BuildContext context, WidgetRef ref, DateTime s, DateTime e) async {
    final services = ref.read(servicesProvider);
    if (event.sourceType == EntityTypes.todoBlock) {
      await services.repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: event.sourceId,
        changes: {'startAt': s.toUtc(), 'endAt': e.toUtc()},
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
    } else {
      final seriesType = event.sourceType == EntityTypes.courseMeeting
          ? SeriesTypes.courseMeeting
          : SeriesTypes.recurringSchedule;
      try {
        await services.dataApi.seriesApply(
          seriesType: seriesType,
          seriesId: event.sourceId,
          scope: SeriesScopes.thisOne,
          occurrenceDateLocal: userTime.localDateString(userTime.localFromUtc(s)),
          operation: {
            'type': SeriesOperations.move,
            'startAt': s.toUtc().toIso8601String(),
            'endAt': e.toUtc().toIso8601String(),
          },
        );
        ref.read(syncCoordinatorProvider.notifier).syncNow();
      } on ApiException catch (err) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(err is NetworkException ? '离线时无法修改，请联网后重试' : err.message)));
        }
      }
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final services = ref.read(servicesProvider);
    if (event.type == EventType.deadline) return;
    Navigator.of(context).pop();
    if (event.sourceType == EntityTypes.todoBlock) {
      await services.repo.localDelete(entityType: EntityTypes.todoBlock, entityId: event.sourceId);
      ref.read(syncCoordinatorProvider.notifier).syncNow();
    } else {
      try {
        final seriesType = event.sourceType == EntityTypes.courseMeeting
            ? SeriesTypes.courseMeeting
            : SeriesTypes.recurringSchedule;
        await services.dataApi.seriesApply(
          seriesType: seriesType,
          seriesId: event.sourceId,
          scope: SeriesScopes.thisOne,
          occurrenceDateLocal: userTime.localDateString(userTime.localFromUtc(event.startUtc)),
          operation: {'type': SeriesOperations.cancel},
        );
        ref.read(syncCoordinatorProvider.notifier).syncNow();
      } on ApiException catch (err) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(err.message)));
        }
      }
    }
  }
}
