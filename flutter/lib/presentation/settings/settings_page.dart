import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/error/api_exception.dart';
import '../../core/time/user_time.dart';
import '../../core/util/json_utils.dart';
import '../../data/local/entities_snapshot.dart';
import '../../data/local/sync_store.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/entities.dart';
import '../../state/app_services.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';

/// Row-height picker for the month grid.
Future<void> _pickMonthCellHeight(BuildContext context, WidgetRef ref) async {
  var value = ref.read(monthCellHeightProvider);
  final picked = await showDialog<double>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: const Text('月视图格子高度'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${value.round()} dp', style: const TextStyle(fontSize: 14)),
            Slider(
              value: value.clamp(MonthCellHeightController.minDp,
                  MonthCellHeightController.maxDp),
              min: MonthCellHeightController.minDp,
              max: MonthCellHeightController.maxDp,
              divisions: 13,
              label: '${value.round()}',
              onChanged: (v) => setLocal(() => value = v),
            ),
            const Text('格子越高，日期格里的条目显示得越完整；竖屏下方留白过多时调大即可。',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, value), child: const Text('保存')),
        ],
      ),
    ),
  );
  if (picked != null) await ref.read(monthCellHeightProvider.notifier).set(picked);
}

/// Shows the last sync failure in full. The text is selectable and copyable so
/// it can be pasted into a bug report.
Future<void> _showSyncDetail(BuildContext context, SyncUiState sync) async {
  final detail = sync.lastErrorDetail ?? sync.lastError ?? '(无详情)';
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('同步失败详情'),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: SelectableText(
            detail,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: detail));
            if (ctx.mounted) Navigator.pop(ctx);
            if (context.mounted) {
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('已复制报错详情')));
            }
          },
          child: const Text('复制'),
        ),
        FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
      ],
    ),
  );
}

/// Lets the user move the 上午/下午 boundary of the 课表 view. Purely local:
/// the server's period templates carry times but no notion of noon.
Future<void> _pickNoonBoundary(BuildContext context, WidgetRef ref) async {
  final current = ref.read(noonBoundaryProvider);
  const presets = <int>[11 * 60, 12 * 60, 13 * 60, 14 * 60, 14 * 60 + 30, 15 * 60];
  final picked = await showDialog<int>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: const Text('中午分界点'),
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text('课表中开始时刻早于此值的节次算上午，之后的算下午。',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
        ),
        for (final m in presets)
          ListTile(
            title: Text(formatMinuteOfDay(m)),
            trailing: current == m ? const Icon(Icons.check) : null,
            onTap: () => Navigator.pop(ctx, m),
          ),
        ListTile(
          leading: const Icon(Icons.more_time),
          title: const Text('自定义…'),
          onTap: () async {
            final t = await showTimePicker(
              context: ctx,
              initialTime: TimeOfDay(hour: current ~/ 60, minute: current % 60),
            );
            if (t != null && ctx.mounted) {
              Navigator.pop(ctx, t.hour * 60 + t.minute);
            }
          },
        ),
      ],
    ),
  );
  if (picked != null) {
    await ref.read(noonBoundaryProvider.notifier).set(picked);
  }
}

/// Writes a full local backup (working copy + operation queue + conflicts +
/// known servers + refresh tokens) and reports where it landed. The path is
/// shown and copyable because the app has no file-picker dependency.
Future<void> _exportBackup(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await ref.read(servicesProvider).backupService.export();
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('备份已导出'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${result.entityCount} 个实体 · ${result.pendingCount} 条待上传 · '
                '${result.conflictCount} 条冲突 · ${result.serverCount} 个服务器凭据 '
                '（${(result.bytes / 1024).toStringAsFixed(1)} KB）'),
            const SizedBox(height: 8),
            const Text('文件路径：', style: TextStyle(fontSize: 12, color: Colors.grey)),
            SelectableText(result.path, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            const Text('注意：文件包含登录凭据（refresh token），请妥善保管。',
                style: TextStyle(fontSize: 12, color: Colors.orange)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: result.path));
              if (ctx.mounted) Navigator.pop(ctx);
              messenger.showSnackBar(const SnackBar(content: Text('路径已复制')));
            },
            child: const Text('复制路径'),
          ),
          FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('好')),
        ],
      ),
    );
  } on Object catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('导出失败: ${e is ApiException ? e.message : e}')),
    );
  }
}

/// Settings hub (agents/flutter-agent.md §页面).
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final snap = ref.watch(snapshotProvider).value;
    final sync = ref.watch(syncCoordinatorProvider);
    final conflicts = snap?.conflicts ?? const [];
    final pending = snap?.pendingOps.length ?? 0;

    final profile = session.profile;

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        actions: [
          IconButton(
            onPressed: sync.syncing
                ? null
                : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
            icon: sync.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
        ],
      ),
      body: ListView(
        children: [
          ListTile(
            leading: CircleAvatar(child: Text(profile?.username.isNotEmpty == true ? profile!.username[0].toUpperCase() : '?')),
            title: Text(profile?.username ?? ''),
            subtitle: Text('时区：${profile?.timezone ?? '—'}（固定，不可修改）'),
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.sync_problem),
            title: const Text('冲突处理'),
            subtitle: Text(conflicts.isEmpty ? '无待处理冲突' : '${conflicts.length} 个字段冲突需要决定'),
            trailing: conflicts.isEmpty ? null : const Icon(Icons.chevron_right),
            onTap: conflicts.isEmpty ? null : () => context.push('/settings/conflicts'),
          ),
          ListTile(
            leading: Icon(
              sync.lastError == null ? Icons.cloud_sync_outlined : Icons.sync_problem,
              color: sync.lastError == null ? null : Theme.of(context).colorScheme.error,
            ),
            title: Text(sync.syncing ? '正在同步…' : '同步状态'),
            subtitle: Text(
              [
                if (pending > 0) '$pending 条待上传',
                sync.lastError == null ? '' : '上次出错: ${sync.lastError}',
                sync.lastSyncAt == null ? '尚未同步' : '上次同步: ${_time(sync.lastSyncAt!)}',
                if (sync.lastError != null) '点按查看详细报错',
              ].where((s) => s.isNotEmpty).join(' · '),
            ),
            // Tapping surfaces the full failure report (cursor, queue depth,
            // error code/status/message/details, stack) so a failure can be
            // copied out instead of needing a debugger attached.
            onTap: sync.lastError == null ? null : () => _showSyncDetail(context, sync),
            trailing: TextButton(
              onPressed: () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
              child: const Text('立即同步'),
            ),
          ),
          ListTile(
            leading: const Icon(Icons.refresh),
            title: const Text('硬刷新本地缓存'),
            subtitle: const Text('保留未上传修改，从服务器重建本地数据'),
            onTap: () async {
              final ok = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('硬刷新？'),
                  content: const Text('将清空本地缓存并按服务器重建（未上传的修改会保留并重放）。'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                    FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('硬刷新')),
                  ],
                ),
              );
              if (ok == true) {
                await ref.read(syncCoordinatorProvider.notifier).hardRefresh();
              }
            },
          ),
          const Divider(),
          const _SectionHeader('课程与学期'),
          ListTile(
            leading: const Icon(Icons.calendar_view_month),
            title: const Text('学期管理'),
            subtitle: const Text('创建学期与节次模板'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/semesters'),
          ),
          ListTile(
            leading: const Icon(Icons.school_outlined),
            title: const Text('课程管理'),
            subtitle: const Text('维护课程与每周上课安排'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/courses'),
          ),
          ListTile(
            leading: const Icon(Icons.event_repeat),
            title: const Text('周期安排'),
            subtitle: const Text('自定义重复日程（非课程）'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/schedules'),
          ),
          ListTile(
            leading: const Icon(Icons.upload_file),
            title: const Text('导入课程（CSV）'),
            subtitle: const Text('需要联网：解析 → 预览 → 确认提交'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/import'),
          ),
          const Divider(),
          const _SectionHeader('外观与界面'),
          ListTile(
            leading: const Icon(Icons.wb_twilight),
            title: const Text('中午分界点'),
            subtitle: Text(
              '${formatMinuteOfDay(ref.watch(noonBoundaryProvider))} · '
              '课表中早于此时刻的节次算上午（仅本地）',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickNoonBoundary(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.calendar_view_month),
            title: const Text('月视图格子高度'),
            subtitle: Text(
              '${ref.watch(monthCellHeightProvider).round()} dp · 竖屏留白过多时调大',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => _pickMonthCellHeight(context, ref),
          ),
          const Divider(),
          const _SectionHeader('服务器与数据'),
          ListTile(
            leading: const Icon(Icons.smart_toy_outlined),
            title: const Text('连接到 MCP'),
            subtitle: const Text('让 Agent 通过 MCP 读取/修改课表与待办'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/mcp'),
          ),
          ListTile(
            leading: const Icon(Icons.dns_outlined),
            title: const Text('服务器'),
            subtitle: Text(ref.watch(servicesProvider).http.baseUrl),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/server'),
          ),
          ListTile(
            leading: const Icon(Icons.archive_outlined),
            title: const Text('导出完整备份'),
            subtitle: const Text('将所有本地数据与登录凭据导出为 JSON 文件'),
            onTap: () => _exportBackup(context, ref),
          ),
          ListTile(
            leading: const Icon(Icons.unarchive_outlined),
            title: const Text('导入备份'),
            subtitle: const Text('可选导入服务器、登录凭据、学期课程、待办等'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/restore'),
          ),
          const Divider(),
          const _SectionHeader('标签与分类'),
          ListTile(
            leading: const Icon(Icons.label_outline),
            title: const Text('标签 / 分类'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => context.push('/settings/tags'),
          ),
          const Divider(),
          ListTile(
            leading: Icon(Icons.logout, color: Theme.of(context).colorScheme.error),
            title: Text('退出登录', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            onTap: () async {
              await ref.read(sessionControllerProvider.notifier).logout();
            },
          ),
          const SizedBox(height: 24),
          const Center(child: Text('Course Planner · Flutter', style: TextStyle(color: Colors.grey, fontSize: 12))),
        ],
      ),
    );
  }

  String _time(DateTime utc) {
    final l = utc.toLocal();
    return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(text, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.primary)),
    );
  }
}

/// Chinese labels for the sync entity types (conflict screen).
const _entityLabels = <String, String>{
  EntityTypes.calendar: '学期',
  EntityTypes.period: '节次',
  EntityTypes.course: '课程',
  EntityTypes.courseMeeting: '上课安排',
  EntityTypes.recurringSchedule: '周期安排',
  EntityTypes.todo: '待办',
  EntityTypes.todoBlock: '时间块',
  EntityTypes.tag: '标签',
  EntityTypes.category: '分类',
  EntityTypes.override: '单次调整',
};

/// Chinese labels for the fields that can conflict, so the conflict screen
/// shows "标题" rather than the raw wire name "title".
const _fieldLabels = <String, String>{
  'title': '标题',
  'name': '名称',
  'description': '描述',
  'status': '状态',
  'priority': '优先级',
  'type': '类型',
  'categoryId': '分类',
  'tagIds': '标签',
  'color': '颜色',
  'deadlineAt': '截止时间',
  'estimatedMinutes': '预计时长',
  'startAt': '开始时间',
  'endAt': '结束时间',
  'blockNote': '时间块备注',
  'startLocal': '开始时刻',
  'endLocal': '结束时刻',
  'periodNo': '节次编号',
  'firstDay': '第一周周一',
  'totalWeeks': '总周数',
  'weekday': '星期',
  'periodStart': '起始节次',
  'periodEnd': '结束节次',
  'location': '地点',
  'teacher': '教师',
  'notes': '备注',
};

String _entityLabel(String type) => _entityLabels[type] ?? type;

String _fieldLabel(String field) => _fieldLabels[field] ?? field;

/// Human-readable name of the entity a conflict is about, taken from the
/// payload (title/name), falling back to a short id.
String _conflictSubject(ConflictRecord c) {
  for (final payload in [c.local, c.server, c.base]) {
    final v = payload['title'] ?? payload['name'];
    if (v is String && v.isNotEmpty) return v;
  }
  final id = c.entityId;
  return id.length > 8 ? '${id.substring(0, 8)}…' : id;
}

const _weekdayChars = ['一', '二', '三', '四', '五', '六', '日'];

String _hhmmLocal(DateTime utc, UserTime? t) {
  final l = t?.localFromUtc(utc) ?? utc.toLocal();
  return '${l.month}/${l.day} '
      '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}';
}

/// Where the conflicting entity actually lives, resolved against the local
/// mirror. A `todo_block` payload only carries ids (`todoId`, `startAt`…), so
/// without this the user just sees an opaque uuid and cannot tell which of
/// their tasks is in conflict.
String _conflictOrigin(ConflictRecord c, EntitiesSnapshot? snap, UserTime? userTime) {
  Map<String, dynamic>? rowPayload(String type, String id) {
    if (snap == null) return null;
    for (final r in snap.rows) {
      if (r.entityType == type && r.entityId == id) return r.payload;
    }
    return null;
  }

  String? displayName(String type, String? id) {
    if (id == null) return null;
    final p = rowPayload(type, id);
    final v = p?['title'] ?? p?['name'];
    return v is String && v.isNotEmpty ? v : null;
  }

  // Prefer the local side of the conflict (the user's edit), else the server's.
  final ref = c.local.isNotEmpty ? c.local : c.server;
  final parts = <String>[];

  switch (c.entityType) {
    case EntityTypes.todoBlock:
      final todoTitle = displayName(EntityTypes.todo, ref['todoId'] as String?);
      if (todoTitle != null) parts.add('属于待办「$todoTitle」');
      final s = parseUtc(readStringOrNull(ref, 'startAt'));
      final e = parseUtc(readStringOrNull(ref, 'endAt'));
      if (s != null && e != null) {
        parts.add('安排在 ${_hhmmLocal(s, userTime)} – ${_hhmmLocal(e, userTime)}');
      }
      if (ref['blockNote'] is String && (ref['blockNote'] as String).isNotEmpty) {
        parts.add('备注「${ref['blockNote']}」');
      }
    case EntityTypes.courseMeeting:
      final courseName = displayName(EntityTypes.course, ref['courseId'] as String?);
      final calName = displayName(EntityTypes.calendar, ref['calendarId'] as String?);
      if (courseName != null) parts.add('属于课程「$courseName」');
      final wd = ref['weekday'];
      if (wd is num && wd.toInt() >= 1 && wd.toInt() <= 7) {
        parts.add('每周${_weekdayChars[wd.toInt() - 1]}');
      }
      final ps = ref['periodStart'], pe = ref['periodEnd'];
      if (ps is num && pe is num) {
        parts.add(ps == pe ? '第${ps.toInt()}节' : '第${ps.toInt()}–${pe.toInt()}节');
      }
      if (calName != null) parts.add('学期「$calName」');
    case EntityTypes.period:
      final no = ref['periodNo'];
      final sl = ref['startLocal'], el = ref['endLocal'];
      if (no is num) parts.add('第${no.toInt()}节');
      if (sl is String && el is String) parts.add('$sl–$el');
      final calName = displayName(EntityTypes.calendar, ref['calendarId'] as String?);
      if (calName != null) parts.add('学期「$calName」');
    case EntityTypes.override:
      final st = ref['seriesType'];
      final sid = ref['seriesId'];
      final date = ref['occurrenceDateLocal'];
      if (st is String) {
        final seriesName = displayName(
          st == 'course_meeting' ? EntityTypes.courseMeeting : EntityTypes.recurringSchedule,
          sid is String ? sid : null,
        );
        parts.add(seriesName == null ? '单次调整（$st）' : '单次调整「$seriesName」');
      }
      if (date is String) parts.add('日期 $date');
    case EntityTypes.course:
      final calName = displayName(EntityTypes.calendar, ref['calendarId'] as String?);
      if (calName != null) parts.add('学期「$calName」');
      if (ref['teacher'] is String) parts.add('教师 ${ref['teacher']}');
      if (ref['location'] is String) parts.add('地点 ${ref['location']}');
    default:
      break;
  }

  if (parts.isEmpty) return 'id ${c.entityId}';
  return parts.join(' · ');
}

/// Renders one field's local vs server value compactly.
String _displayValue(Object? v) {
  if (v == null) return '（空）';
  if (v is bool) return v ? '是' : '否';
  if (v is List) return v.isEmpty ? '（空）' : v.join('、');
  if (v is Map) return v.isEmpty ? '（空）' : jsonEncode(v);
  return '$v';
}

/// Conflict resolution screen (docs/sync-protocol.md §12).
class ConflictsPage extends ConsumerWidget {
  const ConflictsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(snapshotProvider).value;
    final conflicts = snap?.conflicts ?? const [];

    return Scaffold(
      appBar: AppBar(title: const Text('冲突处理')),
      body: conflicts.isEmpty
          ? const Center(child: Text('没有待处理的冲突'))
          : ListView(
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                for (final c in conflicts)
                  Card(
                    margin: const EdgeInsets.all(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.merge_type, size: 18),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  '${_entityLabel(c.entityType)}「${_conflictSubject(c)}」',
                                  style: const TextStyle(fontWeight: FontWeight.bold),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _conflictOrigin(c, snap, ref.watch(userTimeProvider)),
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          const Text('以下字段两边都改过，选择要保留的版本：',
                              style: TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(height: 6),
                          for (final f in c.conflictingFields)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(_fieldLabel(f),
                                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                                  const SizedBox(height: 2),
                                  _ValueRow(
                                    label: '本次修改',
                                    value: _displayValue(c.local[f]),
                                    highlight: true,
                                  ),
                                  _ValueRow(
                                    label: '服务器',
                                    value: _displayValue(c.server[f]),
                                    highlight: false,
                                  ),
                                ],
                              ),
                            ),
                          const SizedBox(height: 10),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    ref.read(syncCoordinatorProvider.notifier).resolveConflict(c, keepLocal: false),
                                child: const Text('保留服务器'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () =>
                                    ref.read(syncCoordinatorProvider.notifier).resolveConflict(c, keepLocal: true),
                                child: const Text('保留本次修改'),
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value, required this.highlight});

  final String label;
  final String value;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: highlight ? Theme.of(context).colorScheme.primary : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Term (semester) manager with period templates (docs/domain-model.md §2-3).
class SemestersPage extends ConsumerWidget {
  const SemestersPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(snapshotProvider).value;
    final calendars = snap == null ? <Live<AcademicCalendar>>[] : liveCalendars(snap);
    final periods = snap == null ? <Live<PeriodTemplate>>[] : livePeriods(snap);
    final periodsByCal = <String, List<PeriodTemplate>>{};
    for (final p in periods) {
      periodsByCal.putIfAbsent(p.value.calendarId, () => []).add(p.value);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('学期管理')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          builder: (_) => const SemesterEditor(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建学期'),
      ),
      body: calendars.isEmpty
          ? const Center(child: Text('还没有学期。先创建一个学期（含第一周日期）'))
          : ListView(
              children: [
                for (final cal in calendars)
                  Builder(builder: (context) {
                  final isActive =
                      ref.watch(activeSemesterProvider) == cal.value.id;
                  return ExpansionTile(
                    leading: Icon(
                      isActive ? Icons.radio_button_checked : Icons.calendar_month,
                      color: isActive ? Theme.of(context).colorScheme.primary : null,
                    ),
                    title: Text('${cal.value.name}${cal.pending ? ' ⏳' : ''}'),
                    subtitle: Text(
                      '${cal.value.totalWeeks} 周 · 起始 ${cal.value.firstDay}'
                      '${isActive ? ' · 课表当前使用' : ''}',
                    ),
                    children: [
                      for (final p in periodsByCal[cal.value.id] ?? const [])
                        ListTile(
                          dense: true,
                          leading: const Icon(Icons.schedule, size: 18),
                          title: Text('第 ${p.periodNo} 节'),
                          subtitle: Text('${p.startLocal} – ${p.endLocal}'),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () => ref.read(servicesProvider).repo.localDelete(
                                  entityType: EntityTypes.period,
                                  entityId: p.id,
                                ),
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Row(
                          children: [
                            if (!isActive)
                              TextButton.icon(
                                icon: const Icon(Icons.check_circle_outline),
                                label: const Text('设为课表学期'),
                                onPressed: () => ref
                                    .read(activeSemesterProvider.notifier)
                                    .set(cal.value.id),
                              ),
                            TextButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('添加节次'),
                              onPressed: () => showModalBottomSheet(
                                context: context,
                                builder: (_) => PeriodEditor(
                                  calendarId: cal.value.id,
                                  existing: periodsByCal[cal.value.id] ?? const [],
                                ),
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.edit_outlined),
                              label: const Text('编辑学期'),
                              onPressed: () => showModalBottomSheet(
                                context: context,
                                isScrollControlled: true,
                                builder: (_) => SemesterEditor(existing: cal.value),
                              ),
                            ),
                            IconButton(
                              icon: const Icon(Icons.delete),
                              onPressed: () => ref.read(servicesProvider).repo
                                  .localDelete(entityType: EntityTypes.calendar, entityId: cal.value.id),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                  }),
              ],
            ),
    );
  }
}

/// Semester create/edit form.
class SemesterEditor extends ConsumerStatefulWidget {
  const SemesterEditor({super.key, this.existing});

  final AcademicCalendar? existing;

  @override
  ConsumerState<SemesterEditor> createState() => _SemesterEditorState();
}

class _SemesterEditorState extends ConsumerState<SemesterEditor> {
  late final TextEditingController _name;
  late final TextEditingController _weeks;
  DateTime? _firstDay;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _weeks = TextEditingController(text: widget.existing?.totalWeeks.toString() ?? '16');
    _firstDay = widget.existing == null
        ? DateTime(DateTime.now().year, 9, 1)
        : _parseYmd(widget.existing!.firstDay);
  }

  static DateTime? _parseYmd(String ymd) {
    final p = ymd.split('-');
    if (p.length != 3) return null;
    final y = int.tryParse(p[0]);
    final m = int.tryParse(p[1]);
    final d = int.tryParse(p[2]);
    if (y == null || m == null || d == null) return null;
    return DateTime(y, m, d);
  }

  @override
  void dispose() {
    _name.dispose();
    _weeks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(isEdit ? '编辑学期' : '新建学期', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: _name, decoration: const InputDecoration(labelText: '名称（如 2026 秋季）')),
          const SizedBox(height: 10),
          TextField(controller: _weeks, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '总周数')),
          const SizedBox(height: 10),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.event),
            title: const Text('第一周周一'),
            subtitle: Text(_firstDay == null ? '' : '${_firstDay!.year}-${_firstDay!.month.toString().padLeft(2, '0')}-${_firstDay!.day.toString().padLeft(2, '0')}'),
            trailing: const Icon(Icons.edit_calendar),
            onTap: () async {
              final d = await showDatePicker(
                context: context,
                initialDate: _firstDay ?? DateTime.now(),
                firstDate: DateTime(2020),
                lastDate: DateTime(2040),
              );
              if (d != null) setState(() => _firstDay = d);
            },
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final repo = ref.read(servicesProvider).repo;
    final firstDay = _firstDay == null
        ? null
        : '${_firstDay!.year.toString().padLeft(4, '0')}-${_firstDay!.month.toString().padLeft(2, '0')}-${_firstDay!.day.toString().padLeft(2, '0')}';
    final totalWeeks = int.tryParse(_weeks.text.trim()) ?? 16;
    if (firstDay == null) return;
    if (widget.existing == null) {
      await repo.localCreate(
        entityType: EntityTypes.calendar,
        snapshot: {'name': _name.text.trim(), 'firstDay': firstDay, 'totalWeeks': totalWeeks},
      );
    } else {
      await repo.localUpdate(
        entityType: EntityTypes.calendar,
        entityId: widget.existing!.id,
        changes: {'name': _name.text.trim(), 'firstDay': firstDay, 'totalWeeks': totalWeeks},
      );
    }
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}

/// One period template form.
/// Defaults for the **next** period of a semester.
///
/// The number continues after the highest existing one, and the time starts
/// `gapMinutes` (10) after the latest period ends — the usual class break —
/// instead of always defaulting to 08:00. The duration follows the previous
/// period so a timetable keeps a consistent rhythm.
///
/// The latest period is picked by start time (not by number) so a
/// re-numbered timetable still chains correctly.
({int periodNo, int startMinute, int endMinute}) nextPeriodDefaults(
  List<PeriodTemplate> existing, {
  int gapMinutes = 10,
  int fallbackStartMinute = 8 * 60,
  int fallbackDuration = 45,
}) {
  if (existing.isEmpty) {
    return (
      periodNo: 1,
      startMinute: fallbackStartMinute,
      endMinute: fallbackStartMinute + fallbackDuration,
    );
  }
  final byStart = [...existing]..sort((a, b) => a.startMinute.compareTo(b.startMinute));
  final last = byStart.last;
  final duration = (last.endMinute - last.startMinute).clamp(5, 24 * 60);
  // max+1 rather than count+1: if a period in the middle was deleted, count+1
  // would collide with an existing number.
  final periodNo = existing.map((p) => p.periodNo).reduce(math.max) + 1;
  final start = math.min(last.endMinute + gapMinutes, 23 * 60 + 54);
  final end = math.min(start + duration, 23 * 60 + 59);
  return (periodNo: periodNo, startMinute: start, endMinute: end);
}

class PeriodEditor extends ConsumerStatefulWidget {
  const PeriodEditor({
    super.key,
    required this.calendarId,
    this.existing = const [],
  });

  final String calendarId;

  /// Periods already defined for this semester — used to prefill the form so
  /// adding the 2nd, 3rd, … period needs no retyping.
  final List<PeriodTemplate> existing;

  @override
  ConsumerState<PeriodEditor> createState() => _PeriodEditorState();
}

class _PeriodEditorState extends ConsumerState<PeriodEditor> {
  late final TextEditingController _no;
  late TimeOfDay _start;
  late TimeOfDay _end;
  late final int _duration;
  String? _previousLabel;

  static int _toMinutes(TimeOfDay t) => t.hour * 60 + t.minute;

  static TimeOfDay _toTimeOfDay(int minutes) {
    final m = minutes.clamp(0, 23 * 60 + 59);
    return TimeOfDay(hour: m ~/ 60, minute: m % 60);
  }

  static String _fmt(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    final d = nextPeriodDefaults(widget.existing);
    _duration = d.endMinute - d.startMinute;
    _no = TextEditingController(text: '${d.periodNo}');
    _start = _toTimeOfDay(d.startMinute);
    _end = _toTimeOfDay(d.endMinute);
    if (widget.existing.isNotEmpty) {
      final byStart = [...widget.existing]
        ..sort((a, b) => a.startMinute.compareTo(b.startMinute));
      final last = byStart.last;
      _previousLabel = '上一节 ${_fmt(_toTimeOfDay(last.startMinute))}–${last.endLocal}';
    }
  }

  @override
  void dispose() {
    _no.dispose();
    super.dispose();
  }

  Future<void> _pickStart() async {
    final t = await showTimePicker(context: context, initialTime: _start);
    if (t == null || !mounted) return;
    setState(() {
      _start = t;
      // Keep the period a valid length: if the new start has overtaken the end,
      // re-derive the end from the previous period's duration.
      if (_toMinutes(_end) <= _toMinutes(t)) {
        _end = _toTimeOfDay(_toMinutes(t) + _duration);
      }
    });
  }

  Future<void> _pickEnd() async {
    final t = await showTimePicker(context: context, initialTime: _end);
    if (t == null || !mounted) return;
    setState(() => _end = t);
  }

  @override
  Widget build(BuildContext context) {
    final fmt = _fmt;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('添加节次', style: Theme.of(context).textTheme.titleMedium),
          if (_previousLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '$_previousLabel · 已按「下课 + 10 分钟」预填',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _no,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: '节次编号（自动顺延）'),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开始'),
                subtitle: Text(fmt(_start)),
                onTap: _pickStart,
              ),
            ),
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('结束'),
                subtitle: Text(fmt(_end)),
                onTap: _pickEnd,
              ),
            ),
          ]),
          FilledButton(
            onPressed: () async {
              final minutes = _toMinutes(_start);
              final minutesEnd = _toMinutes(_end);
              if (minutesEnd <= minutes) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('节次不能跨午夜或结束早于开始')));
                return;
              }
              final nav = Navigator.of(context);
              await ref.read(servicesProvider).repo.localCreate(
                entityType: EntityTypes.period,
                snapshot: {
                  'calendarId': widget.calendarId,
                  'periodNo': int.tryParse(_no.text.trim()) ?? 1,
                  'startLocal': fmt(_start),
                  'endLocal': fmt(_end),
                },
              );
              ref.read(syncCoordinatorProvider.notifier).syncNow();
              nav.pop();
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
