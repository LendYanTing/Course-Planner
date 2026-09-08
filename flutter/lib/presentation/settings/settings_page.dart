import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/entities.dart';
import '../../state/app_services.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';

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
            leading: const Icon(Icons.cloud_sync_outlined),
            title: Text(sync.syncing ? '正在同步…' : '同步状态'),
            subtitle: Text(
              [
                if (pending > 0) '$pending 条待上传',
                sync.lastError == null ? '' : '上次出错: ${sync.lastError}',
                sync.lastSyncAt == null ? '尚未同步' : '上次同步: ${_time(sync.lastSyncAt!)}',
              ].where((s) => s.isNotEmpty).join(' · '),
            ),
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
              children: [
                for (final c in conflicts)
                  Card(
                    margin: const EdgeInsets.all(8),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${c.entityType} · ${c.entityId.substring(0, 8)}',
                              style: const TextStyle(fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Text('冲突字段：${c.conflictingFields.join(', ')}',
                              style: const TextStyle(fontSize: 12, color: Colors.grey)),
                          const SizedBox(height: 8),
                          Row(children: [
                            Expanded(
                              child: OutlinedButton(
                                onPressed: () =>
                                    ref.read(syncCoordinatorProvider.notifier).resolveConflict(c, keepLocal: false),
                                child: const Text('保留云端'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: FilledButton(
                                onPressed: () =>
                                    ref.read(syncCoordinatorProvider.notifier).resolveConflict(c, keepLocal: true),
                                child: const Text('保留本地'),
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
                  ExpansionTile(
                    leading: const Icon(Icons.calendar_month),
                    title: Text('${cal.value.name}${cal.pending ? ' ⏳' : ''}'),
                    subtitle: Text('${cal.value.totalWeeks} 周 · 起始 ${cal.value.firstDay}'),
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
                            TextButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('添加节次'),
                              onPressed: () => showModalBottomSheet(
                                context: context,
                                builder: (_) => PeriodEditor(calendarId: cal.value.id),
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
                  ),
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
class PeriodEditor extends ConsumerStatefulWidget {
  const PeriodEditor({super.key, required this.calendarId});

  final String calendarId;

  @override
  ConsumerState<PeriodEditor> createState() => _PeriodEditorState();
}

class _PeriodEditorState extends ConsumerState<PeriodEditor> {
  final _no = TextEditingController(text: '1');
  TimeOfDay _start = const TimeOfDay(hour: 8, minute: 0);
  TimeOfDay _end = const TimeOfDay(hour: 8, minute: 45);

  @override
  void dispose() {
    _no.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    String fmt(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('添加节次', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(controller: _no, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '节次编号')),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('开始'),
                subtitle: Text(fmt(_start)),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: _start);
                  if (t != null) setState(() => _start = t);
                },
              ),
            ),
            Expanded(
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('结束'),
                subtitle: Text(fmt(_end)),
                onTap: () async {
                  final t = await showTimePicker(context: context, initialTime: _end);
                  if (t != null) setState(() => _end = t);
                },
              ),
            ),
          ]),
          FilledButton(
            onPressed: () async {
              final minutes = (_start.hour * 60 + _start.minute);
              final minutesEnd = (_end.hour * 60 + _end.minute);
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
