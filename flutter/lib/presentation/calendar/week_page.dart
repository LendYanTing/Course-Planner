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
import '../../domain/calendar_event.dart';
import '../../domain/todo.dart';
import '../../state/calendar_controller.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../state/event_projection.dart';
import '../adaptive/adaptive.dart';
import '../widgets/calendar_background.dart';
import 'grid_view.dart';
import 'month_view_content.dart' show MonthViewContent, weekGutterLabel;

const double _hourPx = 48.0;
const double _timeGutter = 46.0;

/// 日程 page view modes: period Grid (纯课表), continuous 7×24 timeline, and the
/// month grid. The names match the persisted [WeekViewModeController] strings.
enum WeekViewMode { timeline, grid, month }

/// Persisted string → page mode. An unknown value (e.g. a future mode) falls
/// back to the timeline.
WeekViewMode _viewModeFromPref(String value) => WeekViewMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => WeekViewMode.timeline,
    );

/// Local Monday of the week that contains [local].
tz.TZDateTime mondayOf(UserTime userTime, DateTime local) {
  final wd = userTime.isoWeekday(local);
  return tz.TZDateTime(userTime.location, local.year, local.month, local.day - (wd - 1));
}

/// Distance between the shown week and the week containing [nowLocal]:
/// negative = past, 0 = this week, positive = future. Null when "now" is
/// unknown (first frame before the server clock answered).
///
/// The day difference is taken on date-only UTC instants so a DST change inside
/// the span cannot turn an exact week into 6 days (which would floor to 0).
int? weeksFromThisWeek(
  UserTime userTime,
  tz.TZDateTime shownMonday,
  DateTime? nowLocal,
) {
  if (nowLocal == null) return null;
  final current = mondayOf(userTime, nowLocal);
  final shown = DateTime.utc(shownMonday.year, shownMonday.month, shownMonday.day);
  final today = DateTime.utc(current.year, current.month, current.day);
  return shown.difference(today).inDays ~/ 7;
}

/// Header subtitle under the date range: `第3周 · 1 周前`, `第3周 · 本周`,
/// `不在本学期 · 2 周后`, …
String weekSubtitle({required int? semesterWeek, required int? weeksFromThisWeek}) {
  final relative = weeksFromThisWeek == null
      ? null
      : weeksFromThisWeek == 0
          ? '本周'
          : weeksFromThisWeek > 0
              ? '$weeksFromThisWeek 周后'
              : '${-weeksFromThisWeek} 周前';
  return [
    semesterWeek == null ? '不在本学期' : '第$semesterWeek周',
    ?relative,
  ].join(' · ');
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

  /// Switch view mode without touching [_anchor]: the same period (week or
  /// month) stays on screen across 课表 / 周 / 月.
  void _setViewMode(WeekViewMode mode) {
    if (_viewModeFromPref(ref.read(weekViewModeProvider)) == mode) return;
    _slideDir = 1;
    ref.read(weekViewModeProvider.notifier).set(mode.name);
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

  tz.TZDateTime _weekStart(DateTime local) => mondayOf(ref.read(userTimeProvider)!, local);

  /// Which way the last period change went, so the slide runs the right way.
  int _slideDir = 1;

  void _moveWeek(int deltaWeeks) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    if (deltaWeeks != 0) _slideDir = deltaWeeks > 0 ? 1 : -1;
    final local = userTime.localFromUtc(_anchor);
    setState(() => _anchor = userTime.addLocalDays(local, deltaWeeks * 7));
  }

  /// Month-mode navigation: ±1 month in the user's timezone, anchored on the
  /// 1st so the whole month (not a day within it) is the unit.
  void _moveMonth(int deltaMonths) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    if (deltaMonths != 0) _slideDir = deltaMonths > 0 ? 1 : -1;
    final local = userTime.localFromUtc(_anchor);
    setState(() {
      _anchor = tz.TZDateTime(userTime.location, local.year, local.month + deltaMonths, 1);
    });
  }

  /// Back to today's week/month without leaving the current mode.
  void _goToday() {
    setState(() => _anchor = ref.read(serverNowProvider).value ?? DateTime.now().toUtc());
  }

  /// Actions for the period title: jump back to this week, toggle course
  /// dragging (课表 tiles) and open the date picker. The old navigation row
  /// (‹ 今天 › + switch) lived on screen permanently; folding it into a menu
  /// gives the timetable back that vertical space.
  Future<void> _showHeaderMenu(BuildContext context, UserTime userTime) async {
    var editable = ref.read(courseEditableInCourseViewProvider);
    await showAppDialog<void>(
      context: context,
      title: '日程视图',
      content: StatefulBuilder(
        builder: (dialogContext, setLocal) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              value: editable,
              title: const Text('课程可长按拖动'),
              subtitle: const Text('关闭后只能移动待办时间块'),
              onChanged: (v) {
                editable = v;
                ref.read(courseEditableInCourseViewProvider.notifier).set(v);
                setLocal(() {});
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.today_outlined),
              title: const Text('回到当前周'),
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                _goToday();
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.event_outlined),
              title: const Text('选择日期…'),
              onTap: () {
                Navigator.of(context, rootNavigator: true).pop();
                _pickDate(userTime);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  /// A day tapped in the month grid: anchor on it and show that week's 课表.
  void _selectDayInMonth(DateTime localDay) {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    setState(() {
      _anchor = userTime
          .fromLocalParts(localDay.year, localDay.month, localDay.day, 12, 0)
          .toUtc();
    });
    ref.read(weekViewModeProvider.notifier).set(WeekViewMode.grid.name);
  }

  @override
  Widget build(BuildContext context) {
    final userTime = ref.watch(userTimeProvider);
    if (userTime == null) {
      return Scaffold(
        appBar: AppTopBar(title: '周视图'),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final viewMode = _viewModeFromPref(ref.watch(weekViewModeProvider));
    final isMonth = viewMode == WeekViewMode.month;
    final noonBoundary = ref.watch(noonBoundaryProvider);
    // One read, handed down to every tile: a per-tile watch would rebuild each
    // tile on its own when a style slider moves.
    final cardStyle = ref.watch(courseCardStyleProvider);
    final hasBackground = ref.watch(backgroundConfigProvider).hasBackground;
    final now = ref.read(serverNowProvider).value;
    final snap = ref.watch(snapshotProvider).value;
    final syncState = ref.watch(syncCoordinatorProvider);

    final anchorLocal = userTime.localFromUtc(_anchor);
    final weekStart = _weekStart(anchorLocal);
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++)
        tz.TZDateTime(userTime.location, weekStart.year, weekStart.month, weekStart.day + i),
    ];
    final window = localWindowToUtc(userTime, days.first, userTime.addLocalDays(days.last, 1));

    // Projection and semester lookup are derived providers (calendar_controller),
    // so scrolling/rebuilding the page does not re-expand the whole mirror.
    final events = ref.watch(calendarEventsProvider(
      (startUtc: window.start, endUtc: window.end),
    ));
    final semesterWeek = ref.watch(semesterWeekProvider(days.first));
    final nowLocal = userTime.localFromUtc(now ?? DateTime.now().toUtc());
    final rangeText = days.length == 7
        ? '${days.first.month}月${days.first.day}日 – ${days.last.month}月${days.last.day}日'
        : '';
    // 第N周 plus how far the shown week is from this one («1 周前» / «本周»).
    final subtitle = weekSubtitle(
      semesterWeek: semesterWeek?.week,
      weeksFromThisWeek: weeksFromThisWeek(userTime, days.first, nowLocal),
    );

    final pageKey = _pageKey(days, viewMode);
    final periodContent = viewMode == WeekViewMode.month
        ? MonthViewContent(
            // The pinned bar above already carries ‹ 今天 ›.
            showNavRow: false,
            // The page body below already paints the wallpaper; a second
            // CalendarBackground would stack two scrims on the same pixels.
            paintBackground: false,
            anchorUtc: _anchor,
            onShiftMonth: _moveMonth,
            onSelectDate: _selectDayInMonth,
          )
        : viewMode == WeekViewMode.grid
            ? GridViewContent(
                userTime: userTime,
                days: days,
                events: events,
                snapshot: snap,
                nowUtc: now,
                courseEditable: ref.watch(courseEditableInCourseViewProvider),
                noonBoundaryMinutes: noonBoundary,
                rowHeight: cardStyle.rowHeight,
                cardStyle: cardStyle,
                hasBackground: hasBackground,
                onCommitMove: _commitEventMove,
                onEmptySlotTap: _onGridEmptyTap,
              )
            : Column(
                children: [
                  _WeekHeader(
                    days: days,
                    todayLocal: now == null ? null : userTime.localFromUtc(now),
                  ),
                  Expanded(
                    child: _buildGrid(userTime, days, events, now, cardStyle),
                  ),
                ],
              );

    return Scaffold(
      // A configured wallpaper shows through the page: everything that is not
      // explicitly tinted must stay transparent.
      backgroundColor: hasBackground ? Colors.transparent : null,
      appBar: AppTopBar(
        // The title is the period control now: it shows the semester week as
        // the headline (date range underneath) and opens the actions menu.
        titleWidget: InkWell(
          onTap: () => _showHeaderMenu(context, userTime),
          child: isMonth
              ? Text(
                  '${anchorLocal.year}年${anchorLocal.month}月',
                  style: const TextStyle(fontSize: 16),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: semesterWeek == null
                            ? Theme.of(context).colorScheme.error
                            : null,
                      ),
                    ),
                    Text(rangeText, style: const TextStyle(fontSize: 12)),
                  ],
                ),
        ),
        actions: [
          _ViewModeSwitch(mode: viewMode, onChanged: _setViewMode),
          // The sync action only exists for a cloud account with sync on; a
          // local session has no server to talk to.
          if (ref.watch(cloudSyncEnabledProvider))
            IconButton(
              tooltip: '同步',
              onPressed: syncState.syncing ? null : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
              icon: syncState.syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
        ],
      ),
      // The period title above carries the period controls (menu: 回到当前周 /
      // 课程可长按拖动 / 选择日期), so the body is just the sliding timetable.
      body: CalendarBackground(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              // Swiping left/right steps a week (or a month in 月 mode);
              // vertical drags stay with the scrollable inside.
              child: GestureDetector(
                onHorizontalDragEnd: (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() < 120) return;
                  if (isMonth) {
                    _moveMonth(v < 0 ? 1 : -1);
                  } else {
                    _moveWeek(v < 0 ? 1 : -1);
                  }
                },
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    // The incoming page comes in from the swipe direction; the
                    // outgoing one leaves the other way, otherwise both travel
                    // together.
                    final incoming = child.key == ValueKey(pageKey);
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
                    key: ValueKey(pageKey),
                    child: periodContent,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Identity of the shown period (week/month + mode) so the switcher animates
  /// on a period change and stays still on unrelated rebuilds.
  String _pageKey(List<tz.TZDateTime> days, WeekViewMode mode) {
    if (mode == WeekViewMode.month) {
      // The month grid depends on the anchor's local month only.
      final userTime = ref.read(userTimeProvider);
      if (userTime != null) {
        final local = userTime.localFromUtc(_anchor);
        return '${local.year}-${local.month}-${mode.name}';
      }
    }
    return '${days.first.year}-${days.first.month}-${days.first.day}-${mode.name}';
  }

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

  Widget _buildGrid(
    UserTime userTime,
    List<tz.TZDateTime> days,
    List<UiEvent> events,
    DateTime? now,
    CourseCardStyle style,
  ) {
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
        // The floating nav bar overlaps the viewport (extendBody), so reserve
        // its height here: the 24h timeline must scroll clear of it.
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
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
                      for (final (event, dayIndex) in _placedByDay(
                            days, events, userTime,
                            (e) => e.type != EventType.deadline))
                        _PositionedEvent(
                          key: ValueKey('${event.id}:${event.sourceId}'),
                          event: event,
                          userTime: userTime,
                          dayIndex: dayIndex,
                          dayWidth: dayWidth,
                          textLines: ref.watch(tileTextLinesProvider),
                          style: style,
                          onDragChanged: (v) => setState(() => _dragActive = v),
                          onCommit: (start, end) => _commitEventMove(event, start, end),
                        ),
                      // deadline markers
                      for (final (event, dayIndex) in _placedByDay(
                          days, events, userTime,
                          (e) => e.type == EventType.deadline))
                        _DeadlineMarker(
                          event: event,
                          userTime: userTime,
                          dayIndex: dayIndex,
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

  /// Events to draw on the timeline, paired with the column each belongs to.
  /// [include] picks the kind of event this layer draws (span tiles vs deadline
  /// markers).
  ///
  /// The projection already window-filters every kind, so this only drops events
  /// whose local **start** date is not one of the shown days — the same rule the
  /// 课表 grid applies. Before this, the column came from `localStart.weekday`,
  /// so a stray event landed in its weekday column of whatever week was on
  /// screen instead of being dropped.
  List<(UiEvent, int)> _placedByDay(
    List<tz.TZDateTime> days,
    List<UiEvent> events,
    UserTime userTime,
    bool Function(UiEvent) include,
  ) {
    final out = <(UiEvent, int)>[];
    for (final e in events) {
      if (!include(e)) continue;
      final dayIndex = _dayIndexOf(days, e, userTime);
      if (dayIndex != null) out.add((e, dayIndex));
    }
    return out;
  }

  /// Column of [e] in the shown week, or null when its local start date is not
  /// one of [days] — such an event must not be drawn at all.
  int? _dayIndexOf(List<tz.TZDateTime> days, UiEvent e, UserTime userTime) {
    final local = _localDayOf(e.startUtc, userTime);
    final idx = days.indexWhere((d) => _isSameLocalDay(d, local));
    return idx >= 0 ? idx : null;
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
    final snapped = _snap(minute);
    // Timeline slots have no period: the sheet defaults to one hour and offers
    // no 「连堂 2 节」 chip.
    final result = await showAppBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _QuickCreateSheet(day: day, startMinute: snapped),
    );
    if (result == null || !mounted) return;
    await _createFromSheet(result, day, snapped);
  }

  /// Empty 课表 cell: the sheet opens on that period's exact start/end, so the
  /// default duration is the period length (45 min) and 「连堂 2 节」 is one tap
  /// away.
  Future<void> _onGridEmptyTap(
    tz.TZDateTime day,
    int startMinute,
    int endMinute,
    int periodNo,
  ) async {
    final periodMinutes = endMinute - startMinute;
    final result = await showAppBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _QuickCreateSheet(
        day: day,
        startMinute: startMinute,
        initialDurationMinutes: periodMinutes > 0 ? periodMinutes : 45,
        periodNo: periodNo,
        showPeriodHint: true,
      ),
    );
    if (result == null || !mounted) return;
    await _createFromSheet(result, day, startMinute);
  }

  /// Shared write path for both empty-slot entry points.
  Future<void> _createFromSheet(
    Map<String, dynamic> result,
    DateTime day,
    int startMinute,
  ) async {
    final title = result['title'] as String? ?? '';
    final duration = (result['durationMinutes'] as num?)?.toInt() ?? 60;
    final todoId = result['todoId'] as String?;
    final alsoDeadline = result['alsoDeadline'] as bool? ?? false;
    final error = await ref.read(calendarControllerProvider.notifier).createQuickBlock(
          day: day,
          startMinute: startMinute,
          durationMinutes: duration,
          title: title,
          todoId: todoId,
          alsoDeadline: alsoDeadline,
        );
    if (error != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('创建失败: ${error.message}')));
    }
  }

  int _snap(int minute) {
    // Default snap: 5 minutes (docs/ui-interaction.md §8). Period snapping is
    // offered in the dedicated editors.
    return (minute / 5).round() * 5;
  }

  Future<void> _commitEventMove(UiEvent event, DateTime newStartUtc, DateTime newEndUtc) async {
    final error = await ref
        .read(calendarControllerProvider.notifier)
        .moveEvent(event: event, startUtc: newStartUtc, endUtc: newEndUtc);
    if (error == null || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(error is NetworkException ? '离线时无法修改课程/周期安排' : '修改失败: ${error.message}')),
    );
  }
}

/// Compact `课表 | 周 | 月` segmented control for the app bar.
///
/// A plain pill rather than [SegmentedButton] so it stays narrow enough for the
/// title to keep its week range on a phone, and so each segment can carry its
/// own tooltip (the switch tests find segments by tooltip).
class _ViewModeSwitch extends StatelessWidget {
  const _ViewModeSwitch({required this.mode, required this.onChanged});

  final WeekViewMode mode;
  final ValueChanged<WeekViewMode> onChanged;

  static const _segments = <WeekViewMode, ({String label, String tooltip})>{
    WeekViewMode.grid: (label: '课表', tooltip: '切到课表视图'),
    WeekViewMode.timeline: (label: '周', tooltip: '切到周视图'),
    WeekViewMode.month: (label: '月', tooltip: '切到月视图'),
  };

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // AppBar actions stretch to the full toolbar height; Center keeps the pill
    // at its compact size.
    return Center(
      child: Material(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in _segments.entries)
                _segment(colors, entry.key, entry.value),
            ],
          ),
        ),
      ),
    );
  }

  Widget _segment(
    ColorScheme colors,
    WeekViewMode value,
    ({String label, String tooltip}) segment,
  ) {
    final selected = value == mode;
    return Tooltip(
      message: segment.tooltip,
      child: InkWell(
        onTap: () => onChanged(value),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: selected ? colors.primary : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Text(
            segment.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? colors.onPrimary : colors.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}

/// The seven weekday headers of the 时间轴 view. The period navigation lives
/// above this row, outside the animated area (see [WeekPage.build]).
class _WeekHeader extends StatelessWidget {
  const _WeekHeader({
    required this.days,
    required this.todayLocal,
  });

  final List<tz.TZDateTime> days;
  final DateTime? todayLocal;

  static const _weekDays = ['一', '二', '三', '四', '五', '六', '日'];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      children: [
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
    required this.dayIndex,
    required this.dayWidth,
    required this.onDragChanged,
    required this.onCommit,
    required this.textLines,
    required this.style,
  });

  final UiEvent event;
  final UserTime userTime;

  /// Column of the shown week this event belongs to. Owned by the parent so an
  /// event from another week can never be placed here.
  final int dayIndex;
  final double dayWidth;
  final ValueChanged<bool> onDragChanged;
  final void Function(DateTime startUtc, DateTime endUtc) onCommit;

  /// Line budget for the title / location (Settings → 外观与界面).
  final ({int title, int location}) textLines;

  /// Opacity / corner radius / gap / text scale of the block.
  final CourseCardStyle style;

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
      left: widget.dayIndex * widget.dayWidth + widget.style.margin,
      top: startMinute / 1440 * (_hourPx * 24),
      width: math.max(widget.dayWidth - 2 * widget.style.margin, 1.0),
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
          textLines: widget.textLines,
          style: widget.style,
          // While dragging, the block dims to mark the ghost as the target.
          dragging: _dragging,
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
    showAppBottomSheet(
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
    required this.textLines,
    required this.style,
    this.dragging = false,
    this.dragOverlay = false,
    this.showHandles = false,
  });

  final UiEvent event;
  final Color color;
  final ({int title, int location}) textLines;
  final CourseCardStyle style;

  /// Whether the source block is being dragged (it dims to 0.35).
  final bool dragging;
  final bool dragOverlay;
  final bool showHandles;

  @override
  Widget build(BuildContext context) {
    final bg = color.withValues(alpha: dragging ? 0.35 : style.opacity);
    final conflict = event.conflict;
    final borderColor = conflict == ConflictState.hard
        ? Colors.red
        : conflict == ConflictState.soft
            ? Colors.orangeAccent
            : Colors.transparent;
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(style.borderRadius),
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
            maxLines: textLines.title,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
                color: Colors.white,
                fontSize: 10.5 * style.fontScale,
                fontWeight: FontWeight.w600),
          ),
          if (event.location != null && event.location!.isNotEmpty)
            Text(event.location!,
                maxLines: textLines.location,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white70,
                    fontSize: 9 * style.fontScale)),
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

/// How the quick-create sheet sources its todo.
enum _QuickCreateMode { newTodo, linkTodo }

/// Bottom sheet: create a todo block in an empty slot (时间轴 or 课表 cell).
///
/// Two modes: a brand-new todo (title typed here) or an existing open todo
/// picked from the mirror. Durations are quick chips rather than a dropdown,
/// so aligning to the tapped period is one tap; when opened from the 课表 grid
/// the default duration is that period's length and 「连堂 2 节」 sits beside it.
class _QuickCreateSheet extends ConsumerStatefulWidget {
  const _QuickCreateSheet({
    required this.day,
    required this.startMinute,
    this.initialDurationMinutes = 60,
    this.periodNo,
    this.showPeriodHint = false,
  });

  final DateTime day;
  final int startMinute;
  final int initialDurationMinutes;

  /// Period whose cell was tapped in the 课表 grid; null from the timeline.
  final int? periodNo;

  /// Adds the period caption and the 「连堂 2 节」 chip (课表 grid only).
  final bool showPeriodHint;

  @override
  ConsumerState<_QuickCreateSheet> createState() => _QuickCreateSheetState();
}

class _QuickCreateSheetState extends ConsumerState<_QuickCreateSheet> {
  static const _chips = <({String key, String label, int minutes})>[
    (key: 'p1', label: '1节课(45m)', minutes: 45),
    (key: 'p2', label: '2节课(90m)', minutes: 90),
    (key: 'h1', label: '1小时', minutes: 60),
    (key: 'h2', label: '2小时', minutes: 120),
  ];

  final _title = TextEditingController();
  late int _duration;
  String? _chipKey;
  _QuickCreateMode _mode = _QuickCreateMode.newTodo;
  String? _todoId;
  bool _alsoDeadline = false;

  @override
  void initState() {
    super.initState();
    _duration =
        widget.initialDurationMinutes > 0 ? widget.initialDurationMinutes : 60;
    for (final c in _chips) {
      if (c.minutes == _duration) {
        _chipKey = c.key;
        break;
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(snapshotProvider).value;
    final todos = <Todo>[
      if (snapshot != null)
        for (final live in liveTodos(snapshot))
          if (!live.value.isCompleted && live.value.status != TodoStatus.cancelled)
            live.value,
    ];
    // A stale id (the todo got completed elsewhere) must not reach the
    // dropdown's item/value assert.
    final selectedTodoId = todos.any((t) => t.id == _todoId) ? _todoId : null;
    final endMinute = widget.startMinute + _duration;
    final crossesMidnight = endMinute > 24 * 60;
    // Crossing midnight hides the range instead of showing a next-day time;
    // the write path keeps its previous behaviour for that case.
    final timeRange =
        crossesMidnight ? null : '${_hhmm(widget.startMinute)} – ${_hhmm(endMinute)}';
    final canCreate =
        _mode == _QuickCreateMode.newTodo || selectedTodoId != null;

    return Padding(
      // Keep the create button above the keyboard while the title is focused.
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.periodNo == null
                  ? '${widget.day.month}月${widget.day.day}日 · 新建时间块'
                  : '${widget.day.month}月${widget.day.day}日 · 第 ${widget.periodNo} 节',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            if (timeRange != null)
              Text(timeRange,
                  style: const TextStyle(fontSize: 13, color: Colors.black54)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                ChoiceChip(
                  label: const Text('新建待办时间块'),
                  selected: _mode == _QuickCreateMode.newTodo,
                  onSelected: (_) =>
                      setState(() => _mode = _QuickCreateMode.newTodo),
                ),
                ChoiceChip(
                  label: const Text('关联已有待办'),
                  selected: _mode == _QuickCreateMode.linkTodo,
                  onSelected: (_) =>
                      setState(() => _mode = _QuickCreateMode.linkTodo),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (_mode == _QuickCreateMode.newTodo)
              TextField(
                controller: _title,
                autofocus: true,
                decoration: const InputDecoration(labelText: '做什么？（留空则只安排时间块）'),
              )
            else if (todos.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('先去待办页新建', style: TextStyle(color: Colors.grey)),
              )
            else
              DropdownButtonFormField<String>(
                initialValue: selectedTodoId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '选择待办'),
                items: [
                  for (final t in todos)
                    DropdownMenuItem(
                      value: t.id,
                      child: Text(t.title,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                ],
                onChanged: (v) => setState(() => _todoId = v),
              ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final c in _chips) _durationChip(c),
                // Same 90 minutes as 「2节课(90m)」, worded for a double period.
                if (widget.showPeriodHint)
                  ChoiceChip(
                    label: const Text('连堂 2 节'),
                    selected: _chipKey == 'conn',
                    onSelected: (_) => setState(() {
                      _chipKey = 'conn';
                      _duration = 90;
                    }),
                  ),
              ],
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('同时将该时间设为截止时间'),
              value: _alsoDeadline,
              onChanged: (v) => setState(() => _alsoDeadline = v ?? false),
            ),
            const SizedBox(height: 6),
            FilledButton(
              onPressed: canCreate ? () => _submit(selectedTodoId) : null,
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _durationChip(({String key, String label, int minutes}) chip) {
    return ChoiceChip(
      label: Text(chip.label),
      selected: _chipKey == chip.key,
      onSelected: (_) => setState(() {
        _chipKey = chip.key;
        _duration = chip.minutes;
      }),
    );
  }

  void _submit(String? selectedTodoId) {
    Navigator.of(context).pop(<String, dynamic>{
      'title': _mode == _QuickCreateMode.newTodo ? _title.text.trim() : '',
      'durationMinutes': _duration,
      'todoId': _mode == _QuickCreateMode.linkTodo ? selectedTodoId : null,
      'alsoDeadline': _alsoDeadline,
    });
  }

  static String _hhmm(int minute) =>
      DateFormat('HH:mm').format(DateTime(2000, 1, 1, (minute ~/ 60) % 24, minute % 60));
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
    final error = await ref
        .read(calendarControllerProvider.notifier)
        .moveEvent(event: event, startUtc: s.toUtc(), endUtc: e.toUtc());
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error is NetworkException ? '离线时无法修改，请联网后重试' : error.message)));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    if (event.type == EventType.deadline) return;
    Navigator.of(context).pop();
    final error = await ref.read(calendarControllerProvider.notifier).deleteEvent(event);
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
