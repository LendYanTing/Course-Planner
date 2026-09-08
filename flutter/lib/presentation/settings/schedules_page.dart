import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/util/week_text.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/entities.dart';
import '../../domain/schedule.dart';
import '../../domain/week_rule.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';
import 'courses_page.dart' show kPalette;

/// Recurring schedule manager (docs/domain-model.md §6).
class SchedulesPage extends ConsumerWidget {
  const SchedulesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(snapshotProvider).value;
    final schedules = snap == null ? <Live<RecurringSchedule>>[] : liveSchedules(snap);

    return Scaffold(
      appBar: AppBar(title: const Text('周期安排')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => const ScheduleEditor(),
        ),
        icon: const Icon(Icons.add),
        label: const Text('新建安排'),
      ),
      body: schedules.isEmpty
          ? const Center(child: Text('还没有周期安排'))
          : ListView(
              children: [
                for (final s in schedules)
                  ListTile(
                    leading: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: AppTheme.parseHex(s.value.color) ?? AppTheme.scheduleColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    title: Text('${s.value.title}${s.pending ? ' ⏳' : ''}'),
                    subtitle: Text(_describe(s.value.rule)),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      onPressed: () {
                        ref.read(servicesProvider).repo
                            .localDelete(entityType: EntityTypes.recurringSchedule, entityId: s.value.id);
                        ref.read(syncCoordinatorProvider.notifier).syncNow();
                      },
                    ),
                  ),
              ],
            ),
    );
  }

  String _describe(ScheduleRule rule) {
    switch (rule.kind) {
      case ScheduleRuleKind.daily:
        return '每天 ${rule.startLocal}–${rule.endLocal} · ${rule.dateStart} 至 ${rule.dateEnd}';
      case ScheduleRuleKind.weekly:
        final wd = ['一', '二', '三', '四', '五', '六', '日']
            .asMap()
            .entries
            .where((e) => rule.weekdays.contains(e.key + 1))
            .map((e) => '周${e.value}')
            .join('、');
        return '$wd ${rule.startLocal}–${rule.endLocal} · ${rule.dateStart} 至 ${rule.dateEnd}';
      case ScheduleRuleKind.byAcademicWeek:
        return '按学期周次（${rule.weekRule?.describe() ?? '?'}）';
    }
  }
}

class ScheduleEditor extends ConsumerStatefulWidget {
  const ScheduleEditor({super.key});

  @override
  ConsumerState<ScheduleEditor> createState() => _ScheduleEditorState();
}

class _ScheduleEditorState extends ConsumerState<ScheduleEditor> {
  final _title = TextEditingController();
  ScheduleRuleKind _kind = ScheduleRuleKind.weekly;
  String _startTime = '08:00';
  String _endTime = '09:00';
  final Set<int> _weekdays = {1};
  final _startDate = TextEditingController();
  final _endDate = TextEditingController();
  String? _calendarId;
  String _weeksText = '';
  int _periodStart = 1;
  int _periodEnd = 1;
  String? _color;
  bool _usePeriods = true;

  @override
  void dispose() {
    _title.dispose();
    _startDate.dispose();
    _endDate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final calendars = snap == null ? <Live<AcademicCalendar>>[] : liveCalendars(snap);

    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('新建周期安排', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: _title, decoration: const InputDecoration(labelText: '标题')),
            const SizedBox(height: 10),
            DropdownButtonFormField<ScheduleRuleKind>(
              initialValue: _kind,
              decoration: const InputDecoration(labelText: '重复方式'),
              items: const [
                DropdownMenuItem(value: ScheduleRuleKind.weekly, child: Text('每周（自定义日期区间）')),
                DropdownMenuItem(value: ScheduleRuleKind.daily, child: Text('每天（自定义日期区间）')),
                DropdownMenuItem(value: ScheduleRuleKind.byAcademicWeek, child: Text('按学期周次')),
              ],
              onChanged: (v) => setState(() => _kind = v ?? ScheduleRuleKind.weekly),
            ),
            const SizedBox(height: 10),
            if (_kind == ScheduleRuleKind.byAcademicWeek) ...[
              if (calendars.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _calendarId ?? calendars.first.value.id,
                  decoration: const InputDecoration(labelText: '学期'),
                  items: [for (final c in calendars) DropdownMenuItem(value: c.value.id, child: Text(c.value.name))],
                  onChanged: (v) => setState(() => _calendarId = v),
                ),
              Row(children: [
                Expanded(
                  child: CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('使用节次', style: TextStyle(fontSize: 13)),
                    value: _usePeriods,
                    onChanged: (v) => setState(() => _usePeriods = v ?? true),
                  ),
                ),
                if (!_usePeriods)
                  Expanded(
                    child: Row(children: [
                      Expanded(
                        child: _TimeField(label: '开始', value: _startTime, onChanged: (v) => _startTime = v),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: _TimeField(label: '结束', value: _endTime, onChanged: (v) => _endTime = v),
                      ),
                    ]),
                  ),
              ]),
              if (_usePeriods)
                Row(children: [
                  Expanded(
                    child: TextField(
                      onChanged: (v) => _periodStart = int.tryParse(v) ?? 1,
                      decoration: const InputDecoration(labelText: '开始节次'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      onChanged: (v) => _periodEnd = int.tryParse(v) ?? 1,
                      decoration: const InputDecoration(labelText: '结束节次'),
                      keyboardType: TextInputType.number,
                    ),
                  ),
                ]),
              const SizedBox(height: 10),
              TextField(
                onChanged: (v) => _weeksText = v,
                decoration: const InputDecoration(labelText: '周次规则', helperText: '如 1-16 或 1-8单'),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 4,
                children: [
                  for (var i = 0; i < 7; i++)
                    FilterChip(
                      label: Text('周${'一二三四五六日'[i]}'),
                      selected: _weekdays.contains(i + 1),
                      onSelected: (v) => setState(() {
                        if (v) {
                          _weekdays.add(i + 1);
                        } else {
                          _weekdays.remove(i + 1);
                        }
                      }),
                    ),
                ],
              ),
            ] else ...[
              Row(children: [
                Expanded(child: _TimeField(label: '开始', value: _startTime, onChanged: (v) => _startTime = v)),
                const SizedBox(width: 10),
                Expanded(child: _TimeField(label: '结束', value: _endTime, onChanged: (v) => _endTime = v)),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: TextField(controller: _startDate, decoration: const InputDecoration(labelText: '开始日期 YYYY-MM-DD')),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(controller: _endDate, decoration: const InputDecoration(labelText: '结束日期 YYYY-MM-DD')),
                ),
              ]),
              if (_kind == ScheduleRuleKind.weekly) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 4,
                  children: [
                    for (var i = 0; i < 7; i++)
                      FilterChip(
                        label: Text('周${'一二三四五六日'[i]}'),
                        selected: _weekdays.contains(i + 1),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _weekdays.add(i + 1);
                          } else {
                            _weekdays.remove(i + 1);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final hex in kPalette)
                  InkWell(
                    onTap: () => setState(() => _color = hex),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppTheme.parseHex(hex),
                        shape: BoxShape.circle,
                        border: Border.all(color: _color == hex ? Colors.black : Colors.transparent, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: _save, child: const Text('保存')),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final rule = <String, dynamic>{};
    if (_kind == ScheduleRuleKind.byAcademicWeek) {
      final weekRule = _weeksText.trim().isEmpty
          ? WeekRule([WeekSegment(start: 1, end: 200, parity: WeekParity.all)])
          : parseWeekRuleText(_weeksText);
      if (weekRule == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('周次规则无法解析')));
        return;
      }
      rule['kind'] = _kind.wire;
      rule['calendarId'] = _calendarId;
      rule['weekdays'] = (_weekdays.toList()..sort());
      rule['weekRule'] = weekRule.toJson();
      if (_usePeriods) {
        rule['periodStart'] = _periodStart;
        rule['periodEnd'] = _periodEnd;
      } else {
        rule['startLocal'] = _startTime;
        rule['endLocal'] = _endTime;
      }
    } else {
      final dateStart = _startDate.text.trim();
      final dateEnd = _endDate.text.trim();
      if (dateStart.isEmpty || dateEnd.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请输入开始与结束日期 YYYY-MM-DD')));
        return;
      }
      rule['kind'] = _kind.wire;
      rule['startLocal'] = _startTime;
      rule['endLocal'] = _endTime;
      if (_kind == ScheduleRuleKind.weekly) {
        rule['weekdays'] = _weekdays.toList()..sort();
      }
      rule['dateStart'] = dateStart;
      rule['dateEnd'] = dateEnd;
    }
    await ref.read(servicesProvider).repo.localCreate(
      entityType: EntityTypes.recurringSchedule,
      snapshot: {'title': title, 'color': _color, 'rule': rule, 'notes': null},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}

class _TimeField extends StatelessWidget {
  const _TimeField({required this.label, required this.value, required this.onChanged});

  final String label;
  final String value;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextField(
      onChanged: onChanged,
      decoration: InputDecoration(labelText: label, hintText: 'HH:MM'),
      controller: TextEditingController(text: value),
      keyboardType: TextInputType.datetime,
    );
  }
}
