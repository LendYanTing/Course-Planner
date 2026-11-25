import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../agent/agent_config.dart';
import '../../agent/llm_client.dart';
import '../../app/theme.dart';
import '../../core/theme/course_palette.dart';
import '../../data/api/import_api.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/edu_import/edu_ai_extractor.dart';
import '../../domain/edu_import/edu_html_parser.dart';
import '../../domain/entities.dart';
import '../../domain/local_csv_import.dart';
import '../../state/app_services.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../adaptive/adaptive.dart';

/// Which input the user is working with.
enum _SourceMode { paste, url }

const _weekdayLabels = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

/// Education-system import (docs/plans/v1/phase-6-voice-and-edu-import.md
/// Step 2).
///
/// A single page walks the whole flow: pick (or create) a semester, paste the
/// timetable page / new Zhengfang JSON / copied text (or fetch a public URL),
/// run the local parser or the built-in agent as a fallback, review the rows,
/// then write them through the same local CSV pipeline as the CSV import page.
class EduImportPage extends ConsumerStatefulWidget {
  const EduImportPage({super.key});

  @override
  ConsumerState<EduImportPage> createState() => _EduImportPageState();
}

class _EduImportPageState extends ConsumerState<EduImportPage> {
  static const _defaultPeriods = 12;
  static const _defaultWeeks = 20;

  String? _calendarId;
  final TextEditingController _raw = TextEditingController();
  final TextEditingController _url = TextEditingController();

  _SourceMode _mode = _SourceMode.paste;
  List<ParsedCsvCourse> _courses = const [];
  List<String?> _previewColors = const [];
  String? _source;
  bool _clearExisting = false;
  bool _busy = false;
  String? _busyLabel;
  int _errorCount = 0;

  @override
  void dispose() {
    _raw.dispose();
    _url.dispose();
    super.dispose();
  }

  // ---- helpers --------------------------------------------------------------

  static String _hhmm(int minute) {
    final h = (minute ~/ 60).toString().padLeft(2, '0');
    final m = (minute % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  /// The selected semester, defaulting to the active one, then the first.
  AcademicCalendar? _resolveCalendar(
    List<Live<AcademicCalendar>> calendars,
    String? activeId,
  ) {
    if (calendars.isEmpty) {
      // Keep a just-created id: the snapshot stream may not have emitted the
      // new semester yet, and wiping it here would lose the selection.
      return null;
    }
    for (final cal in calendars) {
      if (cal.value.id == _calendarId) return cal.value;
    }
    AcademicCalendar? preferred;
    for (final cal in calendars) {
      if (cal.value.id == activeId) preferred = cal.value;
    }
    preferred ??= calendars.first.value;
    _calendarId = preferred.id;
    return preferred;
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  String _describe(ParsedCsvCourse course) {
    final weekday = _weekdayLabels[(course.weekday - 1).clamp(0, 6)];
    final periods = course.periodStart == course.periodEnd
        ? '第${course.periodStart}节'
        : '第${course.periodStart}-${course.periodEnd}节';
    final parts = <String>['$weekday $periods'];
    final weeks = course.weekRuleText?.trim() ?? '';
    if (weeks.isNotEmpty) parts.add('周次 $weeks');
    if (course.teacher?.trim().isNotEmpty ?? false) {
      parts.add(course.teacher!.trim());
    }
    if (course.location?.trim().isNotEmpty ?? false) {
      parts.add(course.location!.trim());
    }
    return parts.join(' · ');
  }

  /// Quotes a CSV field when it carries a separator, quote or newline.
  static String _csvField(String? value) {
    final text = value?.trim() ?? '';
    if (text.contains(',') ||
        text.contains('"') ||
        text.contains('\n') ||
        text.contains('\r')) {
      return '"${text.replaceAll('"', '""')}"';
    }
    return text;
  }

  String _buildCsv(AcademicCalendar calendar) {
    final buffer = StringBuffer(
      'name,weekday,periodStart,periodEnd,teacher,location,weeks\n',
    );
    for (final course in _courses) {
      final weeks = (course.weekRuleText?.trim().isNotEmpty ?? false)
          ? course.weekRuleText!.trim()
          : '1-${calendar.totalWeeks}';
      buffer.writeln(
        [
          _csvField(course.name),
          '${course.weekday}',
          '${course.periodStart}',
          '${course.periodEnd}',
          _csvField(course.teacher),
          _csvField(course.location),
          _csvField(weeks),
        ].join(','),
      );
    }
    return buffer.toString();
  }

  void _adoptCourses(List<ParsedCsvCourse> courses, String source) {
    final colors = <String?>[];
    for (var i = 0; i < courses.length; i++) {
      colors.add(CoursePalette.pickDistinctColor(colors));
    }
    setState(() {
      _courses = courses;
      _previewColors = colors;
      _source = source;
      _errorCount = 0;
    });
  }

  // ---- create semester ------------------------------------------------------

  Future<void> _createCurrentSemester() async {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) {
      _snack('无法确定用户时区，请先在设置中完成账号/时区配置');
      return;
    }
    final nowUtc = ref.read(serverNowProvider).value ?? DateTime.now().toUtc();
    final local = userTime.localFromUtc(nowUtc);
    // Monday of the current local week: the semester's week 1 start.
    final monday = userTime.fromLocalParts(
      local.year,
      local.month,
      local.day - (local.weekday - 1),
      0,
      0,
    );
    final spring = monday.month >= 2 && monday.month <= 7;
    final name = '${monday.year} ${spring ? '春季' : '秋季'}';

    setState(() {
      _busy = true;
      _busyLabel = '正在创建学期…';
    });
    try {
      final repo = ref.read(servicesProvider).repo;
      final calendarId = await repo.localCreate(
        entityType: EntityTypes.calendar,
        snapshot: {
          'name': name,
          'firstDay': userTime.localDateString(monday),
          'totalWeeks': _defaultWeeks,
        },
      );
      for (var n = 1; n <= _defaultPeriods; n++) {
        final start = 8 * 60 + (n - 1) * 55;
        await repo.localCreate(
          entityType: EntityTypes.period,
          snapshot: {
            'calendarId': calendarId,
            'periodNo': n,
            'startLocal': _hhmm(start),
            'endLocal': _hhmm(start + 45),
          },
        );
      }
      if (!mounted) return;
      setState(() => _calendarId = calendarId);
      await ref.read(activeSemesterProvider.notifier).set(calendarId);
      if (!mounted) return;
      _snack('已创建学期「$name」与 $_defaultPeriods 个默认节次');
    } on Object catch (e) {
      _snack('创建学期失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  // ---- parsing --------------------------------------------------------------

  Future<void> _parseLocal() async {
    final raw = _raw.text.trim();
    if (raw.isEmpty) {
      _snack('请先粘贴教务网页、JSON 或课表文字');
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = '正在识别课表…';
    });
    try {
      final result = EduHtmlParser.parse(raw);
      if (!mounted) return;
      if (result.courses.isEmpty) {
        setState(() {
          _courses = const [];
          _previewColors = const [];
          _source = null;
          _errorCount = 0;
        });
        _snack('没有识别到课程，可尝试「使用 AI 深度解析」');
        return;
      }
      _adoptCourses(result.courses, '本地');
    } on Object catch (e) {
      _snack('识别失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _parseWithAi() async {
    final raw = _raw.text.trim();
    if (raw.isEmpty) {
      _snack('请先粘贴教务网页、JSON 或课表文字');
      return;
    }
    final config = ref.read(agentConfigProvider);
    if (!config.isConfigured) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('请先在「设置 → 内置 AI 助手」配置大模型'),
            action: SnackBarAction(
              label: '去配置',
              onPressed: () => context.push('/settings/agent'),
            ),
          ),
        );
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = 'AI 正在解析课表…';
    });
    try {
      final extractor = EduAiExtractor(client: LlmClient(), config: config);
      final courses = await extractor.extract(
        EduHtmlParser.stripHtmlForAi(raw),
      );
      if (!mounted) return;
      if (courses.isEmpty) {
        _snack('AI 没有提取到课程，请检查粘贴内容或更换模型');
        return;
      }
      _adoptCourses(courses, 'AI');
    } on LlmException catch (e) {
      _snack(e.message);
    } on Object catch (e) {
      _snack('AI 解析失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  Future<void> _fetchUrl() async {
    final url = _url.text.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      _snack('请输入以 http:// 或 https:// 开头的教务网址');
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = '正在抓取网页…';
    });
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          headers: const {'User-Agent': 'Mozilla/5.0 (CoursePlanner)'},
        ),
      );
      final response = await dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final body = response.data ?? '';
      if (body.trim().isEmpty) {
        _snack('网页内容为空，请确认网址是否正确');
        return;
      }
      if (!mounted) return;
      setState(() {
        _raw.text = body;
        _mode = _SourceMode.paste;
      });
    } on DioException catch (e) {
      final reason = switch (e.type) {
        DioExceptionType.connectionTimeout ||
        DioExceptionType.receiveTimeout => '连接超时，请检查网络',
        DioExceptionType.badResponse =>
          '服务器返回 ${e.response?.statusCode ?? '错误'}',
        _ => '无法访问该网址',
      };
      _snack('抓取失败：$reason（仅公开页面可抓取，需要登录的教务系统请复制粘贴）');
      return;
    } on Object catch (e) {
      _snack('抓取失败: $e');
      return;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
    if (!mounted) return;
    await _parseLocal();
  }

  // ---- commit ---------------------------------------------------------------

  Future<void> _confirmImport() async {
    final snap = ref.read(snapshotProvider).value;
    if (snap == null) return;
    AcademicCalendar? calendar;
    for (final cal in liveCalendars(snap)) {
      if (cal.value.id == _calendarId) calendar = cal.value;
    }
    if (calendar == null) {
      _snack('请先选择目标学期');
      return;
    }
    if (_courses.isEmpty) return;

    setState(() {
      _busy = true;
      _busyLabel = '正在导入…';
    });
    try {
      final periods = livePeriods(
        snap,
        calendarId: calendar.id,
      ).map((e) => e.value).toList();
      final result = LocalCsvImporter.parseAndValidate(
        csv: _buildCsv(calendar),
        calendarId: calendar.id,
        calendar: calendar,
        periods: periods,
      );
      if (result.errors.isNotEmpty || result.preview == null) {
        setState(() => _errorCount = result.errors.length);
        if (mounted) {
          await showAppDialog<void>(
            context: context,
            title: '无法导入',
            content: SizedBox(
              width: double.maxFinite,
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('请修正以下问题后重试：'),
                    const SizedBox(height: 6),
                    for (final error in result.errors)
                      Text(
                        '第${error.line}行 ${error.field}: ${error.message}',
                        style: const TextStyle(fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              FilledButton(
                onPressed: () =>
                    Navigator.of(context, rootNavigator: true).pop(),
                child: const Text('知道了'),
              ),
            ],
          );
        }
        return;
      }

      final repo = ref.read(servicesProvider).repo;
      if (_clearExisting) {
        final existing = liveCourses(snap, calendarId: calendar.id);
        for (final course in existing) {
          for (final meeting in liveMeetings(snap, courseId: course.value.id)) {
            await repo.localDelete(
              entityType: EntityTypes.courseMeeting,
              entityId: meeting.value.id,
            );
          }
          await repo.localDelete(
            entityType: EntityTypes.course,
            entityId: course.value.id,
          );
        }
      }
      final existingColors = _clearExisting
          ? const <String?>[]
          : liveCourses(
              snap,
              calendarId: calendar.id,
            ).map((e) => e.value.color).toList();
      final written = await LocalCsvImporter.commit(
        repo: repo,
        preview: result.preview!,
        calendarId: calendar.id,
        periods: periods,
        autoCreatePeriods: true,
        existingColors: existingColors,
      );
      if (!mounted) return;
      setState(() {
        _courses = const [];
        _previewColors = const [];
        _source = null;
        _errorCount = 0;
      });
      _snack('已导入 $written 门课程');
    } on Object catch (e) {
      _snack('导入失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  // ---- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final calendars = snap == null
        ? <Live<AcademicCalendar>>[]
        : liveCalendars(snap);
    final activeId = ref.watch(activeSemesterProvider);
    final selected = _resolveCalendar(calendars, activeId);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppTopBar(title: '从教务系统导入'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          // ---- 1. target semester -----------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('目标学期'),
                const SizedBox(height: 8),
                if (calendars.isEmpty) ...[
                  Text(
                    '还没有学期。可以一键创建本学期（含 12 节默认时间表），'
                    '导入后直接在课表查看。',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: _busy ? null : _createCurrentSemester,
                    icon: const Icon(Icons.auto_awesome),
                    label: const Text('一键创建当前学期'),
                  ),
                ] else ...[
                  DropdownButtonFormField<String>(
                    key: ValueKey('edu-calendar-${selected?.id}'),
                    initialValue: selected?.id,
                    decoration: const InputDecoration(labelText: '导入到学期'),
                    items: [
                      for (final cal in calendars)
                        DropdownMenuItem(
                          value: cal.value.id,
                          child: Text(cal.value.name),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (value) => setState(() {
                            _calendarId = value;
                            _errorCount = 0;
                          }),
                  ),
                  if (selected != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        '共 ${selected.totalWeeks} 周 · 起始 ${selected.firstDay}',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),

          // ---- 2. source ---------------------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('来源'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: const Text('粘贴网页/文本'),
                      selected: _mode == _SourceMode.paste,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _mode = _SourceMode.paste),
                    ),
                    ChoiceChip(
                      label: const Text('教务网址抓取'),
                      selected: _mode == _SourceMode.url,
                      onSelected: _busy
                          ? null
                          : (_) => setState(() => _mode = _SourceMode.url),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                if (_mode == _SourceMode.paste)
                  TextField(
                    controller: _raw,
                    readOnly: _busy,
                    minLines: 8,
                    maxLines: 8,
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      alignLabelWithHint: true,
                      hintText:
                          '可直接粘贴教务网页 HTML、新正方 JSON，'
                          '或在浏览器中全选复制的课表文字。',
                    ),
                  )
                else ...[
                  TextField(
                    controller: _url,
                    readOnly: _busy,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '教务网址',
                      hintText: 'https://jw.example.edu.cn/kbcx',
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '仅公开页面可抓取；需要登录的教务系统请用复制粘贴。',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.tonalIcon(
                    onPressed: _busy ? null : _fetchUrl,
                    icon: const Icon(Icons.download),
                    label: const Text('抓取并要求解析'),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _busy ? null : _parseLocal,
                        child: const Text('自动识别课表'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: _busy ? null : _parseWithAi,
                        child: const Text('使用 AI 深度解析'),
                      ),
                    ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 6),
                  Text(
                    _busyLabel ?? '处理中…',
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),

          // ---- 3. preview --------------------------------------------------
          if (_courses.isNotEmpty)
            AppCard(
              margin: const EdgeInsets.only(bottom: 12),
              padding: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '识别到 ${_courses.length} 门课'
                            '（来源：${_source ?? '本地'}）',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        if (_errorCount > 0)
                          Text(
                            '$_errorCount 个错误',
                            style: TextStyle(fontSize: 11, color: scheme.error),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    for (var i = 0; i < _courses.length; i++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color:
                                AppTheme.parseHex(_previewColors[i]) ??
                                scheme.primary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        title: Text(_courses[i].name),
                        subtitle: Text(_describe(_courses[i])),
                        trailing: IconButton(
                          tooltip: '删除此课程',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _courses = [
                                    for (var j = 0; j < _courses.length; j++)
                                      if (j != i) _courses[j],
                                  ];
                                  _previewColors = [
                                    for (
                                      var j = 0;
                                      j < _previewColors.length;
                                      j++
                                    )
                                      if (j != i) _previewColors[j],
                                  ];
                                }),
                        ),
                      ),
                    const Divider(height: 12),
                    CheckboxListTile(
                      value: _clearExisting,
                      onChanged: _busy
                          ? null
                          : (value) =>
                                setState(() => _clearExisting = value ?? false),
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      title: const Text(
                        '清空目标学期原有课程后导入',
                        style: TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ---- 4. confirm --------------------------------------------------
          if (_courses.isNotEmpty)
            AppCard(
              margin: EdgeInsets.zero,
              child: SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _confirmImport,
                  icon: const Icon(Icons.save_alt),
                  label: Text('确认导入 ${_courses.length} 门课程'),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }
}
