import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/api/import_api.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/local_csv_import.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';
import '../adaptive/adaptive.dart';

/// Course CSV import (docs/csv-import.md). Flow: upload → parse → validate →
/// preview → user confirms → commit. Parsing/validation are server-side.
class ImportPage extends ConsumerStatefulWidget {
  const ImportPage({super.key});

  @override
  ConsumerState<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends ConsumerState<ImportPage> {
  String? _calendarId;
  final _csv = TextEditingController();
  bool _busy = false;
  bool _autoCreatePeriods = true;
  CourseCsvPreview? _preview;
  List<CsvFieldError>? _errors;

  @override
  void dispose() {
    _csv.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final calendars = snap == null ? <Live<AcademicCalendar>>[] : liveCalendars(snap);
    _calendarId ??= calendars.isNotEmpty ? calendars.first.value.id : null;

    return Scaffold(
      appBar: AppTopBar(title: '导入课程（CSV）'),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (calendars.isEmpty)
              const Text('请先在「学期管理」中创建学期再导入')
            else ...[
              DropdownButtonFormField<String>(
                initialValue: _calendarId,
                decoration: const InputDecoration(labelText: '导入到学期'),
                items: [for (final c in calendars) DropdownMenuItem(value: c.value.id, child: Text(c.value.name))],
                onChanged: (v) => setState(() {
                  _calendarId = v;
                  _preview = null;
                }),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _csv,
                maxLines: 8,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'CSV 内容',
                  hintText: '课程名称,星期,开始节数,结束节数,老师,地点,周数\n高等数学,1,1,2,小明,逸夫楼201,1-16',
                  alignLabelWithHint: true,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                '列：课程名称,星期,开始节数,结束节数,老师,地点,周数\n周数支持：1-16、2、5、8、1-5、7-11单、12-16双（分隔符可用 、 ， 空格）',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy || _calendarId == null ? null : _previewAndConfirm,
                child: Text(_busy ? '处理中…' : '解析并预览'),
              ),
              if (_errors != null && _errors!.isNotEmpty) ...[
                const SizedBox(height: 16),
                AppCard(
                  padding: EdgeInsets.zero,
                  margin: const EdgeInsets.all(4),
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('校验失败：', style: TextStyle(fontWeight: FontWeight.bold)),
                        for (final e in _errors!)
                          Text('第${e.line}行 ${e.field}: ${e.message}', style: const TextStyle(fontSize: 12)),
                      ],
                    ),
                  ),
                ),
              ],
              if (_preview != null) ...[
                const SizedBox(height: 16),
                AppCard(
                  padding: EdgeInsets.zero,
                  margin: const EdgeInsets.all(4),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('解析出 ${_preview!.courses.length} 门课程', style: Theme.of(context).textTheme.titleSmall),
                        for (final c in _preview!.courses)
                          ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            title: Text(c.name),
                            subtitle: Text(
                              '第${c.weekday}周${c.periodStart}–${c.periodEnd}节 · 周次 ${c.weekRuleText ?? ''}'
                              '${c.teacher != null && c.teacher!.isNotEmpty ? ' · ${c.teacher}' : ''}',
                            ),
                          ),
                        const SizedBox(height: 8),
                        CheckboxListTile(
                          value: _autoCreatePeriods,
                          onChanged: (v) => setState(() => _autoCreatePeriods = v ?? true),
                          contentPadding: EdgeInsets.zero,
                          dense: true,
                          controlAffinity: ListTileControlAffinity.leading,
                          title: const Text('自动补齐缺失的节次模板', style: TextStyle(fontSize: 13)),
                          subtitle: const Text('按 45 分钟一节、课间 10 分钟补齐', style: TextStyle(fontSize: 11)),
                        ),
                        FilledButton(
                          onPressed: _busy ? null : _commit,
                          child: const Text('确认导入'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            AppCard(
              padding: EdgeInsets.zero,
              margin: EdgeInsets.zero,
              child: ListTile(
                leading: const Icon(Icons.travel_explore),
                title: const Text('从学校教务系统智能导入'),
                subtitle: const Text('粘贴教务网页 / AI 解析，自动补齐节次与配色'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/edu-import'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _previewAndConfirm() async {
    setState(() {
      _busy = true;
      _preview = null;
      _errors = null;
    });
    final snap = ref.read(snapshotProvider).value;
    final calendar = snap == null
        ? null
        : liveCalendars(snap)
            .where((c) => c.value.id == _calendarId)
            .map((c) => c.value)
            .firstOrNull;
    if (snap == null || calendar == null) {
      setState(() => _busy = false);
      return;
    }
    final periods =
        livePeriods(snap, calendarId: _calendarId).map((e) => e.value).toList();
    // Parsing and validation are local (docs/plans/v1 phase 1): the CSV never
    // leaves the device, and the whole flow works offline.
    final result = LocalCsvImporter.parseAndValidate(
      csv: _csv.text,
      calendarId: _calendarId!,
      calendar: calendar,
      periods: periods,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _preview = result.preview;
      _errors = result.errors.isEmpty ? null : result.errors;
    });
  }

  Future<void> _commit() async {
    setState(() => _busy = true);
    final services = ref.read(servicesProvider);
    final snap = ref.read(snapshotProvider).value;
    final periods = snap == null
        ? <PeriodTemplate>[]
        : livePeriods(snap, calendarId: _calendarId).map((e) => e.value).toList();
    // Colours already in use this semester, so imported courses stand apart
    // from the existing ones instead of all sharing the default shade.
    final existingColors = snap == null
        ? const <String?>[]
        : liveCourses(snap, calendarId: _calendarId)
            .map((e) => e.value.color)
            .toList();
    try {
      final written = await LocalCsvImporter.commit(
        repo: services.repo,
        preview: _preview!,
        calendarId: _calendarId!,
        periods: periods,
        autoCreatePeriods: _autoCreatePeriods,
        existingColors: existingColors,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('成功导入 $written 门课程')),
      );
      Navigator.of(context).pop();
    } on Object catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('导入失败: $e')));
      setState(() => _busy = false);
    }
  }
}
