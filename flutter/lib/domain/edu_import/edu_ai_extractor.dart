/// AI fallback for education-system timetables (phase 6 Step 1).
///
/// Sends the stripped page text to the built-in agent's LLM and turns the
/// strict JSON answer into [ParsedCsvCourse] rows, so any non-standard school
/// system can still be imported.
library;

import 'dart:convert';

import '../../agent/agent_config.dart';
import '../../agent/llm_client.dart';
import '../../core/util/week_text.dart';
import '../../data/api/import_api.dart';
import 'wakeup_normalizer.dart';

/// Extracts courses from arbitrary timetable text through [LlmClient].
class EduAiExtractor {
  const EduAiExtractor({required this.client, required this.config});

  final LlmClient client;
  final LlmConfig config;

  /// Compressed table HTML is 2–6 KB; 12 K leaves room for long pages.
  static const _maxChars = 12000;
  static const _maxPeriodNo = 20;
  static const _maxCourses = 500;

  /// Production prompt ported from Parser_GPT's AI parser: the model answers
  /// with `IClassesItem[]` so period/week text never has to be invented.
  static const _systemPrompt =
      '请从用户提供的 html 文本中提取课表信息，返回 IClassesItem[]，'
      '严格按照 JSON 格式返回，不要包含其他文字，'
      'IClassesItem 的结构及相关字段的定义如下：\n'
      'interface IClassesItem {\n'
      '  /**\n'
      '   * 课程标识，用来区分列表中的课程\n'
      '   * 非必填，没有就是 ""\n'
      '   */\n'
      '  classDefId: string;\n'
      '  /**\n'
      '   * 课程名\n'
      '   */\n'
      '  courseName: string;\n'
      '  /**\n'
      '   * 上课时间地点\n'
      '   */\n'
      '  classTimeLoc: {\n'
      '    /**\n'
      '     * 任课老师 非必填，没有就是 ""\n'
      '     */\n'
      '    teacher: string;\n'
      '    /**\n'
      '     * 上课地点 非必填，没有就是 ""\n'
      '     */\n'
      '    location: string;\n'
      '    /**\n'
      '     * 唯一 id 非必填，没有就是 ""\n'
      '     */\n'
      '    classTimeLocId: string;\n'
      '    /**\n'
      '     * 必填\n'
      '     * 周几上课，默认 0\n'
      '     * 1- 星期一，2- 星期二，3- 星期三，4- 星期四，5- 星期五，'
      '6- 星期六，0- 星期日\n'
      '     */\n'
      '    weekDay: number;\n'
      '    /**\n'
      '     * 暂时没用，写死 1\n'
      '     * 1- 上午，2- 中午，3- 晚上\n'
      '     */\n'
      '    dayPart: number;\n'
      '    /**\n'
      '     * 必填，默认 [1,2,3,4,5,6,7,....25]\n'
      '     * 上课周数，从 1 开始，第几周\n'
      '     */\n'
      '    weekNums: number[];\n'
      '    /**\n'
      '     * 必填，默认 [1,2]\n'
      '     * 单节课 [1,1]、[2,2] 这样类推\n'
      '     * 上课时间，课程节数如 [1,3] 标识第一节到第三节\n'
      '     */\n'
      '    classTimeDailyIdxList: number[];\n'
      '  }[];\n'
      '}\n'
      '识别出所有课程，不要遗漏，classDefId、classTimeLocId 设置为空字符串，'
      'dayPart 固定为 1，weekNums 不要出现代码，必须是显式周次数组（升序）。\n'
      '其中 classTimeLoc 是数组，每个元素包含 teacher、location、weekDay、'
      'weekNums、classTimeDailyIdxList 字段，同一个课程的不同上课时间点会拆分成'
      '多个元素，每个元素代表一个具体的上课时间信息。\n'
      '需要合并的情况：\n'
      '1. 如果一个课程的具体上课信息中，除了上课周次不同之外，其他星期、地点、'
      '老师、节次都相同，那么就合并为一个上课时段，weekNums 字段包含所有周数，'
      '升序排序。\n'
      '2. 如果一个课程的具体上课信息中，除了上课节次不同之外，其他星期、地点、'
      '老师、周次都相同，也需要合并为一个上课时段，classTimeDailyIdxList 包含'
      '开始和结束的节次（格式为 [开始节次, 结束节次]）。\n'
      '其他情况，只要上课地点、老师、星期、周次、节次有任何一项不一样，'
      '就表示是不同的上课时段，需要拆分为不同的上课时间点。\n'
      '只输出一个 JSON 数组，不要使用 markdown 代码块，不要解释。';

  /// Sends the (already stripped) [strippedContent] and parses the JSON array.
  ///
  /// Both the `IClassesItem[]` answer and the legacy flat course shape are
  /// accepted; invalid entries are skipped. Throws [LlmException] when the
  /// answer carries no usable course data at all; the model key is never logged
  /// or echoed.
  Future<List<ParsedCsvCourse>> extract(String strippedContent) async {
    final content = strippedContent.trim();
    if (content.isEmpty) {
      throw LlmException('没有可解析的课表内容，请先粘贴教务网页源码或课表文本');
    }
    final clipped = content.length > _maxChars
        ? content.substring(0, _maxChars)
        : content;

    final reply = await client.complete(
      config: config,
      messages: [
        {'role': 'system', 'content': _systemPrompt},
        {'role': 'user', 'content': '以下是教务网页/课表文本，请解析为课程 JSON 数组：\n$clipped'},
      ],
      tools: const [],
    );

    final raw = reply.content;
    if (raw == null || raw.trim().isEmpty) {
      throw LlmException('模型没有返回任何课程数据，请重试');
    }

    final entries = _decodeEntries(raw);
    if (entries == null) {
      throw LlmException('模型返回的内容不是合法的 JSON 课程数组，请重试');
    }

    final courses = <ParsedCsvCourse>[];
    final keys = <String>{};

    void addAll(Iterable<ParsedCsvCourse> rows) {
      for (final row in rows) {
        if (courses.length >= _maxCourses) return;
        if (!keys.add(_dedupeKey(row))) continue;
        // Keep `line` gapless in generation order for the preview table.
        courses.add(_withLine(row, courses.length + 1));
      }
    }

    for (final entry in entries) {
      if (entry is! Map) continue;
      if (entry.containsKey('courseName') &&
          entry.containsKey('classTimeLoc')) {
        addAll(WakeupFormatNormalizer.fromIClassesItems([entry]));
        continue;
      }
      final course = _courseFromEntry(entry, courses.length + 1);
      if (course == null) continue;
      addAll([course]);
    }

    if (courses.isEmpty) {
      throw LlmException('模型返回的课程缺少课程名、星期、节次或周次，请重试');
    }
    return courses;
  }

  /// Removes markdown fences and decodes the first `[` .. last `]` block.
  static List<dynamic>? _decodeEntries(String raw) {
    var text = raw.trim();
    text = text.replaceAll(RegExp(r'^```[a-zA-Z0-9_-]*\s*'), '');
    text = text.replaceAll(RegExp(r'\s*```$'), '');
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start >= 0 && end > start) {
      text = text.substring(start, end + 1);
    }
    // Tolerate the trailing commas real models like to emit.
    text = text.replaceAllMapped(RegExp(r',(\s*[\]}])'), (m) => m.group(1)!);
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is List) return decoded;
    if (decoded is Map) {
      for (final key in const ['courses', 'classes', 'data', 'items', 'list']) {
        final value = decoded[key];
        if (value is List) return value;
      }
      if (decoded.containsKey('name') || decoded.containsKey('courseName')) {
        return [decoded];
      }
    }
    return null;
  }

  static String _dedupeKey(ParsedCsvCourse course) =>
      '${course.name}\u0000${course.weekday}\u0000${course.periodStart}'
      '\u0000${course.periodEnd}\u0000${course.weekRuleText ?? ''}'
      '\u0000${course.teacher ?? ''}\u0000${course.location ?? ''}';

  static ParsedCsvCourse _withLine(ParsedCsvCourse course, int line) =>
      ParsedCsvCourse(
        line: line,
        name: course.name,
        weekday: course.weekday,
        periodStart: course.periodStart,
        periodEnd: course.periodEnd,
        teacher: course.teacher,
        location: course.location,
        weekRuleText: course.weekRuleText,
      );

  static ParsedCsvCourse? _courseFromEntry(Object? entry, int line) {
    if (entry is! Map) return null;
    final name = _stringOf(
      entry['name'] ?? entry['courseName'] ?? entry['kcmc'],
    );
    if (name == null || name.length > 100) return null;

    final weekday = _intOf(entry['weekday'] ?? entry['xqj'] ?? entry['day']);
    if (weekday == null || weekday < 1 || weekday > 7) return null;

    final start = _intOf(
      entry['periodStart'] ?? entry['startPeriod'] ?? entry['jcStart'],
    );
    final end =
        _intOf(entry['periodEnd'] ?? entry['endPeriod'] ?? entry['jcEnd']) ??
        start;
    if (start == null || end == null) return null;
    if (start < 1 || end > _maxPeriodNo || start > end) return null;

    final weeks = _weeksOf(
      entry['weeks'] ?? entry['weeksText'] ?? entry['zcd'],
    );
    if (weeks == null) return null;

    return ParsedCsvCourse(
      line: line,
      name: name,
      weekday: weekday,
      periodStart: start,
      periodEnd: end,
      teacher: _stringOf(entry['teacher'] ?? entry['xm']),
      location: _stringOf(entry['location'] ?? entry['cdmc']),
      weekRuleText: weeks,
    );
  }

  static String? _stringOf(Object? value) {
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? null : text;
    }
    if (value is num) return value.toString();
    return null;
  }

  static int? _intOf(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  /// Normalises the model's week cell into text [parseWeekRuleText] accepts.
  static String? _weeksOf(Object? value) {
    if (value is num) {
      final text = value.toInt().toString();
      return parseWeekRuleText(text) == null ? null : text;
    }
    if (value is List) {
      final parts = <String>[
        for (final entry in value)
          if (entry is num) entry.toInt().toString(),
      ];
      if (parts.isEmpty) return null;
      final text = parts.join(',');
      return parseWeekRuleText(text) == null ? null : text;
    }
    if (value is! String) return null;

    var text = value.trim();
    if (text.isEmpty) return null;
    text = text
        .replaceFirst(RegExp(r'^第\s*'), '')
        .replaceAll('周次', '')
        .replaceAll('周', '')
        .replaceAll(RegExp(r'[、，；;]'), ',')
        .replaceAll(RegExp(r'[~—–－]'), '-')
        .replaceAll(' ', '');
    text = text.replaceAllMapped(
      RegExp(r'[（(]\s*([单双])\s*[)）]'),
      (m) => m.group(1)!,
    );
    if (!RegExp(r'^\d').hasMatch(text)) return null;
    return parseWeekRuleText(text) == null ? null : text;
  }
}
