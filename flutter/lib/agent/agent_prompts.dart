import '../core/time/user_time.dart';
import '../data/local/entities_snapshot.dart';
import '../data/local/view_models.dart';
import '../domain/calendar.dart';
import '../sync/expander.dart';

/// High-frequency prompts offered on the empty chat screen (phase 5 Step 3).
/// Kept as plain strings so the chat sheet renders them without extra models.
const kAgentQuickPrompts = <String>[
  '📅 总结我今天和明天的课程与待办',
  '🧩 帮我把未排期的待办自动安排到本周空闲时间',
  '🔍 看看我这周有哪些超过 2 小时的空闲时段',
  '📥 粘贴课表文本/HTML 帮我解析导入课程',
];

const _weekdayLabels = <String>[
  '星期一',
  '星期二',
  '星期三',
  '星期四',
  '星期五',
  '星期六',
  '星期日',
];

/// Builds the agent's Chinese system prompt, injecting the live environment
/// (docs/plans/v1/phase-5-builtin-agent.md Step 3):
///
/// * the user's fixed timezone and current local time/weekday,
/// * the active semester (or the first semester that has period templates),
///   its first day, total weeks and the current week,
/// * that semester's period table, so "周四第 3-4 节" can be resolved,
/// * the four behaviour rules (read first, split work into blocks, one Change
///   Set per request, convert natural-language times locally),
/// * [extra], the user's own additions.
///
/// [preferredCalendarId] comes from `activeSemesterProvider`; the function
/// itself stays pure so it can be unit-tested without a container.
String buildAgentSystemPrompt({
  required UserTime userTime,
  required EntitiesSnapshot snapshot,
  required DateTime nowUtc,
  String extra = '',
  String? preferredCalendarId,
}) {
  final nowLocal = userTime.localFromUtc(nowUtc);
  final calendars = liveCalendars(snapshot).map((e) => e.value).toList();
  final periods = livePeriods(snapshot).map((e) => e.value).toList();

  final active = _activeCalendar(
    calendars: calendars,
    periods: periods,
    preferredCalendarId: preferredCalendarId,
  );
  final activePeriods = <PeriodTemplate>[
    if (active != null)
      for (final p in periods)
        if (p.calendarId == active.id) p,
  ]..sort((a, b) => a.periodNo.compareTo(b.periodNo));

  final b = StringBuffer()
    ..writeln('你是 Course Planner 的内置智能日程与课表助手。')
    ..writeln()
    ..writeln('【当前环境上下文】')
    ..writeln(
      '- 当前本地时间：${userTime.formatDateYmdHm(nowUtc)}'
      '（${_weekdayLabels[(nowLocal.weekday - 1).clamp(0, 6).toInt()]}）',
    )
    ..writeln('- 今天的日期：${userTime.localDateString(nowLocal)}')
    ..writeln('- 用户固定时区：${userTime.ianaName}')
    ..write(_semesterLine(active, userTime, nowLocal, periods))
    ..writeln('- 学期节次时间表：')
    ..write(_periodsSummary(activePeriods))
    ..writeln()
    ..writeln('【核心行为准则】')
    ..writeln(
      '1. 读操作先行：当用户要求安排任务、询问日程或调整课表时，'
      '必须先调用 `get_todos`、`get_schedule` 或 `get_free_slots` 了解现状，'
      '严禁凭空捏造时间、课程 ID 或空闲时段。',
    )
    ..writeln(
      '2. 智能拆块排期：当用户需要安排大型任务/作业/复习'
      '（例如“帮我安排本周完成生化大作业，大概需要 4 小时”）：',
    )
    ..writeln('   - 先调用 `get_free_slots` 查找截止时间前的空闲时段；')
    ..writeln(
      '   - 将任务合理拆分为多个 45~120 分钟的 `todo_block`，'
      '每个时间块写明具体的阶段目标 `blockNote`'
      '（如“1. 查资料与列提纲”、“2. 主体撰写”、“3. 润色与检查”）；',
    )
    ..writeln(
      '   - 默认避开所有已有课程和日程，优先安排在 08:00–22:30 之间，'
      '严禁跨午夜（例如 23:00 → 次日 01:00）。',
    )
    ..writeln(
      '3. 一次性批量确认：一个用户请求涉及的所有创建、修改、删除操作，'
      '必须合并到一次 `propose_changes` 调用中提交给用户确认，'
      '绝不能分多次零散提交，也不要在用户确认前声称已经完成。',
    )
    ..writeln(
      '4. 自然语言时间换算：用户说的“明天下午三点”“这周四第 3-4 节”'
      '“下周一”，一律根据上方【当前环境上下文】中的本地日期和节次时间表'
      '精准换算为 `YYYY-MM-DD HH:mm`，不得改用设备时区。',
    )
    ..writeln()
    ..writeln('【工具与约束】')
    ..writeln(
      '- 只读工具可直接调用；写入一律通过 `propose_changes`，'
      '等待用户在卡片上确认后由系统执行。',
    )
    ..writeln('- 不得修改用户时区；所有时间都是用户时区的本地时间。')
    ..writeln(
      '- 修改周期性对象时必须明确范围（this / this_and_future / all）；'
      '用户语义不明确时，把范围作为确认内容的一部分，不要自行扩大。',
    )
    ..writeln('- 如果确实需要覆盖课程，必须在变更说明中明确告警冲突。');

  final trimmedExtra = extra.trim();
  if (trimmedExtra.isNotEmpty) {
    b
      ..writeln()
      ..writeln('【用户自定义偏好】')
      ..writeln(trimmedExtra);
  }
  return b.toString();
}

AcademicCalendar? _activeCalendar({
  required List<AcademicCalendar> calendars,
  required List<PeriodTemplate> periods,
  String? preferredCalendarId,
}) {
  if (preferredCalendarId != null && preferredCalendarId.isNotEmpty) {
    for (final c in calendars) {
      if (c.id == preferredCalendarId) return c;
    }
  }
  for (final c in calendars) {
    if (periods.any((p) => p.calendarId == c.id)) return c;
  }
  return calendars.isEmpty ? null : calendars.first;
}

String _semesterLine(
  AcademicCalendar? active,
  UserTime userTime,
  DateTime nowLocal,
  List<PeriodTemplate> allPeriods,
) {
  if (active == null) {
    return '- 当前激活学期：未设置（可在“设置 → 学期管理”中添加）\n';
  }
  final week = EventExpander(
    userTime,
  ).weekOf(active.firstDay, userTime.localDateString(nowLocal));
  final String weekLabel;
  if (week < 1) {
    weekLabel = '尚未开学（第 1 周从 ${active.firstDay} 开始）';
  } else if (week > active.totalWeeks) {
    weekLabel = '学期外（学期共 ${active.totalWeeks} 周，当前已结束）';
  } else {
    weekLabel = '第 $week 周';
  }
  final hasPeriods = allPeriods.any((p) => p.calendarId == active.id);
  return '- 当前激活学期：${active.name}'
      '（第一周周一：${active.firstDay}，共 ${active.totalWeeks} 周，'
      '当前为 $weekLabel）'
      '${hasPeriods ? '' : '（该学期尚未设置节次时间表）'}\n';
}

String _periodsSummary(List<PeriodTemplate> periods) {
  if (periods.isEmpty) return '  未设置节次时间表\n';
  final b = StringBuffer();
  for (final p in periods) {
    b.writeln('  ${p.periodNo}: ${p.startLocal}-${p.endLocal}');
  }
  return b.toString();
}
