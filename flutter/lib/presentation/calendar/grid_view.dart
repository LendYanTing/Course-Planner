import 'package:flutter/material.dart';
import 'package:timezone/timezone.dart' as tz;

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../data/local/entities_snapshot.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/calendar_event.dart';
import 'event_projection.dart';

/// Grid (纯课表) view — spec docs/grid-view-web.md.
///
/// Rows = the active semester's period templates (sorted by start time,
/// deduplicated on equal starts); 7 weekday columns, no continuous time axis.
/// Events are clipped/merged onto the rows they touch (≥45-min gaps split a
/// tile), morning/afternoon are separated with a divider, weekend columns are
/// tinted, and the now/deadline markers are pinned to row boundaries.
///
/// Todo blocks are always draggable/resizable; course & recurring-schedule
/// tiles only when the toolbar switch is on (single occurrence edits pushed
/// through the parent commit callback — server series apply).
class GridViewContent extends StatefulWidget {
  const GridViewContent({
    super.key,
    required this.userTime,
    required this.days,
    required this.events,
    required this.snapshot,
    required this.nowUtc,
    required this.onCommitMove,
  });

  final UserTime userTime;

  /// The seven displayed local days (Monday-first).
  final List<tz.TZDateTime> days;
  final List<UiEvent> events;
  final EntitiesSnapshot? snapshot;
  final DateTime? nowUtc;

  /// Commits a move/resize of a single event (block local-first; course /
  /// recurring occurrence via server series apply).
  final void Function(UiEvent event, DateTime startUtc, DateTime endUtc) onCommitMove;

  static const double rowHeight = 54;
  static const double leftWidth = 64;
  static const int splitGapMinutes = 45;

  @override
  State<GridViewContent> createState() => _GridViewContentState();
}

class _PeriodRow {
  const _PeriodRow({required this.periodNo, required this.start, required this.end});
  final int periodNo;
  final int start;
  final int end;
  int get duration => end - start;
}

/// One clip segment of an event over the row area.
class _EventRun {
  const _EventRun({required this.top, required this.bottom, required this.day});
  final double top;
  final double bottom;
  final int day;
  double get height => bottom - top;
}

class _GridLayout {
  _GridLayout(this.rows) {
    _tops = [for (var i = 0; i < rows.length; i++) i * GridViewContent.rowHeight];
    starts = rows.map((r) => r.start).toSet().toList()..sort();
    ends = rows.map((r) => r.end).toSet().toList()..sort();
  }

  final List<_PeriodRow> rows;
  late final List<double> _tops;
  late final List<int> starts;
  late final List<int> ends;

  int get count => rows.length;
  double get height => rows.length * GridViewContent.rowHeight;

  double yForMinute(int minute) {
    if (rows.isEmpty) return 0;
    if (minute < rows.first.start) return 0;
    if (minute >= rows.last.end) return height;
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (minute < r.start) return _tops[i];
      if (minute < r.end) {
        return _tops[i] + (minute - r.start) / r.duration * GridViewContent.rowHeight;
      }
    }
    return height;
  }

  int minuteAtY(double y) {
    if (rows.isEmpty) return 0;
    final clamped = y.clamp(0.0, height);
    final idx = (clamped / GridViewContent.rowHeight).floor().clamp(0, rows.length - 1);
    final r = rows[idx];
    final frac = (clamped - _tops[idx]) / GridViewContent.rowHeight;
    return (r.start + frac * r.duration).round();
  }

  List<_EventRun> runsFor(int day, int start, int end) {
    final covered = <int>[];
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (start < r.end && end > r.start) covered.add(i);
    }
    if (covered.isEmpty) return const [];
    final runs = <_EventRun>[];
    var run = <int>[covered.first];
    void flush() {
      final first = run.first;
      final last = run.last;
      final r0 = rows[first];
      final r1 = rows[last];
      final top = run.length == 1
          ? (_tops[first] +
              (start - r0.start) / r0.duration * GridViewContent.rowHeight)
              .clamp(_tops[first], _tops[first] + GridViewContent.rowHeight)
          : (start <= r0.start
              ? _tops[first]
              : _tops[first] +
                  (start - r0.start) / r0.duration * GridViewContent.rowHeight);
      final bottom = run.length == 1
          ? (_tops[first] +
              (end - r0.start) / r0.duration * GridViewContent.rowHeight)
              .clamp(_tops[first], _tops[first] + GridViewContent.rowHeight)
          : (end >= r1.end
              ? _tops[last] + GridViewContent.rowHeight
              : _tops[last] + (end - r1.start) / r1.duration * GridViewContent.rowHeight);
      runs.add(_EventRun(top: top.toDouble(), bottom: bottom.toDouble(), day: day));
    }

    for (final idx in covered.skip(1)) {
      final gap = rows[idx].start - rows[run.last].end;
      if (idx > run.last + 1 || gap >= GridViewContent.splitGapMinutes) {
        flush();
        run = [idx];
      } else {
        run.add(idx);
      }
    }
    flush();
    return runs;
  }
}

class _GridViewContentState extends State<GridViewContent> {
  bool _courseEditable = false;
  bool _gridDragging = false;
  String? _calendarId;

  @override
  Widget build(BuildContext context) {
    final snap = widget.snapshot;
    if (snap == null) return const Center(child: CircularProgressIndicator());
    final calendars = liveCalendars(snap).map((e) => e.value).toList();
    final periods = livePeriods(snap).map((e) => e.value).toList();
    final usable =
        calendars.where((c) => periods.any((p) => p.calendarId == c.id)).toList();
    if (usable.isEmpty) {
      return const Center(child: Text('暂无学期节次模板（设置 → 学期管理）'));
    }
    if (_calendarId == null || !usable.any((c) => c.id == _calendarId)) {
      _calendarId = usable.first.id;
    }
    final rows = _rowsFor(periods.where((p) => p.calendarId == _calendarId).toList());
    if (rows.isEmpty) {
      return Center(
        child: Text('学期「${usable.firstWhere((c) => c.id == _calendarId).name}」还没有节次'),
      );
    }
    final nowLocal =
        widget.nowUtc == null ? null : widget.userTime.localFromUtc(widget.nowUtc!);
    final todayVisible = nowLocal != null &&
        widget.days.any((d) => d.year == nowLocal.year &&
            d.month == nowLocal.month &&
            d.day == nowLocal.day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(usable),
        _weekHeader(nowLocal),
        Expanded(
          child: LayoutBuilder(builder: (context, constraints) {
            final dayWidth = (constraints.maxWidth - GridViewContent.leftWidth) / 7;
            final layout = _GridLayout(rows);
            return ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(dragDevices: {}),
              child: SingleChildScrollView(
                physics: _gridDragging
                    ? const NeverScrollableScrollPhysics()
                    : const AlwaysScrollableScrollPhysics(),
                child: SizedBox(
                  width: constraints.maxWidth,
                  height: layout.height,
                  child: _GridCanvas(
                    userTime: widget.userTime,
                    days: widget.days,
                    events: widget.events,
                    layout: layout,
                    dayWidth: dayWidth,
                    courseEditable: _courseEditable,
                    nowLocal: todayVisible ? nowLocal : null,
                    onCommitMove: widget.onCommitMove,
                    onDragChanged: (v) => setState(() => _gridDragging = v),
                    onMessage: (m) {
                      if (mounted) {
                        ScaffoldMessenger.of(context)
                            .showSnackBar(SnackBar(content: Text(m)));
                      }
                    },
                  ),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  static List<_PeriodRow> _rowsFor(List<PeriodTemplate> periods) {
    final sorted = [...periods]..sort((a, b) {
        final c = a.startMinute.compareTo(b.startMinute);
        return c != 0 ? c : a.periodNo.compareTo(b.periodNo);
      });
    final seen = <int>{};
    final out = <_PeriodRow>[];
    for (final p in sorted) {
      if (!seen.add(p.startMinute)) continue;
      out.add(_PeriodRow(periodNo: p.periodNo, start: p.startMinute, end: p.endMinute));
    }
    return out;
  }

  Widget _toolbar(List<AcademicCalendar> usable) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 8, 0),
      child: Row(
        children: [
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _calendarId,
              isDense: true,
              items: [
                for (final c in usable)
                  DropdownMenuItem(value: c.id, child: Text(c.name, style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) => setState(() => _calendarId = v),
            ),
          ),
          const Spacer(),
          const Text('课程可拖动', style: TextStyle(fontSize: 12)),
          Switch(
            value: _courseEditable,
            onChanged: (v) => setState(() => _courseEditable = v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ],
      ),
    );
  }

  Widget _weekHeader(DateTime? nowLocal) {
    const labels = ['一', '二', '三', '四', '五', '六', '日'];
    final colors = Theme.of(context).colorScheme;
    return Row(
      children: [
        const SizedBox(width: GridViewContent.leftWidth),
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Column(
                children: [
                  Text('周${labels[i]}', style: TextStyle(fontSize: 11, color: colors.outline)),
                  const SizedBox(height: 1),
                  Container(
                    width: 20,
                    height: 20,
                    alignment: Alignment.center,
                    decoration: _isToday(i, nowLocal)
                        ? BoxDecoration(color: colors.primary, shape: BoxShape.circle)
                        : null,
                    child: Text(
                      '${widget.days[i].day}',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        color: _isToday(i, nowLocal) ? Colors.white : colors.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  bool _isToday(int i, DateTime? nowLocal) {
    final d = widget.days[i];
    return nowLocal != null &&
        d.year == nowLocal.year &&
        d.month == nowLocal.month &&
        d.day == nowLocal.day;
  }
}

/// Positioned, lane-resolved tile of one event.
class _Placed {
  _Placed(this.event, this.run, this.day, this.lane, this.laneCount);
  final UiEvent event;
  final _EventRun run;
  final int day;
  final int lane;
  final int laneCount;
}

class _GridCanvas extends StatefulWidget {
  const _GridCanvas({
    required this.userTime,
    required this.days,
    required this.events,
    required this.layout,
    required this.dayWidth,
    required this.courseEditable,
    required this.nowLocal,
    required this.onCommitMove,
    required this.onDragChanged,
    required this.onMessage,
  });

  final UserTime userTime;
  final List<tz.TZDateTime> days;
  final List<UiEvent> events;
  final _GridLayout layout;
  final double dayWidth;
  final bool courseEditable;
  final DateTime? nowLocal;
  final void Function(UiEvent, DateTime, DateTime) onCommitMove;
  final ValueChanged<bool> onDragChanged;
  final ValueChanged<String> onMessage;

  @override
  State<_GridCanvas> createState() => _GridCanvasState();
}

class _GridCanvasState extends State<_GridCanvas> {
  final _canvasKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final layout = widget.layout;
    final colors = Theme.of(context).colorScheme;
    var pmStart = -1;
    for (var i = 0; i < layout.rows.length; i++) {
      if (layout.rows[i].start >= 12 * 60) {
        pmStart = i;
        break;
      }
    }
    final placed = _place(layout);

    return Container(
      key: _canvasKey,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (var i = 0; i < layout.rows.length; i++)
            Positioned(
              top: i * GridViewContent.rowHeight,
              left: 0,
              right: 0,
              height: GridViewContent.rowHeight,
              child: Container(
                color: pmStart < 0 || i < pmStart
                    ? const Color(0xFFEDF4FF)
                    : const Color(0xFFFFF2E4),
              ),
            ),
          for (var d = 5; d < 7; d++)
            Positioned(
              top: 0,
              left: GridViewContent.leftWidth + d * widget.dayWidth,
              width: widget.dayWidth,
              height: layout.height,
              child: Container(color: Colors.black.withValues(alpha: 0.03)),
            ),
          // row lines + left period gutter
          for (var i = 0; i < layout.rows.length; i++)
            Positioned(
              top: i * GridViewContent.rowHeight,
              left: 0,
              right: 0,
              height: GridViewContent.rowHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: GridViewContent.leftWidth,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        right: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
                        bottom: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
                      ),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '${layout.rows[i].periodNo}',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.bold,
                            color: pmStart >= 0 && i >= pmStart
                                ? const Color(0xFFE07B39)
                                : const Color(0xFF3A6FB0),
                          ),
                        ),
                        Text(
                          _hhmm(layout.rows[i].start),
                          style: const TextStyle(fontSize: 9, color: Colors.black45),
                        ),
                      ],
                    ),
                  ),
                  for (var d = 0; d < 7; d++)
                    Container(
                      width: widget.dayWidth,
                      decoration: BoxDecoration(
                        border: Border(
                          right: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
                          bottom: BorderSide(color: colors.outlineVariant.withValues(alpha: 0.7)),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          if (pmStart > 0) _pmDivider(pmStart),
          // tiles
          for (final p in placed)
            _GridTile(
              key: ValueKey('${p.event.id}:${p.run.top}'),
              event: p.event,
              placed: p,
              editable: _editable(p.event),
              userTime: widget.userTime,
              days: widget.days,
              layout: layout,
              canvasKey: _canvasKey,
              dayWidth: widget.dayWidth,
              onCommit: (ev, s, e) => widget.onCommitMove(ev, s, e),
              onDragChanged: widget.onDragChanged,
              onMessage: widget.onMessage,
            ),
          for (final e in widget.events)
            if (e.type == EventType.deadline) _deadline(e),
          if (widget.nowLocal != null) _nowLine(widget.nowLocal!, layout),
        ],
      ),
    );
  }

  bool _editable(UiEvent e) {
    switch (e.type) {
      case EventType.todoBlock:
        return true;
      case EventType.course:
      case EventType.recurringSchedule:
        return widget.courseEditable;
      case EventType.deadline:
        return false;
    }
  }

  /// Places every span event onto its day(s) with simple per-day lane
  /// interval colouring over the row-clipped segments.
  List<_Placed> _place(_GridLayout layout) {
    final placed = <_Placed>[];
    for (var day = 0; day < widget.days.length; day++) {
      final dayDate = widget.days[day];
      final segs = <({UiEvent event, _EventRun run, double top, double bottom})>[];
      for (final e in widget.events) {
        if (e.type == EventType.deadline) continue;
        final ls = widget.userTime.localFromUtc(e.startUtc);
        if (!(ls.year == dayDate.year && ls.month == dayDate.month && ls.day == dayDate.day)) {
          continue;
        }
        final le = widget.userTime.localFromUtc(e.endUtc);
        final runs = layout.runsFor(day, ls.hour * 60 + ls.minute, le.hour * 60 + le.minute);
        for (final run in runs) {
          segs.add((event: e, run: run, top: run.top, bottom: run.bottom));
        }
      }
      segs.sort((a, b) => a.top.compareTo(b.top));
      final laneEnd = <double>[];
      final laneOf = <Object, int>{};
      for (final s in segs) {
        var lane = -1;
        for (var i = 0; i < laneEnd.length; i++) {
          if (laneEnd[i] <= s.top + 0.5) {
            lane = i;
            break;
          }
        }
        if (lane < 0) {
          lane = laneEnd.length;
          laneEnd.add(0);
        }
        laneEnd[lane] = s.bottom;
        laneOf[s] = lane;
      }
      final laneCount = laneEnd.isEmpty ? 1 : laneEnd.length;
      for (final s in segs) {
        placed.add(_Placed(s.event, s.run, day, laneOf[s]!, laneCount));
      }
    }
    placed.sort((a, b) {
      int rank(UiEvent e) => e.type == EventType.todoBlock ? 1 : 0;
      final c = rank(a.event).compareTo(rank(b.event));
      return c != 0 ? c : a.run.top.compareTo(b.run.top);
    });
    return placed;
  }

  Widget _nowLine(DateTime local, _GridLayout layout) {
    final y = layout.yForMinute(local.hour * 60 + local.minute);
    return Positioned(
      top: y - 1,
      left: 0,
      width: GridViewContent.leftWidth + 7 * widget.dayWidth,
      height: 2,
      child: Row(children: [
        SizedBox(
          width: GridViewContent.leftWidth,
          child: Text(
            '现在 ${_hhmm(local.hour * 60 + local.minute)}',
            textAlign: TextAlign.right,
            style: const TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: AppTheme.nowLineColor,
            ),
          ),
        ),
        Container(width: 7 * widget.dayWidth, height: 2, color: AppTheme.nowLineColor),
      ]),
    );
  }

  Widget _deadline(UiEvent e) {
    final local = widget.userTime.localFromUtc(e.startUtc);
    var day = -1;
    for (var i = 0; i < widget.days.length; i++) {
      final d = widget.days[i];
      if (d.year == local.year && d.month == local.month && d.day == local.day) {
        day = i;
        break;
      }
    }
    if (day < 0) return const SizedBox.shrink();
    final minute = local.hour * 60 + local.minute;
    final y = widget.layout.yForMinute(minute);
    return Positioned(
      top: (y - 9).clamp(0.0, widget.layout.height - 18),
      left: GridViewContent.leftWidth + day * widget.dayWidth + 2,
      width: widget.dayWidth - 4,
      height: 18,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        alignment: Alignment.centerLeft,
        decoration: BoxDecoration(
          color: const Color(0xFFFFEBEE),
          border: Border.all(color: AppTheme.deadlineColor),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${e.title} · ${_hhmm(minute)}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 8.5,
            fontWeight: FontWeight.w600,
            color: AppTheme.deadlineColor,
          ),
        ),
      ),
    );
  }

  Widget _pmDivider(int pmStart) {
    const label = '上午 AM · 下午 PM';
    return Stack(children: [
      Positioned(
        top: pmStart * GridViewContent.rowHeight,
        left: GridViewContent.leftWidth,
        width: 7 * widget.dayWidth,
        height: 2,
        child: Container(color: Colors.black.withValues(alpha: 0.35)),
      ),
      Positioned(
        top: (pmStart * GridViewContent.rowHeight - 12).clamp(0.0, double.infinity),
        left: 0,
        width: GridViewContent.leftWidth + 7 * widget.dayWidth,
        child: IgnorePointer(
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Colors.black26),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(label, style: const TextStyle(fontSize: 10, color: Colors.black54)),
            ),
          ),
        ),
      ),
    ]);
  }

  static String _hhmm(int minute) => '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';
}


/// One event tile on the grid canvas.
///
/// Drag semantics follow docs/grid-view-web.md §4: todo blocks are always
/// editable; course/recurring tiles only when the course switch is on. Body
/// drag moves the occurrence (can change weekday for todo blocks), top/bottom
/// edge drag resizes and snaps to 上课/下课 times. All local-time arithmetic
/// happens in the user's fixed timezone.
class _GridTile extends StatefulWidget {
  const _GridTile({
    super.key,
    required this.event,
    required this.placed,
    required this.editable,
    required this.userTime,
    required this.days,
    required this.layout,
    required this.canvasKey,
    required this.dayWidth,
    required this.onCommit,
    required this.onDragChanged,
    required this.onMessage,
  });

  final UiEvent event;
  final _Placed placed;
  final bool editable;
  final UserTime userTime;
  final List<tz.TZDateTime> days;
  final _GridLayout layout;
  final GlobalKey canvasKey;
  final double dayWidth;
  final void Function(UiEvent, DateTime, DateTime) onCommit;
  final ValueChanged<bool> onDragChanged;
  final ValueChanged<String> onMessage;

  @override
  State<_GridTile> createState() => _GridTileState();
}

class _GridTileState extends State<_GridTile> {
  bool _dragging = false;
  int _mode = 0; // 0 body, 1 top resize, 2 bottom resize
  late int _origStart;
  late int _origEnd;
  late int _origDay;
  int? _candStart;
  int? _candEnd;
  int? _candDay;
  RenderBox? _canvasBox;

  @override
  Widget build(BuildContext context) {
    final p = widget.placed;
    final laneW = (widget.dayWidth - 3) / p.laneCount;
    final left = GridViewContent.leftWidth +
        p.day * widget.dayWidth +
        1 +
        p.lane * laneW;
    final color = _colorFor(widget.event);
    final conflict = widget.event.conflict;

    return Positioned(
      left: left,
      top: p.run.top,
      width: laneW - 1,
      height: p.run.height,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _openInfo(),
        onPanStart: widget.editable ? _onPanStart : null,
        onPanUpdate: widget.editable ? _onPanUpdate : null,
        onPanEnd: widget.editable ? (_) => _finish() : null,
        onPanCancel: widget.editable ? _finish : null,
        child: Container(
          decoration: BoxDecoration(
            color: _dragging
                ? color.withValues(alpha: 0.45)
                : color.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: conflict == ConflictState.hard
                  ? Colors.red
                  : conflict == ConflictState.soft
                      ? Colors.orangeAccent
                      : Colors.transparent,
              width: conflict == ConflictState.none ? 0 : 1.5,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Stack(children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(widget.event.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600)),
                if (widget.event.location != null && widget.event.location!.isNotEmpty)
                  Text(widget.event.location!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white70, fontSize: 9)),
              ],
            ),
            if (widget.editable) ...[
              Positioned(left: 0, right: 0, top: 0, height: 5,
                  child: _handle(color, 1)),
              Positioned(left: 0, right: 0, bottom: 0, height: 5,
                  child: _handle(color, 2)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _handle(Color base, int mode) => Container(
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.25),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Center(
          child: Container(width: 14, height: 2, color: Colors.white.withValues(alpha: 0.7)),
        ),
      );

  Color _colorFor(UiEvent e) => AppTheme.parseHex(e.color) ??
      switch (e.type) {
        EventType.course => AppTheme.courseColor,
        EventType.recurringSchedule => AppTheme.scheduleColor,
        EventType.todoBlock => AppTheme.blockColor,
        EventType.deadline => AppTheme.deadlineColor,
      };

  void _openInfo() {
    final e = widget.event;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(e.title),
        content: Text([
          if (e.type == EventType.todoBlock) '待办时间块',
          if (e.location != null && e.location!.isNotEmpty) e.location!,
          if (e.teacher != null && e.teacher!.isNotEmpty) e.teacher!,
          if (e.note != null && e.note!.isNotEmpty) e.note!,
        ].join(' · ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
  }

  // ---- drag / resize -------------------------------------------------------

  void _onPanStart(DragStartDetails details) {
    final size = context.size;
    if (size == null) return;
    final dyLocal = details.localPosition.dy;
    _mode = dyLocal < 6 ? 1 : (dyLocal > size.height - 6 ? 2 : 0);
    if (_mode != 0 && widget.event.type == EventType.deadline) _mode = 0;

    final ls = widget.userTime.localFromUtc(widget.event.startUtc);
    final le = widget.userTime.localFromUtc(widget.event.endUtc);
    _origStart = ls.hour * 60 + ls.minute;
    _origEnd = le.hour * 60 + le.minute;
    _origDay = ls.weekday - 1;
    _candStart = null;
    _candEnd = null;
    _candDay = null;
    _canvasBox = widget.canvasKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() => _dragging = true);
    widget.onDragChanged(true);
  }

  void _onPanUpdate(DragUpdateDetails details) {
    if (!_dragging) return;
    final box = _canvasBox;
    if (box == null) return;
    final point = box.globalToLocal(details.globalPosition);
    final yMin = widget.layout.minuteAtY(point.dy.clamp(0.0, widget.layout.height));
    final xDay = ((point.dx - GridViewContent.leftWidth) / widget.dayWidth)
        .floor()
        .clamp(0, 6);

    int day;
    int newStart;
    int newEnd;
    if (_mode == 0) {
      // body move: duration preserved, tile start follows the pointer
      day = xDay;
      final dur = _origEnd - _origStart;
      var start = _snap5(yMin);
      var end = start + dur;
      if (end > 24 * 60) {
        end = 24 * 60;
        start = (end - dur).clamp(0, 24 * 60 - 15);
      }
      if (start < 0) {
        start = 0;
        end = dur < 15 ? 15 : dur;
      }
      newStart = start;
      newEnd = end;
    } else {
      day = _origDay;
      if (_mode == 1) {
        final snapped = _snapNearest(yMin, widget.layout.starts);
        newEnd = _origEnd;
        newStart = (snapped).clamp(0, newEnd - 15);
      } else {
        final snapped = _snapNearest(yMin, widget.layout.ends);
        newStart = _origStart;
        newEnd = snapped.clamp(newStart + 15, 24 * 60);
      }
    }
    if (newStart >= newEnd) return;
    setState(() {
      _candStart = newStart;
      _candEnd = newEnd;
      _candDay = day;
    });
  }

  int _snap5(int minute) => _snapStep(minute, 5);

  int _snapStep(int minute, int step) {
    final q = (minute / step).round();
    return (q * step).clamp(0, 24 * 60);
  }

  int _snapNearest(int minute, List<int> targets) {
    if (targets.isEmpty) return minute.clamp(0, 24 * 60);
    var best = targets.first;
    var dist = (best - minute).abs();
    for (final t in targets.skip(1)) {
      final d = (t - minute).abs();
      if (d < dist) {
        best = t;
        dist = d;
      }
    }
    return best;
  }

  void _finish() {
    if (!_dragging) return;
    final start = _candStart;
    final end = _candEnd;
    final day = _candDay ?? _origDay;
    setState(() {
      _dragging = false;
      _candStart = null;
      _candEnd = null;
      _candDay = null;
    });
    _canvasBox = null;
    widget.onDragChanged(false);
    if (start == null || end == null) return;
    final date = widget.days[day];
    final userTime = widget.userTime;
    final ns = userTime.fromLocalParts(
        date.year, date.month, date.day, start ~/ 60, start % 60);
    final ne = userTime.fromLocalParts(
        date.year, date.month, date.day, end ~/ 60, end % 60);
    if (!userTime.sameLocalDay(ns, ne)) {
      widget.onMessage('时间块不能跨午夜');
      return;
    }
    final origStartUtc = widget.event.startUtc;
    final origEndUtc = widget.event.endUtc;
    if (ns.toUtc().isAtSameMomentAs(origStartUtc) &&
        ne.toUtc().isAtSameMomentAs(origEndUtc)) {
      return;
    }
    widget.onCommit(widget.event, ns.toUtc(), ne.toUtc());
  }
}