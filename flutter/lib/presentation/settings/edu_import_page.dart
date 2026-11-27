import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../agent/agent_config.dart';
import '../../agent/llm_client.dart';
import '../../app/theme.dart';
import '../../core/edu/edu_webview_bridge.dart';
import '../../core/theme/course_palette.dart';
import '../../data/api/import_api.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/edu_import/edu_ai_extractor.dart';
import '../../domain/edu_import/edu_html_parser.dart';
import '../../domain/edu_import/school_catalog.dart';
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

  SchoolEntry? _school;

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

  /// Like [_snack], but with a shortcut into the agent settings.
  void _snackWithConfigAction(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          action: SnackBarAction(
            label: '去配置',
            onPressed: () => context.push('/settings/agent'),
          ),
        ),
      );
  }

  bool get _isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Opens the searchable school picker and adopts the chosen entry.
  Future<void> _pickSchool() async {
    final catalog = ref.read(schoolCatalogProvider.future);
    final entry = await showAppBottomSheet<SchoolEntry>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SchoolPickerSheet(catalog: catalog),
    );
    if (entry == null || !mounted) return;
    setState(() {
      _school = entry;
      if (entry.hasUsableUrl) {
        _url.text = entry.normalizedUrl;
        _mode = _SourceMode.url;
      } else {
        _url.clear();
        _mode = _SourceMode.paste;
      }
    });
    if (!entry.hasUsableUrl) {
      _snack('该校未收录教务网址，请手动输入后重试');
    }
  }

  void _clearSchool() {
    setState(() {
      _school = null;
      _url.clear();
    });
  }

  String get _schoolUrl {
    final schoolUrl = _school?.normalizedUrl.trim() ?? '';
    return schoolUrl.isNotEmpty ? schoolUrl : _url.text.trim();
  }

  /// Opens the native education-system browser (Android) and adopts its capture.
  Future<void> _openEduWebView() async {
    final url = _schoolUrl;
    if (url.isEmpty) {
      _snack('请先选择学校或输入教务网址');
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = '正在打开教务浏览器…';
    });
    try {
      final result = await ref
          .read(eduWebViewBridgeProvider)
          .open(
            url: url,
            schoolName: _school?.name ?? '',
            parserType: _school?.parser ?? '',
            desktopMode: _school?.mode == 'pc',
          );
      if (!mounted) return;
      if (result == null) {
        _snack('未提取到数据；可改用粘贴网页/文本导入');
        return;
      }
      await _handleWebViewResult(result);
    } on Object catch (e) {
      _snack('打开教务浏览器失败: $e');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = null;
        });
      }
    }
  }

  /// Non-Android fallback: open the login page in the system browser.
  Future<void> _launchExternal() async {
    final url = _schoolUrl;
    final uri = url.isEmpty ? null : Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      _snack('请先选择学校或输入教务网址');
      return;
    }
    try {
      final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!mounted) return;
      _snack(opened ? '登录后复制课表页面源码，粘贴到下方' : '无法打开浏览器，请手动复制教务网址');
    } on Object {
      _snack('无法打开浏览器，请手动复制教务网址');
    }
  }

  /// Three-stage funnel: local rules, then the configured LLM, then paste.
  Future<void> _handleWebViewResult(EduWebViewResult result) async {
    for (final candidate in [
      result.extractedData,
      result.bestTableHtml,
      result.rawHtml,
    ]) {
      if (candidate.trim().isEmpty) continue;
      final parsed = EduHtmlParser.parse(candidate);
      if (parsed.courses.isNotEmpty) {
        _adoptCourses(parsed.courses, '内置浏览器');
        return;
      }
    }

    // Local rules missed (or the school is marked AI-fallback): compress the
    // best table and hand it to the built-in agent.
    final best = result.bestTableHtml.trim().isNotEmpty
        ? result.bestTableHtml
        : result.rawHtml;
    final compressed = EduHtmlParser.compressHtmlForAi(best);
    final config = ref.read(agentConfigProvider);

    if (!config.isConfigured) {
      if (compressed.isNotEmpty && mounted) {
        setState(() {
          _raw.text = compressed;
          _mode = _SourceMode.paste;
        });
      }
      _snackWithConfigAction('本地规则未命中，请配置 AI 助手后点击「使用 AI 深度解析」');
      return;
    }

    if (compressed.isEmpty) {
      _snack('未提取到可解析的课表内容；可改用粘贴网页/文本导入');
      return;
    }

    setState(() => _busyLabel = 'AI 正在解析课表…');
    try {
      final courses = await EduAiExtractor(
        client: LlmClient(),
        config: config,
      ).extract(compressed);
      if (!mounted) return;
      if (courses.isEmpty) {
        _snack('AI 没有提取到课程，请检查页面内容或更换模型');
        return;
      }
      _adoptCourses(courses, 'AI 兜底');
    } on LlmException catch (e) {
      _snack(e.message);
    } on Object catch (e) {
      _snack('AI 解析失败: $e');
    }
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
        EduHtmlParser.compressHtmlForAi(raw),
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

          // ---- 2. school / education system --------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('选择学校 / 教务系统'),
                const SizedBox(height: 8),
                if (_school == null)
                  Text(
                    '搜索全国 3570 所高校，或直接使用下方粘贴/网址导入。',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  )
                else ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Text(
                          _school!.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _VendorTag(label: _school!.vendorLabel),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _school!.normalizedUrl.isEmpty
                              ? '未收录教务网址'
                              : _school!.normalizedUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton(
                        onPressed: _busy ? null : _clearSchool,
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          minimumSize: const Size(0, 28),
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                        ),
                        child: const Text('清除', style: TextStyle(fontSize: 12)),
                      ),
                    ],
                  ),
                ],
                const SizedBox(height: 10),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : _pickSchool,
                  icon: const Icon(Icons.search),
                  label: const Text('搜索全国高校（3570 所）'),
                ),
                const SizedBox(height: 8),
                if (_isAndroid)
                  FilledButton.icon(
                    onPressed: _busy || !(_school?.hasUsableUrl ?? false)
                        ? null
                        : _openEduWebView,
                    icon: const Icon(Icons.travel_explore),
                    label: const Text('打开教务网登录并提取'),
                  )
                else
                  FilledButton.icon(
                    onPressed: _busy || !(_school?.hasUsableUrl ?? false)
                        ? null
                        : _launchExternal,
                    icon: const Icon(Icons.open_in_browser),
                    label: const Text('在浏览器打开教务网'),
                  ),
              ],
            ),
          ),

          // ---- 3. source ---------------------------------------------------
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

          // ---- 4. preview --------------------------------------------------
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

          // ---- 5. confirm --------------------------------------------------
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

/// Small pill showing the vendor family (`正方教务`, `AI 智能解析`, …).
class _VendorTag extends StatelessWidget {
  const _VendorTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, color: scheme.onSecondaryContainer),
      ),
    );
  }
}

/// Searchable sheet over the bundled 3570-school catalog.
///
/// The only search field in the flow lives here: the import page itself keeps
/// a single paste field so its layout and tests stay stable.
class SchoolPickerSheet extends StatefulWidget {
  const SchoolPickerSheet({super.key, required this.catalog});

  /// Loaded catalog; the sheet shows a progress bar until this resolves.
  final Future<SchoolCatalog> catalog;

  @override
  State<SchoolPickerSheet> createState() => _SchoolPickerSheetState();
}

class _SchoolPickerSheetState extends State<SchoolPickerSheet> {
  static const _resultLimit = 50;

  /// Shown before the user types: real universities rather than the manifest's
  /// leading parser-template rows.
  static const _popularNames = [
    '清华大学',
    '北京大学',
    '浙江大学',
    '复旦大学',
    '上海交通大学',
    '南京大学',
    '武汉大学',
    '中山大学',
    '四川大学',
    '华中科技大学',
    '西安交通大学',
    '哈尔滨工业大学',
    '天津大学',
    '同济大学',
    '东南大学',
    '山东大学',
  ];

  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.8,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _search,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.search),
                hintText: '搜索学校名称，如：安徽、理工、研究生',
              ),
            ),
          ),
          Expanded(
            child: FutureBuilder<SchoolCatalog>(
              future: widget.catalog,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: LinearProgressIndicator(),
                    ),
                  );
                }
                final catalog =
                    snapshot.data ?? SchoolCatalog.fromEntries(const []);
                return _buildList(catalog, scheme);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildList(SchoolCatalog catalog, ColorScheme scheme) {
    final query = _query.trim();
    if (query.isNotEmpty) {
      final results = catalog.search(query, limit: _resultLimit);
      if (results.isEmpty) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text(
              '没有匹配的学校，可改用下方粘贴/网址导入',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        );
      }
      return ListView.builder(
        padding: const EdgeInsets.only(bottom: 24),
        itemCount: results.length,
        itemBuilder: (context, index) => _tile(results[index]),
      );
    }

    final schools = <SchoolEntry>[];
    for (final name in _popularNames) {
      final entry = catalog.byName(name);
      if (entry != null && !schools.any((e) => e.name == entry.name)) {
        schools.add(entry);
      }
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        const _PickerGroupTitle('通用教务系统'),
        for (final entry in catalog.featured) _tile(entry),
        if (schools.isNotEmpty) ...[
          const _PickerGroupTitle('热门高校'),
          for (final entry in schools) _tile(entry),
        ],
      ],
    );
  }

  Widget _tile(SchoolEntry entry) {
    final hasUrl = entry.hasUsableUrl;
    return ListTile(
      dense: true,
      title: Text(entry.name),
      subtitle: Text(
        hasUrl ? entry.normalizedUrl : '未收录教务网址',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 11),
      ),
      trailing: _VendorTag(label: entry.vendorLabel),
      onTap: () => Navigator.of(context).pop(entry),
    );
  }
}

class _PickerGroupTitle extends StatelessWidget {
  const _PickerGroupTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
