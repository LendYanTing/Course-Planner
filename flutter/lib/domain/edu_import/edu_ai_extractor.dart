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

/// Extracts courses from arbitrary timetable text through [LlmClient].
class EduAiExtractor {
  const EduAiExtractor({required this.client, required this.config});

  final LlmClient client;
  final LlmConfig config;

  static const _maxChars = 6000;
  static const _maxPeriodNo = 20;

  static const _systemPrompt =
      '你是教务课表结构化助手。请把用户提供的教务网页文本或复制的课表文本解析为课程数组。\n'
      '只输出一个 JSON 数组，不要 markdown 代码块，不要解释，不要输出任何多余文字。\n'
      '每个元素的字段：\n'
      '- name：课程名称，字符串，必填，保留括号、班号等原文；\n'
      '- weekday：星期几，整数 1-7（周一=1，周日=7），必填；\n'
      '- periodStart：开始节次，整数 1-20，必填；\n'
      '- periodEnd：结束节次，整数 1-20，且不小于 periodStart，必填；\n'
      '- teacher：教师，字符串，未知用 null；\n'
      '- location：上课地点，字符串，未知用 null；\n'
      '- weeks：周次，字符串，必填，使用 1-16、1-5,7-11单、2,4,6 这类写法。\n'
      '同一门课的不同上课时间拆成多个元素；无法识别的行直接忽略；没有课程时输出 []。';

  /// Sends the (already stripped) [strippedContent] and parses the JSON array.
  ///
  /// Invalid entries are skipped. Throws [LlmException] when the answer carries
  /// no usable course data at all; the model key is never logged or echoed.
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
    if (entries.isEmpty) return const [];

    final courses = <ParsedCsvCourse>[];
    for (final entry in entries) {
      final course = _courseFromEntry(entry, courses.length + 1);
      if (course == null) continue;
      courses.add(course);
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
      for (final key in const ['courses', 'data', 'items', 'list']) {
        final value = decoded[key];
        if (value is List) return value;
      }
      if (decoded.containsKey('name')) return [decoded];
    }
    return null;
  }

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
