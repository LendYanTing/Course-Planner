import '../core/time/user_time.dart';
import '../core/util/clock_utils.dart';
import '../core/util/json_utils.dart';
import '../core/util/week_text.dart';
import '../data/local/entities_snapshot.dart';
import '../data/local/sync_store.dart';
import '../data/local/view_models.dart';
import '../data/repo/entity_repo.dart';
import '../domain/calendar.dart';
import '../domain/calendar_event.dart';
import '../domain/course.dart';
import '../domain/entities.dart';
import '../domain/free_slot_finder.dart';
import '../domain/local_series_service.dart';
import '../domain/override.dart';
import '../domain/schedule.dart';
import '../domain/todo.dart';
import '../domain/week_rule.dart';
import '../state/event_projection.dart';
import '../sync/expander.dart';

/// One human-readable entry of a pending agent change set
/// (docs/agent-behavior.md §Confirmation).
class LocalChangeItem {
  const LocalChangeItem({
    required this.kind,
    required this.summary,
    this.conflictWarning,
    this.payload = const {},
  });

  /// Change kind, e.g. `create_todo`, `update_todo`, `create_todo_block`,
  /// `move_course_occurrence`.
  final String kind;

  /// Chinese one-line description shown on the confirmation card, e.g.
  /// `+ 周二(11/27) 15:00-16:30 [时间块] 生化大作业：查阅文献`.
  final String summary;

  /// Soft warning (never a blocker), e.g. `⚠️ 与课程「高等数学」时间冲突`.
  final String? conflictWarning;

  /// Normalised values the apply step needs (local timestamps already parsed
  /// to UTC strings).
  final Map<String, dynamic> payload;
}

/// All writes produced by one user request, confirmed in one card and applied
/// in one SQLite transaction (docs/agent-behavior.md §Confirmation).
class LocalChangeSet {
  const LocalChangeSet({required this.items, required this.createdAt});

  final List<LocalChangeItem> items;
  final DateTime createdAt;

  int get length => items.length;

  bool get hasConflicts => items.any((i) => i.conflictWarning != null);
}

/// In-process MCP-equivalent tool surface for the built-in agent
/// (docs/plans/v1/phase-5-builtin-agent.md Step 2).
///
/// Reads run against the offline mirror and never ask for confirmation. Every
/// write is collected by `propose_changes` into a [LocalChangeSet]; only
/// [applyPendingChangeSet] touches `EntityRepo`, inside a single transaction.
class LocalAgentTools {
  LocalAgentTools({
    required this.repo,
    required this.store,
    required this.userTime,
  });

  final EntityRepo repo;
  final SyncStore store;
  final UserTime userTime;

  LocalChangeSet? _pending;
  int _refCounter = 0;

  /// The most recent `propose_changes` result; null when nothing is awaiting
  /// confirmation.
  LocalChangeSet? get pendingChangeSet => _pending;

  /// OpenAI `tools` schema (each entry is `{"type":"function", ...}`).
  List<Map<String, dynamic>> get toolSchemas => _schemas;

  /// Current local mirror (canonical rows + queued ops + conflicts).
  Future<EntitiesSnapshot> snapshot() async => EntitiesSnapshot(
    rows: await store.allEntities(),
    pendingOps: await store.pendingOps(),
    conflicts: await store.conflicts(),
  );

  /// Executes one tool call. Read tools return directly JSON-encodable maps;
  /// `propose_changes` only stages a change set. Any validation failure is
  /// returned as `{"error": "..."}` and never mutates the database.
  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> arguments,
  ) async {
    try {
      switch (name) {
        case 'get_current_time':
          return await _getCurrentTime();
        case 'get_calendar':
          return await _getCalendar();
        case 'get_courses':
          return await _getCourses(arguments);
        case 'get_schedule':
          return await _getSchedule(arguments);
        case 'get_todos':
          return await _getTodos(arguments);
        case 'get_free_slots':
          return await _getFreeSlots(arguments);
        case 'get_tags_and_categories':
          return await _getTagsAndCategories();
        case 'propose_changes':
          return await _proposeChanges(arguments);
        default:
          return {'error': '未知工具：$name'};
      }
    } on _ToolError catch (e) {
      return {'error': e.message};
    } on Object catch (e) {
      return {'error': '工具执行失败：$e'};
    }
  }

  /// Applies the pending change set atomically. A failure rolls the whole set
  /// back and keeps it pending so the user can retry or discard it.
  Future<void> applyPendingChangeSet() async {
    final pending = _pending;
    if (pending == null) return;
    final createdTodoIds = <String, String>{};
    await repo.db.transaction(() async {
      for (final item in pending.items) {
        await _applyItem(item, createdTodoIds);
      }
    });
    _pending = null;
  }

  void discardPendingChangeSet() {
    _pending = null;
  }

  // ---- read tools -----------------------------------------------------------

  Future<Map<String, dynamic>> _getCurrentTime() async {
    final nowUtc = await _nowUtc();
    final local = userTime.localFromUtc(nowUtc);
    final snap = await snapshot();
    final semester = _activeSemester(snap, local);
    final week = semester == null
        ? 0
        : EventExpander(
            userTime,
          ).weekOf(semester.firstDay, userTime.localDateString(local));
    final weekValid =
        semester != null && week >= 1 && week <= semester.totalWeeks;
    return {
      'utc': formatUtc(nowUtc),
      'localDateTime': userTime.formatDateYmdHm(nowUtc),
      'dateLocal': userTime.localDateString(local),
      'weekday': _weekdays[local.weekday - 1],
      'weekdayIndex': local.weekday,
      'timezone': userTime.ianaName,
      'semester': semester == null
          ? null
          : {
              'id': semester.id,
              'name': semester.name,
              'firstDay': semester.firstDay,
              'totalWeeks': semester.totalWeeks,
              'currentWeek': weekValid ? week : null,
              'currentWeekLabel': week < 1
                  ? '未开学'
                  : week > semester.totalWeeks
                  ? '学期已结束'
                  : '第 $week 周',
            },
    };
  }

  Future<Map<String, dynamic>> _getCalendar() async {
    final snap = await snapshot();
    final calendars = liveCalendars(snap).map((e) => e.value).toList()
      ..sort((a, b) => a.firstDay.compareTo(b.firstDay));
    final periods = livePeriods(snap).map((e) => e.value).toList();
    final active = _activeSemester(
      snap,
      userTime.localFromUtc(await _nowUtc()),
    );
    return {
      'timezone': userTime.ianaName,
      'activeCalendarId': active?.id,
      'calendars': [
        for (final c in calendars)
          {
            'id': c.id,
            'name': c.name,
            'firstDay': c.firstDay,
            'totalWeeks': c.totalWeeks,
            'periods': [
              for (final p in periods.where((p) => p.calendarId == c.id))
                {
                  'periodNo': p.periodNo,
                  'startLocal': p.startLocal,
                  'endLocal': p.endLocal,
                },
            ],
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _getCourses(Map<String, dynamic> args) async {
    final calendarId = _optionalString(args['calendarId'], 'calendarId');
    final snap = await snapshot();
    final calendars = {
      for (final e in liveCalendars(snap)) e.value.id: e.value,
    };
    final periods = livePeriods(snap).map((e) => e.value).toList();
    final courses = liveCourses(
      snap,
      calendarId: calendarId,
    ).map((e) => e.value).toList();
    final meetingsByCourse = <String, List<CourseMeeting>>{};
    for (final e in liveMeetings(snap)) {
      meetingsByCourse.putIfAbsent(e.value.courseId, () => []).add(e.value);
    }
    final out = <Map<String, dynamic>>[];
    for (final course in courses) {
      final calendar = calendars[course.calendarId];
      final meetings = meetingsByCourse[course.id] ?? const <CourseMeeting>[];
      out.add({
        'id': course.id,
        'calendarId': course.calendarId,
        'name': course.name,
        'teacher': course.teacher,
        'location': course.location,
        'color': course.color,
        'notes': course.notes,
        'meetings': [
          for (final m in meetings)
            _meetingJson(m, calendar: calendar, periods: periods),
        ],
      });
    }
    return {'courses': out};
  }

  Future<Map<String, dynamic>> _getSchedule(Map<String, dynamic> args) async {
    final range = _readRange(args, defaultDays: 7);
    final snap = await snapshot();
    final events = EventProjection(
      EventExpander(userTime),
    ).project(snap, startUtc: range.startUtc, endUtc: range.endUtc).events;
    return {
      'timezone': userTime.ianaName,
      'fromUtc': formatUtc(range.startUtc),
      'toUtc': formatUtc(range.endUtc),
      'events': [for (final e in events) _eventJson(e)],
    };
  }

  Future<Map<String, dynamic>> _getTodos(Map<String, dynamic> args) async {
    const statuses = ['todo', 'in_progress', 'completed', 'cancelled'];
    const types = ['one_off', 'project'];
    final status = _optionalEnum(args['status'], statuses, 'status');
    final type = _optionalEnum(args['type'], types, 'type');
    final categoryId = _optionalString(args['categoryId'], 'categoryId');
    final query = _optionalString(args['query'], 'query')?.toLowerCase();

    final snap = await snapshot();
    final blocksByTodo = <String, List<TodoBlock>>{};
    for (final e in liveBlocks(snap)) {
      blocksByTodo.putIfAbsent(e.value.todoId, () => []).add(e.value);
    }
    final out = <Map<String, dynamic>>[];
    for (final e in liveTodos(snap)) {
      final todo = e.value;
      if (status != null && todo.status.wire != status) continue;
      if (type != null && todo.type.wire != type) continue;
      if (categoryId != null && todo.categoryId != categoryId) continue;
      if (query != null && query.isNotEmpty) {
        final haystack = '${todo.title}\n${todo.description ?? ''}'
            .toLowerCase();
        if (!haystack.contains(query)) continue;
      }
      final blocks = blocksByTodo[todo.id] ?? const <TodoBlock>[];
      out.add({
        'id': todo.id,
        'title': todo.title,
        'type': todo.type.wire,
        'priority': todo.priority.wire,
        'status': todo.status.wire,
        'description': todo.description,
        'categoryId': todo.categoryId,
        'tagIds': todo.tagIds,
        'estimatedMinutes': todo.estimatedMinutes,
        'color': todo.color,
        'deadlineAt': todo.deadlineAt == null
            ? null
            : formatUtc(todo.deadlineAt!),
        'displayDeadline': todo.deadlineAt == null
            ? null
            : userTime.formatDateYmdHm(todo.deadlineAt!),
        'blocks': [
          for (final b in blocks)
            {
              'id': b.id,
              'startAt': formatUtc(b.startAt),
              'endAt': formatUtc(b.endAt),
              'displayStart': userTime.formatDateYmdHm(b.startAt),
              'displayEnd': userTime.formatDateYmdHm(b.endAt),
              'blockNote': b.blockNote,
              'status': b.status.wire,
            },
        ],
      });
    }
    return {'todos': out};
  }

  Future<Map<String, dynamic>> _getFreeSlots(Map<String, dynamic> args) async {
    final range = _readRange(args, defaultDays: 1, requireLocal: true);
    final minDuration =
        _optionalInt(args['minDurationMinutes'], 'minDurationMinutes') ?? 30;
    final dayStart =
        _optionalInt(args['dayStartMinute'], 'dayStartMinute') ??
        FreeSlotFinder.defaultDayStartMinute;
    final dayEnd =
        _optionalInt(args['dayEndMinute'], 'dayEndMinute') ??
        FreeSlotFinder.defaultDayEndMinute;
    final snap = await snapshot();
    final slots = FreeSlotFinder(userTime).find(
      snapshot: snap,
      fromUtc: range.startUtc,
      toUtc: range.endUtc,
      minDurationMinutes: minDuration,
      dayStartMinute: dayStart,
      dayEndMinute: dayEnd,
    );
    return {
      'timezone': userTime.ianaName,
      'fromUtc': formatUtc(range.startUtc),
      'toUtc': formatUtc(range.endUtc),
      'freeSlots': [
        for (final s in slots)
          {
            ...s.toJson(),
            'startLocal': userTime.formatDateYmdHm(s.startUtc),
            'endLocal': userTime.formatDateYmdHm(s.endUtc),
          },
      ],
    };
  }

  Future<Map<String, dynamic>> _getTagsAndCategories() async {
    final snap = await snapshot();
    return {
      'tags': [
        for (final e in liveTags(snap))
          {'id': e.value.id, 'name': e.value.name, 'color': e.value.color},
      ],
      'categories': [
        for (final e in liveCategories(snap))
          {'id': e.value.id, 'name': e.value.name, 'color': e.value.color},
      ],
    };
  }

  // ---- propose_changes ------------------------------------------------------

  Future<Map<String, dynamic>> _proposeChanges(
    Map<String, dynamic> args,
  ) async {
    final raw = args['changes'];
    if (raw is! List || raw.isEmpty) {
      throw const _ToolError('changes 必须是非空数组');
    }
    if (raw.length > 50) {
      throw const _ToolError('一次最多提交 50 条变更');
    }
    final ctx = await _buildContext();
    final items = <LocalChangeItem>[];
    for (var i = 0; i < raw.length; i++) {
      final entry = raw[i];
      if (entry is! Map) {
        throw _ToolError('第 ${i + 1} 项必须是对象');
      }
      final change = Map<String, dynamic>.from(entry);
      final kind = change['kind'];
      try {
        items.addAll(await _buildItems(change, ctx));
      } on _ToolError catch (e) {
        throw _ToolError(
          '第 ${i + 1} 项（${kind is String ? kind : '?'}）：${e.message}',
        );
      }
    }
    if (items.isEmpty) {
      throw const _ToolError('变更集为空');
    }
    _pending = LocalChangeSet(
      items: List<LocalChangeItem>.unmodifiable(items),
      createdAt: DateTime.now().toUtc(),
    );
    final warnings = <String>[
      for (final item in items)
        if (item.conflictWarning != null) item.conflictWarning!,
    ];
    return {
      'summary': [for (final item in items) item.summary],
      'count': items.length,
      'hasConflicts': warnings.isNotEmpty,
      if (warnings.isNotEmpty) 'conflicts': warnings,
    };
  }

  Future<_ChangeContext> _buildContext() async {
    final snap = await snapshot();
    final calendars = liveCalendars(snap).map((e) => e.value).toList()
      ..sort((a, b) => a.firstDay.compareTo(b.firstDay));
    return _ChangeContext(
      snapshot: snap,
      todos: {for (final e in liveTodos(snap)) e.value.id: e.value},
      blocks: {for (final e in liveBlocks(snap)) e.value.id: e.value},
      courses: {for (final e in liveCourses(snap)) e.value.id: e.value},
      meetings: {for (final e in liveMeetings(snap)) e.value.id: e.value},
      schedules: {for (final e in liveSchedules(snap)) e.value.id: e.value},
      calendars: calendars,
      periods: livePeriods(snap).map((e) => e.value).toList(),
    );
  }

  Future<List<LocalChangeItem>> _buildItems(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final kind = _requireText(change, 'kind', 'kind');
    switch (kind) {
      case 'create_todo':
        return _createTodo(change, ctx);
      case 'update_todo':
        return [_updateTodo(change, ctx)];
      case 'delete_todo':
        return [_deleteTodo(change, ctx)];
      case 'create_todo_block':
        return await _createTodoBlock(change, ctx);
      case 'update_todo_block':
        return await _updateTodoBlock(change, ctx);
      case 'delete_todo_block':
        return [_deleteTodoBlock(change, ctx)];
      case 'create_course':
        return await _createCourse(change, ctx);
      case 'update_course':
        return [_updateCourse(change, ctx)];
      case 'delete_course':
        return [_deleteCourse(change, ctx)];
      case 'move_course_occurrence':
        return await _moveOccurrence(change, ctx, cancel: false);
      case 'cancel_course_occurrence':
        return await _moveOccurrence(change, ctx, cancel: true);
      case 'create_recurring_schedule':
        return await _createRecurringSchedule(change, ctx);
      case 'update_recurring_schedule':
        return await _updateRecurringSchedule(change, ctx);
      case 'delete_recurring_schedule':
        return [_deleteRecurringSchedule(change, ctx)];
      default:
        throw _ToolError('未知的变更类型：$kind');
    }
  }

  // ---- todo changes ---------------------------------------------------------

  Future<List<LocalChangeItem>> _createTodo(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final title = _requireText(change, 'title', '待办标题');
    final deadline = _optionalStamp(change['deadlineLocal'], 'deadlineLocal');
    final todo = <String, dynamic>{
      'title': title,
      'type': _enumValue(
        change['type'],
        const ['one_off', 'project'],
        'one_off',
        'type',
      ),
      'priority': _enumValue(
        change['priority'],
        const ['low', 'normal', 'high', 'urgent'],
        'normal',
        'priority',
      ),
      'status': _enumValue(
        change['status'],
        const ['todo', 'in_progress', 'completed', 'cancelled'],
        'todo',
        'status',
      ),
      'description': _optionalString(change['description'], 'description'),
      'categoryId': _optionalString(change['categoryId'], 'categoryId'),
      'tagIds': _stringList(change['tagIds'], 'tagIds'),
      'estimatedMinutes': _optionalInt(
        change['estimatedMinutes'],
        'estimatedMinutes',
      ),
      'color': _optionalString(change['color'], 'color'),
      if (deadline != null) 'deadlineAt': formatUtc(deadline.utc),
    };
    final ref = 'new_todo_${_refCounter++}';
    final items = <LocalChangeItem>[
      LocalChangeItem(
        kind: 'create_todo',
        summary: deadline == null
            ? '+ [待办] $title'
            : '+ [待办] $title（截止 ${deadline.label}）',
        payload: {'kind': 'create_todo', 'ref': ref, 'todo': todo},
      ),
    ];

    final rawBlocks = change['blocks'];
    if (rawBlocks != null) {
      if (rawBlocks is! List) {
        throw const _ToolError('blocks 必须是数组');
      }
      for (var i = 0; i < rawBlocks.length; i++) {
        final raw = rawBlocks[i];
        if (raw is! Map) {
          throw _ToolError('blocks 第 ${i + 1} 项必须是对象');
        }
        final b = Map<String, dynamic>.from(raw);
        final range = _parseRangeFrom(b, 'blocks 第 ${i + 1} 项');
        final note = _optionalString(b['blockNote'], 'blockNote');
        final status = _enumValue(
          b['status'],
          const ['scheduled', 'in_progress', 'completed', 'skipped'],
          'scheduled',
          'status',
        );
        final warnings = await _intervalConflictWarnings(
          ctx,
          startUtc: range.start.utc,
          endUtc: range.end.utc,
        );
        ctx.plannedBlocks.add((
          title: title,
          start: range.start.utc,
          end: range.end.utc,
        ));
        items.add(
          LocalChangeItem(
            kind: 'create_todo_block',
            summary: _blockSummary('+', range.start, range.end, title, note),
            conflictWarning: _joinWarnings(warnings),
            payload: {
              'kind': 'create_todo_block',
              'todoRef': ref,
              'startAt': formatUtc(range.start.utc),
              'endAt': formatUtc(range.end.utc),
              'blockNote': note,
              'status': status,
            },
          ),
        );
      }
    }
    return items;
  }

  LocalChangeItem _updateTodo(Map<String, dynamic> change, _ChangeContext ctx) {
    final todoId = _requireText(change, 'todoId', '待办 ID');
    final todo = ctx.todos[todoId];
    if (todo == null) {
      throw _ToolError('待办不存在：$todoId');
    }
    final rawFields = change['fields'];
    if (rawFields is! Map || rawFields.isEmpty) {
      throw const _ToolError('fields 必须是非空对象');
    }
    final fields = _normalizeTodoFields(Map<String, dynamic>.from(rawFields));
    return LocalChangeItem(
      kind: 'update_todo',
      summary: '~ [待办] 修改「${todo.title}」：${_fieldLabels(fields).join('、')}',
      payload: {'kind': 'update_todo', 'todoId': todoId, 'fields': fields},
    );
  }

  LocalChangeItem _deleteTodo(Map<String, dynamic> change, _ChangeContext ctx) {
    final todoId = _requireText(change, 'todoId', '待办 ID');
    final todo = ctx.todos[todoId];
    if (todo == null) {
      throw _ToolError('待办不存在：$todoId');
    }
    return LocalChangeItem(
      kind: 'delete_todo',
      summary: '- [待办] 删除「${todo.title}」',
      payload: {'kind': 'delete_todo', 'todoId': todoId},
    );
  }

  Future<List<LocalChangeItem>> _createTodoBlock(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final todoId = _requireText(change, 'todoId', '待办 ID');
    final todo = ctx.todos[todoId];
    if (todo == null) {
      throw _ToolError('待办不存在：$todoId');
    }
    final range = _parseRangeFrom(change, '时间块');
    final note = _optionalString(change['blockNote'], 'blockNote');
    final status = _enumValue(
      change['status'],
      const ['scheduled', 'in_progress', 'completed', 'skipped'],
      'scheduled',
      'status',
    );
    final warnings = await _intervalConflictWarnings(
      ctx,
      startUtc: range.start.utc,
      endUtc: range.end.utc,
    );
    ctx.plannedBlocks.add((
      title: todo.title,
      start: range.start.utc,
      end: range.end.utc,
    ));
    return [
      LocalChangeItem(
        kind: 'create_todo_block',
        summary: _blockSummary('+', range.start, range.end, todo.title, note),
        conflictWarning: _joinWarnings(warnings),
        payload: {
          'kind': 'create_todo_block',
          'todoId': todoId,
          'startAt': formatUtc(range.start.utc),
          'endAt': formatUtc(range.end.utc),
          'blockNote': note,
          'status': status,
        },
      ),
    ];
  }

  Future<List<LocalChangeItem>> _updateTodoBlock(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final blockId = _requireText(change, 'blockId', '时间块 ID');
    final block = ctx.blocks[blockId];
    if (block == null) {
      throw _ToolError('时间块不存在：$blockId');
    }
    final todo = ctx.todos[block.todoId];
    final changes = <String, dynamic>{};
    if (change.containsKey('startLocal') || change.containsKey('endLocal')) {
      final start = change.containsKey('startLocal')
          ? _requireStamp(change, 'startLocal', '开始时间')
          : _stampFromUtc(block.startAt);
      final end = change.containsKey('endLocal')
          ? _requireStamp(change, 'endLocal', '结束时间')
          : _stampFromUtc(block.endAt);
      _ensureRange(start, end, '时间块');
      changes['startAt'] = formatUtc(start.utc);
      changes['endAt'] = formatUtc(end.utc);
    }
    if (change.containsKey('blockNote')) {
      changes['blockNote'] = _optionalString(change['blockNote'], 'blockNote');
    }
    if (change.containsKey('status')) {
      changes['status'] = _enumValue(
        change['status'],
        const ['scheduled', 'in_progress', 'completed', 'skipped'],
        'scheduled',
        'status',
      );
    }
    if (changes.isEmpty) {
      throw const _ToolError('没有需要修改的字段');
    }
    final startStamp = changes.containsKey('startAt')
        ? _stampFromUtc(parseUtc(changes['startAt'] as String)!)
        : _stampFromUtc(block.startAt);
    final endStamp = changes.containsKey('endAt')
        ? _stampFromUtc(parseUtc(changes['endAt'] as String)!)
        : _stampFromUtc(block.endAt);
    final warnings = await _intervalConflictWarnings(
      ctx,
      startUtc: startStamp.utc,
      endUtc: endStamp.utc,
      excludeEventIds: {'todo_block:$blockId'},
    );
    final note = changes.containsKey('blockNote')
        ? changes['blockNote'] as String?
        : block.blockNote;
    return [
      LocalChangeItem(
        kind: 'update_todo_block',
        summary: _blockSummary(
          '~',
          startStamp,
          endStamp,
          todo?.title ?? block.todoId,
          note,
        ),
        conflictWarning: _joinWarnings(warnings),
        payload: {
          'kind': 'update_todo_block',
          'blockId': blockId,
          'changes': changes,
        },
      ),
    ];
  }

  LocalChangeItem _deleteTodoBlock(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) {
    final blockId = _requireText(change, 'blockId', '时间块 ID');
    final block = ctx.blocks[blockId];
    if (block == null) {
      throw _ToolError('时间块不存在：$blockId');
    }
    final title = ctx.todos[block.todoId]?.title ?? block.todoId;
    return LocalChangeItem(
      kind: 'delete_todo_block',
      summary: _blockSummary(
        '-',
        _stampFromUtc(block.startAt),
        _stampFromUtc(block.endAt),
        title,
        block.blockNote,
      ),
      payload: {'kind': 'delete_todo_block', 'blockId': blockId},
    );
  }

  // ---- course changes -------------------------------------------------------

  Future<List<LocalChangeItem>> _createCourse(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final name = _requireText(change, 'name', '课程名称');
    final calendar = _calendarForCreate(
      ctx,
      _optionalString(change['calendarId'], 'calendarId'),
    );
    final course = <String, dynamic>{
      'calendarId': calendar.id,
      'name': name,
      'teacher': _optionalString(change['teacher'], 'teacher'),
      'location': _optionalString(change['location'], 'location'),
      'color': _optionalString(change['color'], 'color'),
      'notes': _optionalString(change['notes'], 'notes'),
    };
    final meetings = <Map<String, dynamic>>[];
    final parts = <String>[];
    final spans = <({DateTime start, DateTime end})>[];
    final rawMeetings = change['meetings'];
    if (rawMeetings != null) {
      if (rawMeetings is! List) {
        throw const _ToolError('meetings 必须是数组');
      }
      for (var i = 0; i < rawMeetings.length; i++) {
        final raw = rawMeetings[i];
        if (raw is! Map) {
          throw _ToolError('meetings 第 ${i + 1} 项必须是对象');
        }
        final m = Map<String, dynamic>.from(raw);
        final label = 'meetings 第 ${i + 1} 项';
        final weekday = _requireInt(m, 'weekday', '$label weekday');
        if (weekday < 1 || weekday > 7) {
          throw _ToolError('$label weekday 必须是 1..7');
        }
        final periodStart = _requireInt(m, 'periodStart', '$label periodStart');
        final periodEnd = _requireInt(m, 'periodEnd', '$label periodEnd');
        if (periodStart < 1 || periodEnd < periodStart) {
          throw _ToolError('$label 节次范围不合理');
        }
        final rule = _parseWeeks(m['weeks'], '$label weeks');
        final minutes = _periodRangeFor(
          ctx,
          calendar.id,
          periodStart,
          periodEnd,
        );
        meetings.add({
          'weekday': weekday,
          'periodStart': periodStart,
          'periodEnd': periodEnd,
          'weekRule': rule.toJson(),
        });
        parts.add(
          '${_weekdays[weekday - 1]} 第$periodStart-$periodEnd节 '
          '${_hhmm(minutes.start)}-${_hhmm(minutes.end)}'
          '（${_weeksLabel(rule, calendar.totalWeeks)}）',
        );
        spans.addAll(
          _meetingSpans(
            calendar: calendar,
            weekday: weekday,
            rule: rule,
            minutes: minutes,
          ),
        );
      }
    }
    final warnings = await _spanConflictWarnings(ctx, spans);
    return [
      LocalChangeItem(
        kind: 'create_course',
        summary:
            '+ [课程] $name'
            '${parts.isEmpty ? '' : '（${parts.join('；')}）'}',
        conflictWarning: _joinWarnings(warnings),
        payload: {
          'kind': 'create_course',
          'course': course,
          'meetings': meetings,
        },
      ),
    ];
  }

  LocalChangeItem _updateCourse(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) {
    final courseId = _requireText(change, 'courseId', '课程 ID');
    final course = ctx.courses[courseId];
    if (course == null) {
      throw _ToolError('课程不存在：$courseId');
    }
    final rawFields = change['fields'];
    if (rawFields is! Map || rawFields.isEmpty) {
      throw const _ToolError('fields 必须是非空对象');
    }
    const allowed = ['name', 'teacher', 'location', 'color', 'notes'];
    final changes = <String, dynamic>{};
    for (final key in rawFields.keys) {
      final name = key.toString();
      if (!allowed.contains(name)) {
        throw _ToolError('update_course 不支持字段「$name」');
      }
      if (name == 'name') {
        final value = _optionalString(rawFields[key], 'name');
        if (value == null) throw const _ToolError('课程名称不能为空');
        changes['name'] = value;
      } else {
        changes[name] = _optionalString(rawFields[key], name);
      }
    }
    return LocalChangeItem(
      kind: 'update_course',
      summary:
          '~ [课程] 修改「${course.name}」：'
          '${_fieldLabels(changes).join('、')}',
      payload: {
        'kind': 'update_course',
        'courseId': courseId,
        'changes': changes,
      },
    );
  }

  LocalChangeItem _deleteCourse(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) {
    final courseId = _requireText(change, 'courseId', '课程 ID');
    final course = ctx.courses[courseId];
    if (course == null) {
      throw _ToolError('课程不存在：$courseId');
    }
    final meetingIds = [
      for (final m in ctx.meetings.values)
        if (m.courseId == courseId) m.id,
    ];
    return LocalChangeItem(
      kind: 'delete_course',
      summary:
          '- [课程] 删除「${course.name}」'
          '${meetingIds.isEmpty ? '' : '（含 ${meetingIds.length} 个课次）'}',
      payload: {
        'kind': 'delete_course',
        'courseId': courseId,
        'meetingIds': meetingIds,
      },
    );
  }

  Future<List<LocalChangeItem>> _moveOccurrence(
    Map<String, dynamic> change,
    _ChangeContext ctx, {
    required bool cancel,
  }) async {
    final seriesType = _optionalEnum(change['seriesType'], const [
      SeriesTypes.courseMeeting,
      SeriesTypes.recurringSchedule,
    ], 'seriesType');
    if (seriesType == null) {
      throw const _ToolError(
        'seriesType 必须是 course_meeting 或 recurring_schedule',
      );
    }
    final seriesId = _requireText(change, 'seriesId', '系列 ID');
    if (seriesType == SeriesTypes.courseMeeting &&
        !ctx.meetings.containsKey(seriesId)) {
      throw _ToolError('课程安排不存在：$seriesId');
    }
    if (seriesType == SeriesTypes.recurringSchedule &&
        !ctx.schedules.containsKey(seriesId)) {
      throw _ToolError('周期日程不存在：$seriesId');
    }
    final dateText = _requireText(
      change,
      'occurrenceDateLocal',
      'occurrenceDateLocal',
    );
    final dateStamp = _parseLocalDateStrict(dateText, 'occurrenceDateLocal');
    final occurrenceDateLocal = dateStamp.dateLocal;

    final event = _occurrenceEvent(
      ctx,
      seriesType,
      seriesId,
      occurrenceDateLocal,
    );
    if (event == null) {
      throw _ToolError('找不到 $occurrenceDateLocal 的该课次（可能已取消或不在该学期）');
    }
    final title = event.title;
    if (cancel) {
      return [
        LocalChangeItem(
          kind: 'cancel_course_occurrence',
          summary:
              '- ${_stampFromUtc(event.startUtc).dayLabel} '
              '${_stampFromUtc(event.startUtc).hhmm}-'
              '${_stampFromUtc(event.endUtc).hhmm} [停课] $title',
          payload: {
            'kind': 'cancel_course_occurrence',
            'seriesType': seriesType,
            'seriesId': seriesId,
            'occurrenceDateLocal': occurrenceDateLocal,
            'originalStartUtc': formatUtc(event.startUtc),
          },
        ),
      ];
    }

    final newStart = _requireStamp(change, 'newStartLocal', '新开始时间');
    final newEnd = _requireStamp(change, 'newEndLocal', '新结束时间');
    _ensureRange(newStart, newEnd, '调课时间');
    final warnings = await _intervalConflictWarnings(
      ctx,
      startUtc: newStart.utc,
      endUtc: newEnd.utc,
      excludeEventIds: {event.id},
    );
    final original = _stampFromUtc(event.startUtc);
    return [
      LocalChangeItem(
        kind: 'move_course_occurrence',
        summary:
            '~ ${newStart.dayLabel} ${newStart.hhmm}-${newEnd.hhmm} '
            '[调课] $title（原 ${original.dayLabel} '
            '${original.hhmm}-${_stampFromUtc(event.endUtc).hhmm}）',
        conflictWarning: _joinWarnings(warnings),
        payload: {
          'kind': 'move_course_occurrence',
          'seriesType': seriesType,
          'seriesId': seriesId,
          'occurrenceDateLocal': occurrenceDateLocal,
          'originalStartUtc': formatUtc(event.startUtc),
          'newStartUtc': formatUtc(newStart.utc),
          'newEndUtc': formatUtc(newEnd.utc),
        },
      ),
    ];
  }

  // ---- recurring schedule changes -------------------------------------------

  Future<List<LocalChangeItem>> _createRecurringSchedule(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final title = _requireText(change, 'title', '周期日程标题');
    final calendar = _calendarForCreate(
      ctx,
      _optionalString(change['calendarId'], 'calendarId'),
    );
    final weekday = _requireInt(change, 'weekday', 'weekday');
    if (weekday < 1 || weekday > 7) {
      throw const _ToolError('weekday 必须是 1..7');
    }
    final rule = _parseWeeks(change['weeks'], 'weeks');
    final periodStart = _optionalInt(change['periodStart'], 'periodStart');
    final periodEnd = _optionalInt(change['periodEnd'], 'periodEnd');
    final usePeriods = (periodStart ?? 0) > 0 || (periodEnd ?? 0) > 0;
    final startHm = usePeriods
        ? null
        : _requireHm(change, 'startLocal', '开始时间');
    final endHm = usePeriods ? null : _requireHm(change, 'endLocal', '结束时间');

    late final ScheduleRule scheduleRule;
    late final int startMinute;
    late final int endMinute;
    if (usePeriods) {
      final ps = periodStart ?? 0;
      final pe = periodEnd ?? 0;
      if (ps < 1 || pe < ps) {
        throw const _ToolError('节次范围不合理');
      }
      final minutes = _periodRangeFor(ctx, calendar.id, ps, pe);
      startMinute = minutes.start;
      endMinute = minutes.end;
      scheduleRule = ScheduleRule(
        kind: ScheduleRuleKind.byAcademicWeek,
        calendarId: calendar.id,
        weekdays: [weekday],
        periodStart: ps,
        periodEnd: pe,
        weekRule: rule,
      );
    } else {
      startMinute = startHm!.hour * 60 + startHm.minute;
      endMinute = endHm!.hour * 60 + endHm.minute;
      if (endMinute <= startMinute) {
        throw const _ToolError('结束时间必须晚于开始时间');
      }
      scheduleRule = ScheduleRule(
        kind: ScheduleRuleKind.byAcademicWeek,
        calendarId: calendar.id,
        weekdays: [weekday],
        startLocal: _hm(startHm),
        endLocal: _hm(endHm),
        weekRule: rule,
      );
    }
    final spans = _scheduleSpans(
      scheduleRule,
      calendar: calendar,
      startMinute: startMinute,
      endMinute: endMinute,
    );
    final warnings = await _spanConflictWarnings(ctx, spans);
    final schedule = <String, dynamic>{
      'title': title,
      'color': _optionalString(change['color'], 'color'),
      'notes': _optionalString(change['notes'], 'notes'),
      'rule': scheduleRule.toJson(),
    };
    return [
      LocalChangeItem(
        kind: 'create_recurring_schedule',
        summary:
            '+ [周期日程] $title'
            '（${_weekdays[weekday - 1]} ${_hhmm(startMinute)}-'
            '${_hhmm(endMinute)}（${_weeksLabel(rule, calendar.totalWeeks)}））',
        conflictWarning: _joinWarnings(warnings),
        payload: {'kind': 'create_recurring_schedule', 'schedule': schedule},
      ),
    ];
  }

  Future<List<LocalChangeItem>> _updateRecurringSchedule(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) async {
    final scheduleId = _requireText(change, 'scheduleId', '周期日程 ID');
    final existing = ctx.schedules[scheduleId];
    if (existing == null) {
      throw _ToolError('周期日程不存在：$scheduleId');
    }
    const allowed = [
      'title',
      'color',
      'notes',
      'weekday',
      'weekdays',
      'periodStart',
      'periodEnd',
      'weeks',
      'startLocal',
      'endLocal',
    ];
    final rawFields = change['fields'];
    if (rawFields is! Map || rawFields.isEmpty) {
      throw const _ToolError('fields 必须是非空对象');
    }
    final fields = Map<String, dynamic>.from(rawFields);
    for (final key in fields.keys) {
      if (!allowed.contains(key.toString())) {
        throw _ToolError('update_recurring_schedule 不支持字段「$key」');
      }
    }

    final oldRule = existing.rule;
    var weekdays = oldRule.weekdays;
    if (fields.containsKey('weekday')) {
      final weekday = _requireInt(fields, 'weekday', 'weekday');
      if (weekday < 1 || weekday > 7) {
        throw const _ToolError('weekday 必须是 1..7');
      }
      weekdays = [weekday];
    } else if (fields.containsKey('weekdays')) {
      final raw = fields['weekdays'];
      if (raw is! List || raw.isEmpty) {
        throw const _ToolError('weekdays 必须是非空数组');
      }
      final out = <int>[];
      for (final e in raw) {
        final day = _asInt(e, 'weekdays');
        if (day < 1 || day > 7) {
          throw const _ToolError('weekdays 中的值必须是 1..7');
        }
        out.add(day);
      }
      weekdays = out;
    }

    var periodStart = oldRule.periodStart;
    var periodEnd = oldRule.periodEnd;
    if (fields.containsKey('periodStart')) {
      periodStart = _optionalInt(fields['periodStart'], 'periodStart') ?? 0;
    }
    if (fields.containsKey('periodEnd')) {
      periodEnd = _optionalInt(fields['periodEnd'], 'periodEnd') ?? 0;
    }
    if (periodStart > 0 || periodEnd > 0) {
      if (periodStart < 1 || periodEnd < periodStart) {
        throw const _ToolError('节次范围不合理');
      }
    }

    final rule = ScheduleRule(
      kind: oldRule.kind,
      startLocal: fields.containsKey('startLocal')
          ? _hm(_requireHm(fields, 'startLocal', '开始时间'))
          : oldRule.startLocal,
      endLocal: fields.containsKey('endLocal')
          ? _hm(_requireHm(fields, 'endLocal', '结束时间'))
          : oldRule.endLocal,
      weekdays: weekdays,
      dateStart: oldRule.dateStart,
      dateEnd: oldRule.dateEnd,
      calendarId: oldRule.calendarId,
      weekRule: fields.containsKey('weeks')
          ? _parseWeeks(fields['weeks'], 'weeks')
          : oldRule.weekRule,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );

    const ruleKeys = [
      'weekday',
      'weekdays',
      'periodStart',
      'periodEnd',
      'weeks',
      'startLocal',
      'endLocal',
    ];
    final touchesRule = ruleKeys.any(fields.containsKey);
    final changes = <String, dynamic>{if (touchesRule) 'rule': rule.toJson()};
    if (fields.containsKey('title')) {
      final title = _optionalString(fields['title'], 'title');
      if (title == null) throw const _ToolError('周期日程标题不能为空');
      changes['title'] = title;
    }
    if (fields.containsKey('color')) {
      changes['color'] = _optionalString(fields['color'], 'color');
    }
    if (fields.containsKey('notes')) {
      changes['notes'] = _optionalString(fields['notes'], 'notes');
    }

    final warnings = touchesRule
        ? await _scheduleRuleWarnings(ctx, rule, excludeSourceId: scheduleId)
        : const <String>[];
    final newTitle = changes['title'] as String? ?? existing.title;
    final labels = <String>[
      for (final key in changes.keys)
        if (key != 'rule') _fieldLabels({key: changes[key]}).first,
      if (changes.containsKey('rule'))
        for (final key in const [
          'weekday',
          'weekdays',
          'periodStart',
          'periodEnd',
          'weeks',
          'startLocal',
          'endLocal',
        ])
          if (fields.containsKey(key)) _recurringFieldLabel(key),
    ];
    return [
      LocalChangeItem(
        kind: 'update_recurring_schedule',
        summary:
            '~ [周期日程] 修改「$newTitle」'
            '${labels.isEmpty ? '' : '：${_dedupe(labels).join('、')}'}',
        conflictWarning: _joinWarnings(warnings),
        payload: {
          'kind': 'update_recurring_schedule',
          'scheduleId': scheduleId,
          'changes': changes,
        },
      ),
    ];
  }

  LocalChangeItem _deleteRecurringSchedule(
    Map<String, dynamic> change,
    _ChangeContext ctx,
  ) {
    final scheduleId = _requireText(change, 'scheduleId', '周期日程 ID');
    final schedule = ctx.schedules[scheduleId];
    if (schedule == null) {
      throw _ToolError('周期日程不存在：$scheduleId');
    }
    return LocalChangeItem(
      kind: 'delete_recurring_schedule',
      summary: '- [周期日程] 删除「${schedule.title}」',
      payload: {'kind': 'delete_recurring_schedule', 'scheduleId': scheduleId},
    );
  }

  // ---- apply ----------------------------------------------------------------

  Future<void> _applyItem(
    LocalChangeItem item,
    Map<String, String> createdTodoIds,
  ) async {
    final p = item.payload;
    switch (item.kind) {
      case 'create_todo':
        final id = await repo.localCreate(
          entityType: EntityTypes.todo,
          snapshot: Map<String, dynamic>.from(p['todo'] as Map),
        );
        final ref = p['ref'];
        if (ref is String && ref.isNotEmpty) createdTodoIds[ref] = id;
        return;
      case 'create_todo_block':
        await repo.localCreate(
          entityType: EntityTypes.todoBlock,
          snapshot: {
            'todoId': _todoIdFromPayload(p, createdTodoIds),
            'startAt': p['startAt'],
            'endAt': p['endAt'],
            'blockNote': p['blockNote'],
            'status': p['status'] ?? 'scheduled',
          },
        );
        return;
      case 'update_todo':
        await repo.localUpdate(
          entityType: EntityTypes.todo,
          entityId: p['todoId'] as String,
          changes: Map<String, dynamic>.from(p['fields'] as Map),
        );
        return;
      case 'delete_todo':
        await repo.localDelete(
          entityType: EntityTypes.todo,
          entityId: p['todoId'] as String,
        );
        return;
      case 'update_todo_block':
        await repo.localUpdate(
          entityType: EntityTypes.todoBlock,
          entityId: p['blockId'] as String,
          changes: Map<String, dynamic>.from(p['changes'] as Map),
        );
        return;
      case 'delete_todo_block':
        await repo.localDelete(
          entityType: EntityTypes.todoBlock,
          entityId: p['blockId'] as String,
        );
        return;
      case 'create_course':
        final meetings = <Map<String, dynamic>>[];
        final raw = p['meetings'];
        if (raw is List) {
          for (final m in raw) {
            if (m is Map) meetings.add(Map<String, dynamic>.from(m));
          }
        }
        await repo.createCourseWithMeetings(
          courseSnapshot: Map<String, dynamic>.from(p['course'] as Map),
          meetingSnapshots: meetings,
        );
        return;
      case 'update_course':
        await repo.localUpdate(
          entityType: EntityTypes.course,
          entityId: p['courseId'] as String,
          changes: Map<String, dynamic>.from(p['changes'] as Map),
        );
        return;
      case 'delete_course':
        final meetingIds = p['meetingIds'];
        if (meetingIds is List) {
          for (final id in meetingIds) {
            if (id is String && id.isNotEmpty) {
              await repo.localDelete(
                entityType: EntityTypes.courseMeeting,
                entityId: id,
              );
            }
          }
        }
        await repo.localDelete(
          entityType: EntityTypes.course,
          entityId: p['courseId'] as String,
        );
        return;
      case 'move_course_occurrence':
        final service = LocalSeriesService(repo: repo, userTime: userTime);
        await service.moveOccurrence(
          snapshot: await snapshot(),
          seriesType: p['seriesType'] as String,
          seriesId: p['seriesId'] as String,
          originalStartUtc: _isoUtc(p['originalStartUtc']),
          newStartUtc: _isoUtc(p['newStartUtc']),
          newEndUtc: _isoUtc(p['newEndUtc']),
        );
        return;
      case 'cancel_course_occurrence':
        final service = LocalSeriesService(repo: repo, userTime: userTime);
        await service.cancelOccurrence(
          snapshot: await snapshot(),
          seriesType: p['seriesType'] as String,
          seriesId: p['seriesId'] as String,
          originalStartUtc: _isoUtc(p['originalStartUtc']),
        );
        return;
      case 'create_recurring_schedule':
        await repo.localCreate(
          entityType: EntityTypes.recurringSchedule,
          snapshot: Map<String, dynamic>.from(p['schedule'] as Map),
        );
        return;
      case 'update_recurring_schedule':
        await repo.localUpdate(
          entityType: EntityTypes.recurringSchedule,
          entityId: p['scheduleId'] as String,
          changes: Map<String, dynamic>.from(p['changes'] as Map),
        );
        return;
      case 'delete_recurring_schedule':
        await repo.localDelete(
          entityType: EntityTypes.recurringSchedule,
          entityId: p['scheduleId'] as String,
        );
        return;
      default:
        throw _ToolError('无法应用未知的变更类型：${item.kind}');
    }
  }

  String _todoIdFromPayload(
    Map<String, dynamic> payload,
    Map<String, String> createdTodoIds,
  ) {
    final ref = payload['todoRef'];
    if (ref is String && ref.isNotEmpty) {
      final id = createdTodoIds[ref];
      if (id == null) {
        throw const _ToolError('内部错误：找不到新建待办的引用');
      }
      return id;
    }
    final id = payload['todoId'];
    if (id is String && id.isNotEmpty) return id;
    throw const _ToolError('时间块缺少所属待办 ID');
  }

  // ---- context helpers ------------------------------------------------------

  /// Current UTC instant, preferring the last server-clock estimate
  /// (docs/datetime.md §8) and falling back to the device clock.
  Future<DateTime> _nowUtc() async {
    final deviceNow = DateTime.now().toUtc();
    final meta = await store.meta();
    final fetchedAt = meta?.clockFetchedAt;
    final serverUtc = meta?.clockServerUtc;
    if (fetchedAt == null || serverUtc == null) return deviceNow;
    final elapsed = deviceNow.difference(fetchedAt.toUtc());
    if (elapsed.isNegative || elapsed > const Duration(days: 1)) {
      return deviceNow;
    }
    return serverUtc.toUtc().add(elapsed);
  }

  AcademicCalendar? _activeSemester(EntitiesSnapshot snap, DateTime localNow) {
    final calendars = liveCalendars(snap).map((e) => e.value).toList()
      ..sort((a, b) => a.firstDay.compareTo(b.firstDay));
    if (calendars.isEmpty) return null;
    final today = userTime.localDateString(localNow);
    final expander = EventExpander(userTime);
    for (final c in calendars.reversed) {
      final week = expander.weekOf(c.firstDay, today);
      if (week >= 1 && week <= c.totalWeeks) return c;
    }
    return null;
  }

  AcademicCalendar? _semesterOf(
    _ChangeContext ctx, {
    required bool allowFallback,
  }) {
    if (ctx.calendars.isEmpty) return null;
    final nowLocal = userTime.localFromUtc(DateTime.now().toUtc());
    final today = userTime.localDateString(nowLocal);
    final expander = EventExpander(userTime);
    for (final c in ctx.calendars.reversed) {
      final week = expander.weekOf(c.firstDay, today);
      if (week >= 1 && week <= c.totalWeeks) return c;
    }
    return allowFallback ? ctx.calendars.last : null;
  }

  AcademicCalendar _calendarForCreate(_ChangeContext ctx, String? calendarId) {
    if (calendarId != null) {
      for (final c in ctx.calendars) {
        if (c.id == calendarId) return c;
      }
      throw _ToolError('学期不存在：$calendarId');
    }
    final semester = _semesterOf(ctx, allowFallback: true);
    if (semester == null) {
      throw const _ToolError('还没有学期，请先在设置中添加学期');
    }
    return semester;
  }

  ({int start, int end}) _periodRangeFor(
    _ChangeContext ctx,
    String calendarId,
    int periodStart,
    int periodEnd,
  ) {
    final periods = [
      for (final p in ctx.periods)
        if (p.calendarId == calendarId) p,
    ];
    if (periods.isEmpty) {
      throw const _ToolError('该学期还没有节次时间表，无法按节次安排');
    }
    PeriodTemplate? start;
    PeriodTemplate? end;
    for (final p in periods) {
      if (p.periodNo == periodStart) start = p;
      if (p.periodNo == periodEnd) end = p;
    }
    if (start == null) {
      throw _ToolError('该学期没有第 $periodStart 节的时间模板');
    }
    if (end == null) {
      throw _ToolError('该学期没有第 $periodEnd 节的时间模板');
    }
    return (start: start.startMinute, end: end.endMinute);
  }

  UiEvent? _occurrenceEvent(
    _ChangeContext ctx,
    String seriesType,
    String seriesId,
    String occurrenceDateLocal,
  ) {
    final date = userTime.parseLocalDate(occurrenceDateLocal);
    if (date == null) return null;
    final startUtc = _plainUtc(userTime.localDateAfter(date, -21));
    final endUtc = _plainUtc(userTime.localDateAfter(date, 22));
    final events = EventProjection(EventExpander(userTime))
        .project(
          ctx.snapshot,
          startUtc: startUtc,
          endUtc: endUtc,
          includeDeadlines: false,
        )
        .events;
    final id = seriesType == SeriesTypes.courseMeeting
        ? 'course:$seriesId:$occurrenceDateLocal'
        : 'recurring:$seriesId:$occurrenceDateLocal';
    for (final e in events) {
      if (e.id == id) return e;
    }
    return null;
  }

  List<({DateTime start, DateTime end})> _meetingSpans({
    required AcademicCalendar calendar,
    required int weekday,
    required WeekRule rule,
    required ({int start, int end}) minutes,
  }) {
    final weeks = rule.isEmpty
        ? List<int>.generate(calendar.totalWeeks, (i) => i + 1)
        : rule.weeks(calendar.totalWeeks);
    return _spansFor(
      calendar: calendar,
      weekdays: [weekday],
      weeks: weeks,
      startMinute: minutes.start,
      endMinute: minutes.end,
    );
  }

  List<({DateTime start, DateTime end})> _scheduleSpans(
    ScheduleRule rule, {
    required AcademicCalendar calendar,
    required int startMinute,
    required int endMinute,
  }) {
    final weeks = rule.weekRule == null || rule.weekRule!.isEmpty
        ? List<int>.generate(calendar.totalWeeks, (i) => i + 1)
        : rule.weekRule!.weeks(calendar.totalWeeks);
    return _spansFor(
      calendar: calendar,
      weekdays: rule.weekdays,
      weeks: weeks,
      startMinute: startMinute,
      endMinute: endMinute,
    );
  }

  List<({DateTime start, DateTime end})> _spansFor({
    required AcademicCalendar calendar,
    required List<int> weekdays,
    required List<int> weeks,
    required int startMinute,
    required int endMinute,
  }) {
    final expander = EventExpander(userTime);
    final out = <({DateTime start, DateTime end})>[];
    for (final weekday in weekdays) {
      for (final week in weeks) {
        final dateStr = expander.localDateOfOccurrence(
          calendar.firstDay,
          week,
          weekday,
        );
        if (dateStr == null) continue;
        final date = userTime.parseLocalDate(dateStr);
        if (date == null) continue;
        out.add((
          start: _plainUtc(
            userTime.fromLocalParts(
              date.year,
              date.month,
              date.day,
              startMinute ~/ 60,
              startMinute % 60,
            ),
          ),
          end: _plainUtc(
            userTime.fromLocalParts(
              date.year,
              date.month,
              date.day,
              endMinute ~/ 60,
              endMinute % 60,
            ),
          ),
        ));
      }
    }
    return out;
  }

  Future<List<String>> _scheduleRuleWarnings(
    _ChangeContext ctx,
    ScheduleRule rule, {
    String? excludeSourceId,
  }) async {
    if (rule.kind != ScheduleRuleKind.byAcademicWeek) return const [];
    final calendarId = rule.calendarId;
    if (calendarId == null) return const [];
    AcademicCalendar? calendar;
    for (final c in ctx.calendars) {
      if (c.id == calendarId) calendar = c;
    }
    if (calendar == null) return const [];
    int startMinute;
    int endMinute;
    if (rule.periodStart > 0) {
      final minutes = _periodRangeFor(
        ctx,
        calendarId,
        rule.periodStart,
        rule.periodEnd,
      );
      startMinute = minutes.start;
      endMinute = minutes.end;
    } else {
      final s = _hhmmMinutes(rule.startLocal);
      final e = _hhmmMinutes(rule.endLocal);
      if (s == null || e == null || e <= s) return const [];
      startMinute = s;
      endMinute = e;
    }
    final spans = _scheduleSpans(
      rule,
      calendar: calendar,
      startMinute: startMinute,
      endMinute: endMinute,
    );
    return _spanConflictWarnings(ctx, spans, excludeSourceId: excludeSourceId);
  }

  // ---- conflict detection ---------------------------------------------------

  Future<List<String>> _intervalConflictWarnings(
    _ChangeContext ctx, {
    required DateTime startUtc,
    required DateTime endUtc,
    Set<String> excludeEventIds = const {},
  }) async {
    if (!endUtc.isAfter(startUtc)) return const [];
    final events = EventProjection(EventExpander(userTime))
        .project(
          ctx.snapshot,
          startUtc: startUtc,
          endUtc: endUtc,
          includeDeadlines: false,
        )
        .events;
    final warnings = <String>[];
    for (final e in events) {
      if (excludeEventIds.contains(e.id)) continue;
      if (!intervalsOverlap(startUtc, endUtc, e.startUtc, e.endUtc)) continue;
      final message = _conflictMessage(e.type, e.title);
      if (message.isNotEmpty) warnings.add(message);
    }
    for (final planned in ctx.plannedBlocks) {
      if (intervalsOverlap(startUtc, endUtc, planned.start, planned.end)) {
        warnings.add('⚠️ 与本次同时排期的时间块「${planned.title}」重叠');
      }
    }
    return _dedupe(warnings);
  }

  Future<List<String>> _spanConflictWarnings(
    _ChangeContext ctx,
    List<({DateTime start, DateTime end})> spans, {
    String? excludeSourceId,
  }) async {
    final valid = [
      for (final s in spans)
        if (s.end.isAfter(s.start)) s,
    ];
    if (valid.isEmpty) return const [];
    valid.sort((a, b) => a.start.compareTo(b.start));
    final startUtc = valid.first.start;
    var endUtc = valid.first.end;
    for (final s in valid) {
      if (s.end.isAfter(endUtc)) endUtc = s.end;
    }
    final events = EventProjection(EventExpander(userTime))
        .project(
          ctx.snapshot,
          startUtc: startUtc,
          endUtc: endUtc,
          includeDeadlines: false,
        )
        .events;
    final warnings = <String>[];
    for (final span in valid) {
      for (final e in events) {
        if (excludeSourceId != null && e.sourceId == excludeSourceId) continue;
        if (!intervalsOverlap(span.start, span.end, e.startUtc, e.endUtc)) {
          continue;
        }
        final message = _conflictMessage(e.type, e.title);
        if (message.isNotEmpty) warnings.add(message);
      }
    }
    return _dedupe(warnings);
  }

  // ---- formatting / parsing -------------------------------------------------

  Map<String, dynamic> _eventJson(UiEvent e) => {
    'id': e.id,
    'type': e.type.wire,
    'title': e.title,
    'startUtc': formatUtc(e.startUtc),
    'endUtc': formatUtc(e.endUtc),
    'displayStart': userTime.formatDateYmdHm(e.startUtc),
    'displayEnd': e.type == EventType.deadline
        ? null
        : userTime.formatDateYmdHm(e.endUtc),
    'sourceType': e.sourceType,
    'sourceId': e.sourceId,
    'conflict': e.conflict.wire,
    'location': e.location,
    'teacher': e.teacher,
    'note': e.note,
    'reminder': e.reminder,
  };

  Map<String, dynamic> _meetingJson(
    CourseMeeting m, {
    AcademicCalendar? calendar,
    required List<PeriodTemplate> periods,
  }) {
    String? startLocal;
    String? endLocal;
    final calendarId = calendar?.id;
    if (calendarId != null) {
      for (final p in periods) {
        if (p.calendarId != calendarId) continue;
        if (p.periodNo == m.periodStart) startLocal = p.startLocal;
        if (p.periodNo == m.periodEnd) endLocal = p.endLocal;
      }
    }
    return {
      'id': m.id,
      'courseId': m.courseId,
      'weekday': m.weekday,
      'weekdayLabel': _weekdays[m.weekday - 1],
      'periodStart': m.periodStart,
      'periodEnd': m.periodEnd,
      'weeks': _weeksLabel(m.weekRule, calendar?.totalWeeks ?? 0),
      'weekRule': m.weekRule.toJson(),
      'startLocal': startLocal,
      'endLocal': endLocal,
    };
  }

  _LocalStamp _stampFromUtc(DateTime utc) {
    final local = userTime.localFromUtc(utc);
    return _LocalStamp(
      utc: _plainUtc(utc),
      dateLocal: userTime.localDateString(local),
      weekday: local.weekday,
      hour: local.hour,
      minute: local.minute,
    );
  }

  String _blockSummary(
    String prefix,
    _LocalStamp start,
    _LocalStamp end,
    String title,
    String? note,
  ) =>
      '$prefix ${start.dayLabel} ${start.hhmm}-${end.hhmm} [时间块] '
      '${_titleWithNote(title, note)}';

  ({DateTime startUtc, DateTime endUtc}) _readRange(
    Map<String, dynamic> args, {
    required int defaultDays,
    bool requireLocal = false,
  }) {
    final fromLocal = _optionalString(args['fromLocal'], 'fromLocal');
    final toLocal = _optionalString(args['toLocal'], 'toLocal');
    final startArg = _optionalString(args['start'], 'start');
    final endArg = _optionalString(args['end'], 'end');
    if (requireLocal && (fromLocal == null || toLocal == null)) {
      throw const _ToolError('需要 fromLocal 与 toLocal（本地日期或时间）');
    }
    final nowLocal = userTime.localFromUtc(DateTime.now().toUtc());

    DateTime start;
    if (startArg != null) {
      final parsed = DateTime.tryParse(startArg);
      if (parsed == null) {
        throw const _ToolError('start 应为 UTC RFC3339 时间');
      }
      start = parsed.toUtc();
    } else if (fromLocal != null) {
      start = _parseLocalStamp(fromLocal, 'fromLocal').utc;
    } else {
      start = _plainUtc(
        userTime.fromLocalParts(
          nowLocal.year,
          nowLocal.month,
          nowLocal.day,
          0,
          0,
        ),
      );
    }

    DateTime end;
    if (endArg != null) {
      final parsed = DateTime.tryParse(endArg);
      if (parsed == null) {
        throw const _ToolError('end 应为 UTC RFC3339 时间');
      }
      end = parsed.toUtc();
    } else if (toLocal != null) {
      final stamp = _parseLocalStamp(toLocal, 'toLocal');
      if (toLocal.contains(':')) {
        end = stamp.utc;
      } else {
        final date = userTime.parseLocalDate(stamp.dateLocal)!;
        end = _plainUtc(userTime.localDateAfter(date, 1));
      }
    } else {
      final startLocal = userTime.localFromUtc(start);
      end = _plainUtc(userTime.localDateAfter(startLocal, defaultDays));
    }
    if (!end.isAfter(start)) {
      throw const _ToolError('结束时间必须晚于开始时间');
    }
    if (end.difference(start) > const Duration(days: 62)) {
      throw const _ToolError('时间范围不能超过 62 天');
    }
    return (startUtc: start, endUtc: end);
  }

  _LocalStamp _requireStamp(Map<String, dynamic> m, String key, String label) {
    final raw = m[key];
    if (raw is! String || raw.trim().isEmpty) {
      throw _ToolError('$label不能为空（YYYY-MM-DD HH:mm）');
    }
    return _parseLocalStamp(raw, label);
  }

  _LocalStamp? _optionalStamp(Object? value, String label) {
    if (value == null) return null;
    if (value is! String) throw _ToolError('$label 必须是字符串');
    if (value.trim().isEmpty) return null;
    return _parseLocalStamp(value, label);
  }

  _LocalStamp _parseLocalStamp(String raw, String label) {
    final match = _localStampPattern.firstMatch(raw.trim());
    if (match == null) {
      throw _ToolError('$label 应为用户时区的 YYYY-MM-DD HH:mm：$raw');
    }
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final hour = match[4] == null ? 0 : int.parse(match[4]!);
    final minute = match[5] == null ? 0 : int.parse(match[5]!);
    if (month < 1 ||
        month > 12 ||
        day < 1 ||
        day > 31 ||
        hour > 23 ||
        minute > 59) {
      throw _ToolError('$label 不是有效的本地时间：$raw');
    }
    final utc = userTime.utcFromLocalParts(year, month, day, hour, minute);
    final back = userTime.localFromUtc(utc);
    if (back.year != year ||
        back.month != month ||
        back.day != day ||
        back.hour != hour ||
        back.minute != minute) {
      throw _ToolError('$label 不是有效的本地时间：$raw');
    }
    return _LocalStamp(
      utc: utc,
      dateLocal: userTime.localDateString(back),
      weekday: back.weekday,
      hour: hour,
      minute: minute,
    );
  }

  _LocalStamp _parseLocalDateStrict(String raw, String label) {
    final text = raw.trim();
    if (!RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').hasMatch(text)) {
      throw _ToolError('$label 应为 YYYY-MM-DD：$raw');
    }
    return _parseLocalStamp(text, label);
  }

  ({_LocalStamp start, _LocalStamp end}) _parseRangeFrom(
    Map<String, dynamic> m,
    String label,
  ) {
    final start = _requireStamp(m, 'startLocal', '$label 开始时间');
    final end = _requireStamp(m, 'endLocal', '$label 结束时间');
    _ensureRange(start, end, label);
    return (start: start, end: end);
  }

  void _ensureRange(_LocalStamp start, _LocalStamp end, String label) {
    if (!end.utc.isAfter(start.utc)) {
      throw _ToolError('$label 结束时间必须晚于开始时间');
    }
    if (start.dateLocal != end.dateLocal) {
      throw _ToolError('$label 不能跨午夜（本地日期必须相同）');
    }
  }

  Map<String, dynamic> _normalizeTodoFields(Map<String, dynamic> fields) {
    const allowed = [
      'title',
      'type',
      'description',
      'categoryId',
      'tagIds',
      'priority',
      'status',
      'estimatedMinutes',
      'color',
      'deadlineLocal',
    ];
    for (final key in fields.keys) {
      if (!allowed.contains(key.toString())) {
        throw _ToolError('update_todo 不支持字段「$key」');
      }
    }
    final out = <String, dynamic>{};
    if (fields.containsKey('title')) {
      final title = _optionalString(fields['title'], 'title');
      if (title == null) throw const _ToolError('待办标题不能为空');
      out['title'] = title;
    }
    if (fields.containsKey('type')) {
      out['type'] = _enumValue(
        fields['type'],
        const ['one_off', 'project'],
        'one_off',
        'type',
      );
    }
    if (fields.containsKey('priority')) {
      out['priority'] = _enumValue(
        fields['priority'],
        const ['low', 'normal', 'high', 'urgent'],
        'normal',
        'priority',
      );
    }
    if (fields.containsKey('status')) {
      out['status'] = _enumValue(
        fields['status'],
        const ['todo', 'in_progress', 'completed', 'cancelled'],
        'todo',
        'status',
      );
    }
    if (fields.containsKey('description')) {
      out['description'] = _optionalString(
        fields['description'],
        'description',
      );
    }
    if (fields.containsKey('categoryId')) {
      out['categoryId'] = _optionalString(fields['categoryId'], 'categoryId');
    }
    if (fields.containsKey('color')) {
      out['color'] = _optionalString(fields['color'], 'color');
    }
    if (fields.containsKey('tagIds')) {
      out['tagIds'] = _stringList(fields['tagIds'], 'tagIds');
    }
    if (fields.containsKey('estimatedMinutes')) {
      out['estimatedMinutes'] = _optionalInt(
        fields['estimatedMinutes'],
        'estimatedMinutes',
      );
    }
    if (fields.containsKey('deadlineLocal')) {
      final deadline = _optionalStamp(fields['deadlineLocal'], 'deadlineLocal');
      out['deadlineAt'] = deadline == null ? null : formatUtc(deadline.utc);
    }
    if (out.isEmpty) {
      throw const _ToolError('没有需要修改的字段');
    }
    return out;
  }
}

// ---- static schema ----------------------------------------------------------

final List<Map<String, dynamic>> _schemas = <Map<String, dynamic>>[
  _fn('get_current_time', '获取当前时间：UTC、用户时区本地时间、星期，以及当前激活学期的名称与第几周。', const {}),
  _fn(
    'get_calendar',
    '获取所有学期（AcademicCalendar）及每个学期的节次时间表（PeriodTemplate，'
        '如第 1 节 08:00-08:45）。',
    const {},
  ),
  _fn('get_courses', '查询课程及每周上课安排（Course + CourseMeeting）。', {
    'calendarId': _str('可选，按学期 ID 过滤；不传表示全部学期'),
  }),
  _fn('get_schedule', '查询指定时间范围内展开后的全部日历事件：课程、周期日程、时间块与截止时间。', {
    'fromLocal': _str('起始本地日期或时间，YYYY-MM-DD 或 YYYY-MM-DD HH:mm；默认今天 00:00'),
    'toLocal': _str('结束本地日期或时间（不含）；YYYY-MM-DD 表示包含该日整天；默认 7 天后'),
    'start': _str('可选，UTC RFC3339 起始时间（优先于 fromLocal）'),
    'end': _str('可选，UTC RFC3339 结束时间（优先于 toLocal）'),
  }),
  _fn('get_todos', '按状态、类型、分类或关键词查询待办及其已排期的时间块（TodoBlock）。', {
    'status': _str(
      '状态过滤',
      enumValues: ['todo', 'in_progress', 'completed', 'cancelled'],
    ),
    'type': _str('类型过滤', enumValues: ['one_off', 'project']),
    'categoryId': _str('可选，按分类 ID 过滤'),
    'query': _str('可选，在标题与描述中搜索关键词'),
  }),
  _fn(
    'get_free_slots',
    '查询一段时间内每日 08:00-22:30 的空闲时段，已自动避开课程、周期日程与已有时间块。'
        '给待办排期前必须先调用本工具，不得凭空捏造空闲时间。',
    {
      'fromLocal': _str('起始本地日期或时间，YYYY-MM-DD 或 YYYY-MM-DD HH:mm'),
      'toLocal': _str('结束本地日期或时间（不含）；YYYY-MM-DD 表示包含该日整天'),
      'minDurationMinutes': _int('最短空闲分钟数，默认 30', minimum: 1),
      'dayStartMinute': _int(
        '每日可排期起始分钟（0-1440），默认 480 即 08:00',
        minimum: 0,
        maximum: 1440,
      ),
      'dayEndMinute': _int(
        '每日可排期结束分钟（0-1440），默认 1350 即 22:30',
        minimum: 0,
        maximum: 1440,
      ),
    },
    const ['fromLocal', 'toLocal'],
  ),
  _fn('get_tags_and_categories', '获取已有标签（Tag）与待办分类（Category）列表。', const {}),
  _fn(
    'propose_changes',
    '生成待用户确认的变更集（Change Set），不会立即写入数据库。'
        '一次用户请求涉及的所有创建、修改、删除必须放在同一次调用中，'
        '等待用户点「全部确认」后由系统原子执行。\n'
        '支持的 kind：\n'
        '- create_todo：title 必填；可选 type(one_off|project)、'
        'priority(low|normal|high|urgent)、status、deadlineLocal(YYYY-MM-DD HH:mm)、'
        'categoryId、tagIds、description、estimatedMinutes、color；'
        'blocks:[{startLocal,endLocal,blockNote}] 可在创建的同时排期。\n'
        '- update_todo：todoId 必填；fields 可含 title/type/priority/status/description/'
        'categoryId/tagIds/estimatedMinutes/color/deadlineLocal。\n'
        '- delete_todo：todoId。\n'
        '- create_todo_block：todoId、startLocal、endLocal，可选 blockNote、status。\n'
        '- update_todo_block：blockId；可含 startLocal、endLocal、blockNote、status。\n'
        '- delete_todo_block：blockId。\n'
        '- create_course：name 必填；可选 calendarId/teacher/location/color/notes；'
        'meetings:[{weekday(1-7),periodStart,periodEnd,weeks("1-16" 或 "1-5,7-11单")}]。\n'
        '- update_course：courseId；fields 可含 name/teacher/location/color/notes。\n'
        '- delete_course：courseId。\n'
        '- move_course_occurrence：seriesType(course_meeting|recurring_schedule)、'
        'seriesId、occurrenceDateLocal(YYYY-MM-DD)、newStartLocal、newEndLocal；只改单次课。\n'
        '- cancel_course_occurrence：seriesType、seriesId、occurrenceDateLocal；只停单次课。\n'
        '- create_recurring_schedule：title、weekday(1-7)、weeks，并提供 '
        'periodStart/periodEnd（按节次）或 startLocal/endLocal（自定义时间）；'
        '可选 calendarId/color/notes。\n'
        '- update_recurring_schedule：scheduleId；fields 可含 title/color/notes/weekday/'
        'weekdays/periodStart/periodEnd/weeks/startLocal/endLocal。\n'
        '- delete_recurring_schedule：scheduleId。\n'
        '所有时间均为用户时区的本地时间 `YYYY-MM-DD HH:mm`，单个时间块/调课不得跨午夜。'
        '已有 ID 必须来自 get_* 工具，严禁编造。与课程或已有时间块的冲突会在返回中标注，但不会阻断。',
    {
      'changes': {
        'type': 'array',
        'description': '变更列表，按顺序原子应用',
        'items': {
          'type': 'object',
          'properties': {
            'kind': _str(
              '变更类型',
              enumValues: [
                'create_todo',
                'update_todo',
                'delete_todo',
                'create_todo_block',
                'update_todo_block',
                'delete_todo_block',
                'create_course',
                'update_course',
                'delete_course',
                'move_course_occurrence',
                'cancel_course_occurrence',
                'create_recurring_schedule',
                'update_recurring_schedule',
                'delete_recurring_schedule',
              ],
            ),
            'title': _str('标题'),
            'todoId': _str('待办 ID'),
            'blockId': _str('时间块 ID'),
            'courseId': _str('课程 ID'),
            'scheduleId': _str('周期日程 ID'),
            'seriesType': _str(
              '系列类型',
              enumValues: ['course_meeting', 'recurring_schedule'],
            ),
            'seriesId': _str('课次/周期日程系列 ID'),
            'occurrenceDateLocal': _str('单次课的原本地日期 YYYY-MM-DD'),
            'startLocal': _str('本地开始时间 YYYY-MM-DD HH:mm'),
            'endLocal': _str('本地结束时间 YYYY-MM-DD HH:mm'),
            'newStartLocal': _str('调课后的本地开始时间'),
            'newEndLocal': _str('调课后的本地结束时间'),
            'blockNote': _str('时间块阶段目标'),
            'deadlineLocal': _str('截止/提醒本地时间'),
            'type': _str('待办类型', enumValues: ['one_off', 'project']),
            'priority': _str(
              '优先级',
              enumValues: ['low', 'normal', 'high', 'urgent'],
            ),
            'status': _str('状态'),
            'categoryId': _str('分类 ID'),
            'tagIds': _arr('标签 ID 数组', _str('标签 ID')),
            'description': _str('描述'),
            'estimatedMinutes': _int('预计分钟数', minimum: 1),
            'color': _str('颜色'),
            'notes': _str('备注'),
            'teacher': _str('教师'),
            'location': _str('地点'),
            'calendarId': _str('学期 ID'),
            'weekday': _int('星期，1=周一..7=周日', minimum: 1, maximum: 7),
            'weeks': _str('周次规则，如 1-16 或 1-5,7-11单'),
            'periodStart': _int('开始节次', minimum: 1),
            'periodEnd': _int('结束节次', minimum: 1),
            'fields': {'type': 'object', 'description': '更新字段集合'},
            'blocks': {
              'type': 'array',
              'description': 'create_todo 时同时创建的时间块',
              'items': {
                'type': 'object',
                'properties': {
                  'startLocal': _str('本地开始时间 YYYY-MM-DD HH:mm'),
                  'endLocal': _str('本地结束时间 YYYY-MM-DD HH:mm'),
                  'blockNote': _str('阶段目标'),
                },
                'required': ['startLocal', 'endLocal'],
              },
            },
            'meetings': {
              'type': 'array',
              'description': 'create_course 的每周上课安排',
              'items': {
                'type': 'object',
                'properties': {
                  'weekday': _int('星期，1=周一..7=周日', minimum: 1, maximum: 7),
                  'periodStart': _int('开始节次', minimum: 1),
                  'periodEnd': _int('结束节次', minimum: 1),
                  'weeks': _str('周次规则，如 1-16'),
                },
                'required': ['weekday', 'periodStart', 'periodEnd'],
              },
            },
          },
          'required': ['kind'],
        },
      },
    },
    const ['changes'],
  ),
];

Map<String, dynamic> _fn(
  String name,
  String description,
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) => {
  'type': 'function',
  'function': {
    'name': name,
    'description': description,
    'parameters': {
      'type': 'object',
      'properties': properties,
      'required': required,
    },
  },
};

Map<String, dynamic> _str(String description, {List<String>? enumValues}) => {
  'type': 'string',
  'description': description,
  'enum': ?enumValues,
};

Map<String, dynamic> _int(String description, {int? minimum, int? maximum}) => {
  'type': 'integer',
  'description': description,
  'minimum': ?minimum,
  'maximum': ?maximum,
};

Map<String, dynamic> _arr(String description, Map<String, dynamic> items) => {
  'type': 'array',
  'description': description,
  'items': items,
};

// ---- private value types ----------------------------------------------------

class _ToolError implements Exception {
  const _ToolError(this.message);
  final String message;
}

class _LocalStamp {
  const _LocalStamp({
    required this.utc,
    required this.dateLocal,
    required this.weekday,
    required this.hour,
    required this.minute,
  });

  final DateTime utc;
  final String dateLocal;
  final int weekday;
  final int hour;
  final int minute;

  String get hhmm => '${_two(hour)}:${_two(minute)}';

  String get dayLabel =>
      '${_weekdays[weekday - 1]}(${dateLocal.substring(5).replaceFirst('-', '/')})';

  String get label => '$dayLabel $hhmm';
}

class _ChangeContext {
  _ChangeContext({
    required this.snapshot,
    required this.todos,
    required this.blocks,
    required this.courses,
    required this.meetings,
    required this.schedules,
    required this.calendars,
    required this.periods,
  });

  final EntitiesSnapshot snapshot;
  final Map<String, Todo> todos;
  final Map<String, TodoBlock> blocks;
  final Map<String, Course> courses;
  final Map<String, CourseMeeting> meetings;
  final Map<String, RecurringSchedule> schedules;
  final List<AcademicCalendar> calendars;
  final List<PeriodTemplate> periods;

  /// Blocks proposed earlier in the same change set, used for intra-set
  /// overlap warnings.
  final List<({String title, DateTime start, DateTime end})> plannedBlocks = [];
}

// ---- small helpers ----------------------------------------------------------

const _weekdays = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

final _localStampPattern = RegExp(
  r'^(\d{4})-(\d{1,2})-(\d{1,2})(?:[ T](\d{1,2}):(\d{2})(?::(\d{2}))?)?$',
);

final _hhmmPattern = RegExp(r'^(\d{1,2}):(\d{2})$');

String _two(int n) => n.toString().padLeft(2, '0');

String _hhmm(int minuteOfDay) =>
    '${_two(minuteOfDay ~/ 60)}:${_two(minuteOfDay % 60)}';

String _hm(({int hour, int minute}) hm) =>
    '${_two(hm.hour)}:${_two(hm.minute)}';

int? _hhmmMinutes(String? value) {
  if (value == null) return null;
  final match = _hhmmPattern.firstMatch(value.trim());
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  if (hour > 23 || minute > 59) return null;
  return hour * 60 + minute;
}

String _weeksLabel(WeekRule rule, int totalWeeks) {
  if (rule.isEmpty || rule.isEveryWeek) return '每周';
  return rule.describe();
}

String _titleWithNote(String title, String? note) {
  final text = note?.trim();
  if (text == null || text.isEmpty) return title;
  return '$title：$text';
}

String? _joinWarnings(List<String> warnings) {
  final unique = _dedupe(warnings);
  return unique.isEmpty ? null : unique.join('\n');
}

List<String> _dedupe(List<String> values) {
  final seen = <String>{};
  final out = <String>[];
  for (final v in values) {
    if (v.isEmpty) continue;
    if (seen.add(v)) out.add(v);
  }
  return out;
}

String _conflictMessage(EventType type, String title) {
  switch (type) {
    case EventType.course:
      return '⚠️ 与课程「$title」时间冲突';
    case EventType.recurringSchedule:
      return '⚠️ 与日程「$title」时间冲突';
    case EventType.todoBlock:
      return '⚠️ 与已有时间块「$title」重叠';
    case EventType.deadline:
      return '';
  }
}

String _requireText(Map<String, dynamic> m, String key, String label) {
  final value = m[key];
  if (value is! String || value.trim().isEmpty) {
    throw _ToolError('$label不能为空');
  }
  return value.trim();
}

String? _optionalString(Object? value, String label) {
  if (value == null) return null;
  if (value is! String) {
    throw _ToolError('$label 必须是字符串');
  }
  final text = value.trim();
  return text.isEmpty ? null : text;
}

String? _optionalEnum(Object? value, List<String> allowed, String label) {
  if (value == null) return null;
  if (value is! String || !allowed.contains(value.trim())) {
    throw _ToolError('$label 必须是 ${allowed.join(' / ')}');
  }
  return value.trim();
}

String _enumValue(
  Object? value,
  List<String> allowed,
  String fallback,
  String label,
) => _optionalEnum(value, allowed, label) ?? fallback;

int? _optionalInt(Object? value, String label) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    if (value.trim().isEmpty) return null;
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  throw _ToolError('$label 必须是整数');
}

int _asInt(Object? value, String label) {
  final parsed = _optionalInt(value, label);
  if (parsed == null) {
    throw _ToolError('$label 必须是整数');
  }
  return parsed;
}

int _requireInt(Map<String, dynamic> m, String key, String label) =>
    _asInt(m[key], label);

List<String> _stringList(Object? value, String label) {
  if (value == null) return const [];
  if (value is! List) {
    throw _ToolError('$label 必须是字符串数组');
  }
  final out = <String>[];
  for (final entry in value) {
    if (entry is! String) {
      throw _ToolError('$label 必须是字符串数组');
    }
    out.add(entry);
  }
  return out;
}

WeekRule _parseWeeks(Object? value, String label) {
  if (value == null) return const WeekRule();
  if (value is! String) {
    throw _ToolError('$label 必须是字符串，如 1-16');
  }
  final text = value.trim();
  if (text.isEmpty) return const WeekRule();
  final rule = parseWeekRuleText(text);
  if (rule == null) {
    throw _ToolError('$label 无法解析：$value（示例 1-16 或 1-5,7-11单）');
  }
  return rule;
}

({int hour, int minute}) _requireHm(
  Map<String, dynamic> m,
  String key,
  String label,
) {
  final raw = m[key];
  if (raw == null) {
    throw _ToolError('$label不能为空（HH:mm）');
  }
  if (raw is! String) {
    throw _ToolError('$label 格式应为 HH:mm');
  }
  final match = _hhmmPattern.firstMatch(raw.trim());
  if (match == null) {
    throw _ToolError('$label 格式应为 HH:mm：$raw');
  }
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  if (hour > 23 || minute > 59) {
    throw _ToolError('$label 不是有效时间：$raw');
  }
  return (hour: hour, minute: minute);
}

// ---- small helpers ----------------------------------------------------------

List<String> _fieldLabels(Map<String, dynamic> fields) => [
  for (final key in fields.keys) _todoFieldLabel(key.toString()),
];

String _todoFieldLabel(String key) {
  switch (key) {
    case 'title':
      return '标题';
    case 'type':
      return '类型';
    case 'description':
      return '描述';
    case 'categoryId':
      return '分类';
    case 'tagIds':
      return '标签';
    case 'priority':
      return '优先级';
    case 'status':
      return '状态';
    case 'estimatedMinutes':
      return '预计时长';
    case 'color':
      return '颜色';
    case 'deadlineAt':
    case 'deadlineLocal':
      return '截止时间';
    case 'name':
      return '名称';
    case 'teacher':
      return '教师';
    case 'location':
      return '地点';
    case 'notes':
      return '备注';
    default:
      return key;
  }
}

String _recurringFieldLabel(String key) {
  switch (key) {
    case 'weekday':
    case 'weekdays':
      return '星期';
    case 'periodStart':
    case 'periodEnd':
      return '节次';
    case 'weeks':
      return '周次';
    case 'startLocal':
    case 'endLocal':
      return '时间';
    default:
      return key;
  }
}

DateTime _plainUtc(DateTime value) => DateTime.fromMillisecondsSinceEpoch(
  value.millisecondsSinceEpoch,
  isUtc: true,
);

DateTime _isoUtc(Object? value) {
  if (value is! String) {
    throw const _ToolError('缺少时间参数');
  }
  final parsed = DateTime.tryParse(value);
  if (parsed == null) {
    throw _ToolError('时间格式无法识别：$value');
  }
  return parsed.toUtc();
}
