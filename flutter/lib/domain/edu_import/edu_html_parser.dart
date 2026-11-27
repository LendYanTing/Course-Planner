/// Education-system timetable parsing (phase 6 Step 1).
///
/// Pure Dart: no I/O, no widgets, no exceptions escaping [EduHtmlParser.parse].
/// Three complementary formats are recognised:
///
/// 1. new Zhengfang JSON (`kbList` / `sjkList`, optionally embedded in HTML as
///    `var kbList = [...]`), plus JinZhi / ShuWei / Qiangzhi Vue / Chaoxing
///    JSON via `WakeupFormatNormalizer`;
/// 2. generic / Zhengfang / Qiangzhi / Qingguo `<table>` timetables, including
///    Qiangzhi `<font title="...">` cells and `-----`-separated courses;
/// 3. a plain-text timetable copied from the page (one course per line).
///
/// The output rows reuse [ParsedCsvCourse] so the caller can turn them into CSV
/// and run them through `LocalCsvImporter` (docs/csv-import.md).
library;

import 'dart:convert';

import '../../core/util/week_text.dart';
import '../../data/api/import_api.dart';
import 'wakeup_normalizer.dart';

/// One period slot read from an education-system timetable page.
typedef EduPeriodTime = ({int periodNo, String startLocal, String endLocal});

/// Result of [EduHtmlParser.parse] / [EduHtmlParser.parseText].
class EduParseResult {
  const EduParseResult({
    required this.courses,
    this.periods = const [],
    this.source,
  });

  /// Parsed courses in page order; every row passed the basic shape checks.
  final List<ParsedCsvCourse> courses;

  /// Period time table, only when the source carried one (`08:00`-`08:45`).
  final List<EduPeriodTime> periods;

  /// `zhengfang-json` | `jinzhi-json` | `shuwei-json` | `qiangzhi-vue` |
  /// `chaoxing-json` | `iclasses-json` | `table` | `text` | null when
  /// nothing was recognised.
  final String? source;

  bool get isEmpty => courses.isEmpty;
}

/// Stateless timetable parser for education-system pages and copied text.
abstract final class EduHtmlParser {
  static const _maxCourses = 500;
  static const _maxPeriodNo = 20;
  static const _maxNameLength = 100;

  // ---- regular expressions (bounded, no nested unbounded quantifiers) ------

  /// `第1-2节`, `1-2节`, `第 1 ~ 2 节`.
  static final RegExp _periodPattern = RegExp(
    r'第?\s*(\d{1,2})\s*[-~—–－至]\s*(\d{1,2})\s*节',
  );

  /// `(1-2)`, `（1~2节）` — a bare parenthesised period range.
  static final RegExp _periodParenPattern = RegExp(
    r'[（(]\s*(\d{1,2})\s*[-~—–－至]\s*(\d{1,2})\s*节?\s*[)）]',
  );

  /// `第3节`.
  static final RegExp _periodSinglePattern = RegExp(r'第\s*(\d{1,2})\s*节');

  /// `周一`, `星期三`, `礼拜天`, `周1`.
  static final RegExp _weekdayPattern = RegExp(
    r'(?:周|星期|礼拜)\s*([一二三四五六日天1-7])',
  );

  /// Week column: `1-16周`, `1-16周(单)`, `1-5,7-9`, `1-16(双)`, `1-16单`.
  /// Group 1 is the numeric run; groups 2..5 are the parity marker.
  ///
  /// `(?<!\d)` keeps a room number (`201 周三`) from being read as week 01,
  /// and `周(?![一二三四五六日天1-7])` keeps it from swallowing a weekday.
  static final RegExp _weeksPattern = RegExp(
    r'(?<!\d)第?\s*(\d{1,2}(?:\s*[-~—–－至]\s*\d{1,2})?'
    r'(?:\s*[,、，]\s*\d{1,2}(?:\s*[-~—–－至]\s*\d{1,2})?)*)'
    r'\s*(?:周(?![一二三四五六日天1-7])(?:次)?\s*'
    r'(?:[（(]\s*([单双])\s*周?\s*[)）]|([单双])\s*周?)?'
    r'|[（(]\s*([单双])\s*周?\s*[)）]'
    r'|([单双]))',
  );

  /// A bare `1-2` range; only used as a last resort, never on the week column.
  static final RegExp _bareRangePattern = RegExp(
    r'(\d{1,2})\s*[-~—–－]\s*(\d{1,2})',
  );

  static final RegExp _tagPattern = RegExp(r'<[^>]*>');

  /// Whole `<table>` elements, used by [compressHtmlForAi].
  static final RegExp _tablePattern = RegExp(
    r'<table\b[\s\S]*?</table\s*>',
    caseSensitive: false,
  );

  static final RegExp _tableRowPattern = RegExp(
    r'<tr\b[^>]*>([\s\S]*?)</tr\s*>',
    caseSensitive: false,
  );

  static final RegExp _tableCellPattern = RegExp(
    r'<t[dh]\b([^>]*)>([\s\S]*?)</t[dh]\s*>',
    caseSensitive: false,
  );

  /// Opening tag with optional quoted attributes; quoted values may contain
  /// `>` (`<font title="a>b">`), which keeps the rewrite from splitting a tag.
  static final RegExp _aiOpenTagPattern = RegExp(
    r'''<([a-zA-Z][a-zA-Z0-9:-]*)((?:[^<>"']|"[^"]*"|'[^']*')*)>''',
  );

  /// Weekday header labels in a timetable grid (`星期一`..`星期日`, 1..7).
  static final RegExp _aiWeekdayHeaderPattern = RegExp(
    r'星期[一二三四五六日天1-7]',
  );

  /// Period-column labels: `节次`, `第1节`, `上午`, `08:00-09:35`.
  static final RegExp _aiPeriodLabelPattern = RegExp(
    r'节次|节|周\s*/?\s*节|上午|下午|晚上'
    r'|\d{1,2}\s*[:：]\s*\d{2}\s*[-~—至]\s*\d{1,2}\s*[:：]\s*\d{2}',
  );

  /// Parser_GPT's five header keywords, in its original order.
  static final List<RegExp> _aiKeywordPatterns = [
    RegExp(r'课程'),
    RegExp(r'教师|老师|教授'),
    RegExp(r'地点|教室|楼|校区'),
    RegExp(r'周|星期'),
    RegExp(r'节次'),
  ];

  /// Qiangzhi `<font title="教师">...</font>` field annotations.
  static final RegExp _fontTitlePattern = RegExp(
    "<font\\b[^>]*\\btitle\\s*=\\s*[\"']?([^\"'>\\s]+)[\"']?[^>]*>"
    "([\\s\\S]*?)</font\\s*>",
    caseSensitive: false,
  );

  // ---- public API -----------------------------------------------------------

  /// Recognises the format automatically: new Zhengfang JSON → HTML table →
  /// plain text. Never throws; bad input yields an empty result.
  static EduParseResult parse(String raw) {
    if (raw.trim().isEmpty) return const EduParseResult(courses: []);
    try {
      final json = _tryJson(raw);
      if (json != null && (!json.isEmpty || json.periods.isNotEmpty)) {
        return json;
      }
      final table = _tryHtml(raw);
      if (table != null) return table;
      final text = raw.contains('<') ? _plainDocument(raw) : raw;
      final parsed = parseText(text);
      if (!parsed.isEmpty) return parsed;
      return const EduParseResult(courses: []);
    } on Object {
      // 解析失败按空结果处理：页面会回退到 AI 解析或提示用户。
      return const EduParseResult(courses: []);
    }
  }

  /// Strips `script` / `style` / `svg` / `head` blocks and every attribute,
  /// keeping only text plus a light `<tr>` / `<td>` grid, so a 100 KB page
  /// shrinks to a few KB for the AI fallback.
  static String stripHtmlForAi(String rawHtml, {int maxChars = 6000}) {
    if (rawHtml.trim().isEmpty) return '';
    var s = rawHtml;
    s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
    for (final tag in const [
      'script',
      'style',
      'svg',
      'head',
      'noscript',
      'template',
      'iframe',
    ]) {
      s = _removeElement(s, tag);
    }
    s = s.replaceAllMapped(_tagPattern, (m) {
      final tag = m.group(0)!;
      final closing = tag.startsWith('</');
      final name = _tagName(tag);
      switch (name) {
        case 'br':
          return '\n';
        case 'td':
        case 'th':
          return closing ? ' | ' : '';
        case 'tr':
          return closing ? '\n' : '';
        case 'table':
        case 'thead':
        case 'tbody':
        case 'tfoot':
          return '';
      }
      if (closing &&
          const {
            'p',
            'div',
            'li',
            'h1',
            'h2',
            'h3',
            'h4',
            'h5',
            'h6',
            'section',
            'article',
          }.contains(name)) {
        return '\n';
      }
      return '';
    });
    s = _decodeEntities(s);
    final lines = <String>[];
    for (final rawLine in s.split('\n')) {
      var line = _squeeze(rawLine).replaceAll(RegExp(r'(\s*\|\s*)+'), ' | ');
      line = line
          .replaceAll(RegExp(r'^(\|\s*)+'), '')
          .replaceAll(RegExp(r'(\s*\|)+$'), '')
          .trim();
      if (line.isNotEmpty) lines.add(line);
    }
    s = lines.join('\n');
    if (s.length > maxChars) s = s.substring(0, maxChars);
    return s;
  }

  /// Picks the highest-weight `<table>` on a page and shrinks it to a compact
  /// HTML skeleton for the AI fallback (port of Parser_GPT's `findTables` +
  /// `getWeight` + `compressHtml`).
  ///
  /// Every table gets a 6-digit weight; the lexicographically largest one wins
  /// (first in document order on ties). The winner keeps only `class`, `title`,
  /// `rowspan` and `colspan` attributes, so `title="教师"` markers and
  /// `rowspan` / `colspan` geometry survive while `onclick`, `id`, `data-*`,
  /// `width` and `align` disappear.
  ///
  /// Falls back to [stripHtmlForAi] (plain text) when the page has no table or
  /// when the best table looks like navigation / layout (`'000000'`).
  /// Never throws: bad input yields an empty string.
  static String compressHtmlForAi(String rawHtml, {int maxChars = 8000}) {
    if (rawHtml.trim().isEmpty || maxChars <= 0) return '';
    try {
      _AiTable? best;
      for (final match in _tablePattern.allMatches(rawHtml)) {
        final html = match.group(0)!;
        final weight = _tableWeight(html);
        if (best == null || weight.compareTo(best.weight) > 0) {
          best = _AiTable(html: html, weight: weight);
        }
      }
      if (best == null || best.weight == '000000') {
        return stripHtmlForAi(rawHtml, maxChars: maxChars);
      }
      return _truncateHtml(_compressTableHtml(best.html), maxChars);
    } on Object {
      return '';
    }
  }

  /// `'000000'` when the table carries no schedule signal, otherwise the six
  /// weight digits Parser_GPT uses (`[0]` weekday/period axis, `[1]` header
  /// keywords, `[2]` body keywords, `[3]` wide grid, `[4]`/`[5]` reserved).
  static String _tableWeight(String table) {
    final rows = _tableRows(table);
    final weight = List<int>.filled(6, 0);

    var maxWidth = 0;
    for (final row in rows) {
      var width = 0;
      for (final cell in row.cells) {
        width += cell.colspan;
      }
      if (width > maxWidth) maxWidth = width;
    }
    if (rows.length >= 2 && maxWidth >= 4) weight[3] = 1;

    var bodyHits = 0;
    for (final row in rows) {
      for (final cell in row.cells) {
        for (final pattern in _aiKeywordPatterns) {
          if (pattern.hasMatch(cell.text)) bodyHits++;
        }
      }
    }
    if (bodyHits > 0) weight[2] = bodyHits > 6 ? 6 : bodyHits;

    if (rows.isNotEmpty) {
      var headerHits = 0;
      for (final cell in rows.first.cells) {
        for (final pattern in _aiKeywordPatterns) {
          if (pattern.hasMatch(cell.text)) headerHits++;
        }
      }
      if (headerHits > 0) weight[1] = headerHits > 6 ? 6 : headerHits;
    }

    var weekdayLabels = 0;
    if (rows.isNotEmpty) {
      for (final cell in rows.first.cells) {
        if (_aiWeekdayHeaderPattern.hasMatch(cell.text)) weekdayLabels++;
      }
    }
    var periodLabels = 0;
    for (final row in rows) {
      if (row.cells.isEmpty) continue;
      if (_aiPeriodLabelPattern.hasMatch(row.cells.first.text)) {
        periodLabels++;
      }
    }
    final half = rows.length ~/ 2;
    if (weekdayLabels >= 3 || (periodLabels > 0 && periodLabels >= half)) {
      weight[0] = 1;
    }

    // Parser_GPT ignores the first row and each row's first cell here; a table
    // whose body is under 5% non-empty is treated as layout chrome.
    var considered = 0;
    var nonEmpty = 0;
    for (var r = 1; r < rows.length; r++) {
      for (var c = 1; c < rows[r].cells.length; c++) {
        considered++;
        if (rows[r].cells[c].text.trim().isNotEmpty) nonEmpty++;
      }
    }
    if (considered == 0) {
      for (var r = 1; r < rows.length; r++) {
        for (final cell in rows[r].cells) {
          considered++;
          if (cell.text.trim().isNotEmpty) nonEmpty++;
        }
      }
    }
    if (considered > 0 && nonEmpty / considered < 0.05) return '000000';

    return weight.join();
  }

  static List<_AiTableRow> _tableRows(String table) {
    final rows = <_AiTableRow>[];
    for (final row in _tableRowPattern.allMatches(table)) {
      final cells = <_AiTableCell>[];
      for (final cell in _tableCellPattern.allMatches(row.group(1)!)) {
        cells.add(
          _AiTableCell(
            text: _fragmentToText(cell.group(2)!),
            colspan: _spanOf(cell.group(1) ?? ''),
          ),
        );
      }
      rows.add(_AiTableRow(cells));
    }
    return rows;
  }

  /// Drops chrome elements and rewrites every opening tag to keep only
  /// `class`, `title`, `rowspan` and `colspan` (always double-quoted).
  static String _compressTableHtml(String table) {
    var s = table.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
    for (final tag in const ['script', 'style', 'svg', 'head']) {
      s = _removeElement(s, tag);
    }
    s = s.replaceAllMapped(_aiOpenTagPattern, (match) {
      final name = match.group(1)!;
      final attributes = match.group(2) ?? '';
      final buffer = StringBuffer('<$name');
      for (final key in const ['class', 'title', 'rowspan', 'colspan']) {
        final value = _attributeOf(attributes, key);
        if (value == null) continue;
        buffer.write(' $key="${value.replaceAll('"', '&quot;')}"');
      }
      buffer.write('>');
      return buffer.toString();
    });
    s = s.replaceAll(RegExp(r'[ \t\u00A0\u3000]+'), ' ');
    s = s.replaceAll(RegExp(r' ?\n ?'), '\n');
    s = s.replaceAll(RegExp(r'\n{2,}'), '\n');
    return s.trim();
  }

  static String _truncateHtml(String html, int maxChars) {
    if (html.length <= maxChars) return html;
    final head = html.substring(0, maxChars);
    final cut = head.lastIndexOf('>');
    return cut >= 0 ? head.substring(0, cut + 1) : head;
  }

  static int _spanOf(String attributes) {
    final value = _attributeOf(attributes, 'colspan');
    if (value == null) return 1;
    final number = int.tryParse(value.trim());
    if (number == null || number < 1 || number > 100) return 1;
    return number;
  }

  /// Reads one attribute, accepting `"..."`, `'...'` and unquoted values.
  static String? _attributeOf(String attributes, String key) {
    final pattern = RegExp(
      '(?:^|\\s)${RegExp.escape(key)}\\s*=\\s*'
      r'''(?:"([^"]*)"|'([^']*)'|([^\s>"']+))''',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(attributes);
    if (match == null) return null;
    return match.group(1) ?? match.group(2) ?? match.group(3) ?? '';
  }

  /// Parses a plain-text timetable (one course per line, `\t` or spaces).
  /// Never throws; unrecognised text yields an empty result.
  static EduParseResult parseText(String text) {
    try {
      return _parseText(text);
    } on Object {
      // 文本无法解析时返回空结果，交给 AI 兜底。
      return const EduParseResult(courses: []);
    }
  }

  static EduParseResult _parseText(String text) {
    final courses = <ParsedCsvCourse>[];
    final seen = <String>{};
    final lines = text
        .replaceAll('\u00A0', ' ')
        .replaceAll('\u3000', ' ')
        .split(RegExp(r'\r\n|\r|\n'));
    final pending = <String>[];
    var recordText = '';
    var recordHasWeek = false;
    var recordLine = 1;

    void flush() {
      if (recordText.isEmpty) {
        recordHasWeek = false;
        return;
      }
      final course = _courseFrom(
        recordText,
        line: recordLine,
        preferFirstAsName: false,
      );
      recordText = '';
      recordHasWeek = false;
      if (course == null) return;
      if (!seen.add(_key(course))) return;
      if (courses.length < _maxCourses) courses.add(course);
    }

    for (var i = 0; i < lines.length; i++) {
      final line = _squeeze(lines[i]);
      if (line.isEmpty) continue;
      if (_isIgnorableLine(line)) {
        flush();
        continue;
      }
      if (_periodSpan(line) != null) {
        flush();
        recordText = [if (pending.isNotEmpty) ...pending, line].join(' ');
        pending.clear();
        recordLine = i + 1;
        recordHasWeek = _weeksPattern.hasMatch(line);
        continue;
      }
      if (recordText.isEmpty) {
        // A course name on its own line, followed by its detail line.
        if (_isNameCandidateLine(line)) {
          pending.add(line);
          if (pending.length > 3) pending.removeAt(0);
        }
        continue;
      }
      if (!recordHasWeek) {
        recordText = '$recordText $line';
        recordHasWeek = _weeksPattern.hasMatch(line);
        continue;
      }
      if (_isNameCandidateLine(line)) {
        // Likely the next course's name column: close the record and keep it.
        flush();
        pending.add(line);
        if (pending.length > 3) pending.removeAt(0);
        continue;
      }
      recordText = '$recordText $line';
    }
    flush();
    return EduParseResult(
      courses: courses,
      source: courses.isEmpty ? null : 'text',
    );
  }

  // ---- JSON: Zhengfang first, then the vendor normaliser --------------------

  static EduParseResult? _tryJson(String raw) {
    final zhengfang = _tryZhengfangJson(raw);
    if (zhengfang != null) return zhengfang;
    return _tryVendorJson(raw);
  }

  /// New Zhengfang `kbList` / `sjkList`, including the period-time table.
  static EduParseResult? _tryZhengfangJson(String raw) {
    final decoded = _decodeWhole(raw);
    final lists = <List<dynamic>>[];
    var sawZhengfang = false;
    var periods = const <EduPeriodTime>[];

    if (decoded is Map) {
      for (final key in const ['kbList', 'sjkList', 'kbListJson']) {
        final value = decoded[key];
        if (value is List) {
          lists.add(value);
          sawZhengfang = true;
        }
      }
      periods = _periodsFromJson(decoded);
    } else if (decoded is List) {
      if (_looksLikeCourseList(decoded)) {
        lists.add(decoded);
        sawZhengfang = true;
      } else {
        periods = _periodsFromList(decoded);
      }
    }

    if (!sawZhengfang) {
      for (final key in const ['kbList', 'sjkList']) {
        final array = _findKeyArray(raw, key);
        if (array == null) continue;
        lists.add(array);
        sawZhengfang = true;
      }
    }
    if (periods.isEmpty) {
      for (final key in const ['jcList', 'jcs', 'pksj', 'periodList']) {
        final array = _findKeyArray(raw, key);
        if (array == null) continue;
        final found = _periodsFromList(array);
        if (found.isNotEmpty) {
          periods = found;
          break;
        }
      }
    }
    if (!sawZhengfang && periods.isEmpty) return null;

    final courses = <ParsedCsvCourse>[];
    final seen = <String>{};
    for (final list in lists) {
      for (final entry in list) {
        if (courses.length >= _maxCourses) break;
        if (entry is! Map) continue;
        final course = _courseFromJson(entry, courses.length + 1);
        if (course == null) continue;
        if (!seen.add(_key(course))) continue;
        courses.add(course);
      }
    }
    if (courses.isEmpty && periods.isEmpty) return null;
    return EduParseResult(
      courses: courses,
      periods: periods,
      source: 'zhengfang-json',
    );
  }

  /// Vendor JSON (JinZhi / ShuWei / Qiangzhi Vue / Chaoxing / IClasses) as a
  /// whole document or embedded in a `<script>` block.
  static EduParseResult? _tryVendorJson(String raw) {
    final decoded = _decodeWhole(raw);
    if (decoded != null) {
      final parsed = WakeupFormatNormalizer.fromAnyJsonWithSource(decoded);
      if (parsed.courses.isNotEmpty) {
        return EduParseResult(courses: parsed.courses, source: parsed.source);
      }
      return null;
    }
    for (final key in const [
      'arrangedList',
      'studentTableVms',
      'sdpkkbList',
      'lessons',
      'rows',
    ]) {
      final slice = _findKeyJson(raw, key);
      if (slice == null) continue;
      try {
        final nested = jsonDecode(slice);
        final parsed = WakeupFormatNormalizer.fromAnyJsonWithSource(
          <String, Object?>{key: nested},
        );
        if (parsed.courses.isNotEmpty) {
          return EduParseResult(
            courses: parsed.courses,
            source: parsed.source,
          );
        }
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// Finds `key: [...]` / `key: {...}` in a page source and returns the
  /// balanced JSON slice.
  static String? _findKeyJson(String raw, String key) {
    final pattern = RegExp(
      '["\']?${RegExp.escape(key)}["\']?\\s*[:=]\\s*([\\[{])',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    if (match == null) return null;
    // The regex ends with the opening bracket, so the group starts at end - 1.
    return _balancedJson(raw, match.end - 1);
  }

  static ParsedCsvCourse? _courseFromJson(Map<dynamic, dynamic> m, int line) {
    final rawName = _mapString(m, const [
      'kcmc',
      'kcname',
      'courseName',
      'name',
    ]);
    if (rawName == null) return null;
    final weekday = _weekdayOf(m['xqj'] ?? m['weekday'] ?? m['xingqi']);
    final period = _periodRange(
      _mapString(m, const ['jcs', 'jc', 'jcor', 'period']) ?? '',
    );
    if (weekday == null || period == null) return null;

    final weeks = _weeksFromRaw(
      _mapString(m, const ['zcd', 'weeks', 'zc', 'weekText']) ?? '',
    );
    final teacher = _mapString(m, const ['xm', 'jsxm', 'teacher']);
    final location = _mapString(m, const ['cdmc', 'jxdd', 'location']);
    final name = _cleanName(rawName);
    if (name.isEmpty || _isNoiseName(name)) return null;

    return ParsedCsvCourse(
      line: line,
      name: _clipName(name),
      weekday: weekday,
      periodStart: period.$1,
      periodEnd: period.$2,
      teacher: _cleanTeacher(teacher),
      location: _cleanLocation(location),
      weekRuleText: weeks,
    );
  }

  /// Collects the period-time table from any array of maps that carries a
  /// period number plus start/end time (new Zhengfang `jcList` and variants).
  static List<EduPeriodTime> _periodsFromJson(Map<dynamic, dynamic> map) {
    for (final value in map.values) {
      if (value is! List) continue;
      final found = _periodsFromList(value);
      if (found.isNotEmpty) return found;
    }
    return const [];
  }

  static List<EduPeriodTime> _periodsFromList(List<dynamic> list) {
    final byNo = <int, EduPeriodTime>{};
    for (final entry in list) {
      if (entry is! Map) continue;
      final no = _periodNoOf(entry);
      final start = _timeOf(entry, const [
        'qssj',
        'kssj',
        'startLocal',
        'start',
      ]);
      final end = _timeOf(entry, const ['jssj', 'zzsj', 'endLocal', 'end']);
      if (no == null || start == null || end == null) continue;
      byNo[no] = (periodNo: no, startLocal: start, endLocal: end);
    }
    final out = byNo.values.toList()
      ..sort((a, b) => a.periodNo.compareTo(b.periodNo));
    return out;
  }

  static int? _periodNoOf(Map<dynamic, dynamic> m) {
    for (final key in const ['jc', 'jcs', 'periodNo', 'jcmc', 'period']) {
      final n = _firstInt(m[key]);
      if (n != null && n >= 1 && n <= _maxPeriodNo) return n;
    }
    return null;
  }

  static String? _timeOf(Map<dynamic, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = m[key];
      if (value is! String) continue;
      final match = RegExp(r'(\d{1,2})\s*[:：]\s*(\d{2})').firstMatch(value);
      if (match == null) continue;
      final hour = int.tryParse(match.group(1)!);
      final minute = int.tryParse(match.group(2)!);
      if (hour == null || minute == null) continue;
      if (hour > 23 || minute > 59) continue;
      return '${hour.toString().padLeft(2, '0')}:'
          '${minute.toString().padLeft(2, '0')}';
    }
    return null;
  }

  static bool _looksLikeCourseList(List<dynamic> list) {
    for (final entry in list) {
      if (entry is! Map) continue;
      if (entry.containsKey('kcmc') || entry.containsKey('xqj')) return true;
    }
    return false;
  }

  /// Decodes the whole input when it already is JSON.
  static Object? _decodeWhole(String raw) {
    final text = raw.trim();
    if (!text.startsWith('{') && !text.startsWith('[')) return null;
    try {
      return jsonDecode(text);
    } on FormatException {
      return null;
    }
  }

  /// Finds `key: [...]` / `key = [...]` (also `"key":[...]`) in a page source
  /// and returns the decoded array via a balanced-bracket scan.
  static List<dynamic>? _findKeyArray(String raw, String key) {
    final pattern = RegExp(
      '["\']?${RegExp.escape(key)}["\']?\\s*[:=]\\s*\\[',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    if (match == null) return null;
    final start = raw.indexOf('[', match.start);
    if (start < 0) return null;
    final slice = _balancedJson(raw, start);
    if (slice == null) return null;
    try {
      final decoded = jsonDecode(slice);
      if (decoded is List) return decoded;
    } on FormatException {
      return null;
    }
    return null;
  }

  /// Slice of a balanced `[ ... ]` / `{ ... }` block starting at [start],
  /// string-aware.
  static String? _balancedJson(String text, int start) {
    var depth = 0;
    var inString = false;
    var escaped = false;
    for (var i = start; i < text.length; i++) {
      final ch = text[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (ch == r'\') {
          escaped = true;
        } else if (ch == '"') {
          inString = false;
        }
        continue;
      }
      if (ch == '"') {
        inString = true;
      } else if (ch == '[' || ch == '{') {
        depth++;
      } else if (ch == ']' || ch == '}') {
        depth--;
        if (depth == 0) return text.substring(start, i + 1);
      }
    }
    return null;
  }

  // ---- HTML tables ----------------------------------------------------------

  static EduParseResult? _tryHtml(String raw) {
    final lower = raw.toLowerCase();
    if (!lower.contains('<table') && !lower.contains('<tr')) return null;
    var html = raw;
    for (final tag in const ['script', 'style', 'svg', 'head', 'noscript']) {
      html = _removeElement(html, tag);
    }
    final courses = <ParsedCsvCourse>[];
    final seen = <String>{};
    final tables = RegExp(
      r'<table\b[\s\S]*?</table\s*>',
      caseSensitive: false,
    ).allMatches(html);
    for (final table in tables) {
      _parseTable(table.group(0)!, courses, seen);
      if (courses.length >= _maxCourses) break;
    }
    if (courses.isEmpty) return null;
    return EduParseResult(courses: courses, source: 'table');
  }

  static void _parseTable(
    String table,
    List<ParsedCsvCourse> out,
    Set<String> seen,
  ) {
    Map<int, int>? columns; // cell index -> weekday
    final rows = RegExp(
      r'<tr\b[^>]*>([\s\S]*?)</tr\s*>',
      caseSensitive: false,
    ).allMatches(table);
    for (final row in rows) {
      final cells = <String>[
        for (final cell in RegExp(
          r'<t[dh]\b[^>]*>([\s\S]*?)</t[dh]\s*>',
          caseSensitive: false,
        ).allMatches(row.group(1)!))
          cell.group(1)!,
      ];
      if (cells.isEmpty) continue;

      final plain = [for (final cell in cells) _fragmentToText(cell)];
      final header = <int, int>{};
      for (var i = 0; i < plain.length; i++) {
        final weekday = _pureWeekday(plain[i]);
        if (weekday != null) header[i] = weekday;
      }
      if (header.length >= 2) {
        columns = header;
        continue;
      }

      final mapping = columns ?? _inferColumns(plain);
      if (mapping.isEmpty) continue;

      // The row's own label ("第1-2节") supplies the periods when a cell only
      // carries the course name, teacher, room and weeks (classic Zhengfang).
      String? rowPeriod;
      for (var i = 0; i < plain.length; i++) {
        if (mapping.containsKey(i)) continue;
        final flat = _squeeze(plain[i].replaceAll('\n', ' '));
        if (_periodSpan(flat) != null) {
          rowPeriod = flat;
          break;
        }
      }

      for (final entry in mapping.entries) {
        if (entry.key >= cells.length) continue;
        for (final block in _cellBlocks(cells[entry.key])) {
          if (out.length >= _maxCourses) return;
          final course = _courseFromCell(
            block,
            weekday: entry.value,
            line: out.length + 1,
            rowPeriod: rowPeriod,
          );
          if (course == null) continue;
          if (!seen.add(_key(course))) continue;
          out.add(course);
        }
      }
    }
  }

  /// Column mapping for a table without a weekday header row.
  static Map<int, int> _inferColumns(List<String> plain) {
    if (plain.isEmpty) return const {};
    final first = _squeeze(plain.first.replaceAll('\n', ' '));
    final offset = (plain.length >= 8 || _isPeriodLabel(first)) ? 1 : 0;
    final mapping = <int, int>{};
    for (var i = 0; i < plain.length; i++) {
      final weekday = i - offset + 1;
      if (weekday < 1 || weekday > 7) continue;
      mapping[i] = weekday;
    }
    return mapping;
  }

  /// Splits one table cell into course blocks.
  ///
  /// Qiangzhi stacks several courses in one cell and separates them with a run
  /// of hyphens (`-----`) or a blank line (`<br><br>`); both are split first,
  /// keeping the inner HTML so `<font title="...">` metadata survives until
  /// [_courseFromCell] reads it. Single-course cells keep their line breaks as
  /// spaces; multi-course cells split on the next name line after a completed
  /// block (name + week rule).
  static List<String> _cellBlocks(String cellHtml) {
    final blocks = <String>[];
    for (final chunk in cellHtml.split(RegExp(r'-{4,}'))) {
      if (chunk.trim().isEmpty) continue;
      blocks.addAll(_blocksFromChunk(chunk));
    }
    return blocks;
  }

  static List<String> _blocksFromChunk(String chunk) {
    final groups = chunk.split(
      RegExp(r'(?:<br\s*/?>\s*){2,}', caseSensitive: false),
    );
    if (groups.length > 1) {
      return [
        for (final group in groups)
          if (_fragmentToText(group).isNotEmpty) group.trim(),
      ];
    }
    if (_fontTitlePattern.hasMatch(chunk)) return [chunk.trim()];
    return _textBlocks(chunk);
  }

  static List<String> _textBlocks(String cellHtml) {
    final text = _fragmentToText(cellHtml);
    if (text.isEmpty) return const [];
    final lines = [
      for (final line in text.split('\n'))
        if (line.trim().isNotEmpty) line.trim(),
    ];
    if (lines.isEmpty) return const [];
    if (_weeksPattern.allMatches(text).length <= 1) {
      return [lines.join(' ')];
    }
    final blocks = <String>[];
    var current = <String>[];
    for (final line in lines) {
      if (current.isNotEmpty && _startsNewBlock(current.join(' '), line)) {
        blocks.add(current.join(' '));
        current = <String>[];
      }
      current.add(line);
    }
    if (current.isNotEmpty) blocks.add(current.join(' '));
    return blocks;
  }

  static bool _startsNewBlock(String current, String line) {
    if (!_weeksPattern.hasMatch(current)) return false;
    if (line.length > 30) return false;
    if (RegExp(r'\d').hasMatch(line)) return false;
    if (_isPeriodLabel(line)) return false;
    if (_isLocationToken(line)) return false;
    if (_isTeacherMarker(line)) return false;
    // Only a completed block may be closed by the next course's name: either
    // the room is already there, or name + week + teacher are.
    final tokens = current
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList();
    if (tokens.any(_isLocationToken)) return true;
    return tokens.length >= 3;
  }

  // ---- shared course extraction ---------------------------------------------

  /// Extracts one course from a cell block, honouring Qiangzhi `<font title>`.
  static ParsedCsvCourse? _courseFromCell(
    String blockHtml, {
    required int weekday,
    required int line,
    String? rowPeriod,
  }) {
    final hints = _fontHints(blockHtml);
    var text = _fragmentToText(hints.html);
    if (rowPeriod != null &&
        _periodSpan(text) == null &&
        hints.period == null) {
      text = '$text $rowPeriod';
    }
    return _courseFrom(
      text,
      weekdayHint: weekday,
      line: line,
      preferFirstAsName: true,
      teacherOverride: hints.teacher,
      locationOverride: hints.location,
      weekTextOverride: hints.weekText,
      periodOverride: hints.period,
    );
  }

  /// Reads Qiangzhi field annotations and removes those elements so the plain
  /// text keeps only the course name.
  static ({
    String? teacher,
    String? location,
    String? weekText,
    (int, int)? period,
    String html,
  }) _fontHints(String html) {
    String? teacher;
    String? location;
    String? weekText;
    (int, int)? period;
    final cleaned = html.replaceAllMapped(_fontTitlePattern, (match) {
      final title = _squeeze(match.group(1) ?? '');
      final text = _fragmentToText(match.group(2) ?? '');
      if (const {
        '教师',
        '老师',
        '任课教师',
        '上课教师',
        '授课教师',
      }.contains(title)) {
        teacher ??= _cleanTeacher(text);
        return '';
      }
      if (const {'教室', '上课地点', '地点', '上课教室'}.contains(title)) {
        final value = _cleanLocation(text);
        if (value != null) location = '${location ?? ''}$value';
        return '';
      }
      if (title == '教学楼' || title == 'jxlmc') {
        final value = _cleanLocation(text);
        if (value != null) location = '$value${location ?? ''}';
        return '';
      }
      if (title.contains('周次') || title.contains('节次')) {
        if (title.contains('周次')) weekText ??= _weekTextFromFontTitle(text);
        final span = _periodSpan(text);
        if (span != null) period ??= (span.start, span.end);
        return '';
      }
      return match.group(0)!;
    });
    return (
      teacher: teacher,
      location: location,
      weekText: weekText,
      period: period,
      html: cleaned,
    );
  }

  /// `1-16(周)[01-02节]` → `1-16`; `1-16周(单)` → `1-16单`.
  static String? _weekTextFromFontTitle(String text) {
    final parity = RegExp(r'[单双]').firstMatch(text)?.group(0) ?? '';
    final numbers = RegExp(
      r'\d{1,2}(?:\s*[-~—–－至]\s*\d{1,2})?'
      r'(?:\s*[,，、]\s*\d{1,2}(?:\s*[-~—–－至]\s*\d{1,2})?)*',
    ).firstMatch(text)?.group(0);
    if (numbers == null) return null;
    return _weeksFromRaw('$numbers$parity');
  }

  static ParsedCsvCourse? _courseFrom(
    String raw, {
    int? weekdayHint,
    required int line,
    required bool preferFirstAsName,
    String? teacherOverride,
    String? locationOverride,
    String? weekTextOverride,
    (int, int)? periodOverride,
  }) {
    final text = _squeeze(raw);
    if (text.isEmpty) return null;

    final weekdayMatch = _weekdayPattern.firstMatch(text);
    final weekday = weekdayHint ?? _weekdayFromChar(weekdayMatch?.group(1));
    if (weekday == null) return null;

    final weekMatch = _weeksPattern.firstMatch(text);
    var period = periodOverride == null
        ? _periodSpan(text)
        : (start: periodOverride.$1, end: periodOverride.$2, from: 0, to: 0);
    if (period == null) {
      // Last resort: "1-2" without 节, skipping the week column span.
      for (final m in _bareRangePattern.allMatches(text)) {
        if (weekMatch != null &&
            m.start < weekMatch.end &&
            m.end > weekMatch.start) {
          continue;
        }
        final a = int.tryParse(m.group(1)!);
        final b = int.tryParse(m.group(2)!);
        if (a == null || b == null) continue;
        if (a < 1 || b > _maxPeriodNo || a > b) continue;
        period = (start: a, end: b, from: m.start, to: m.end);
        break;
      }
    }
    if (period == null) return null;

    final tokens = _tokens(text, [
      if (weekMatch != null) (start: weekMatch.start, end: weekMatch.end),
      (start: period.from, end: period.to),
      if (weekdayMatch != null)
        (start: weekdayMatch.start, end: weekdayMatch.end),
    ]);
    final resolved = _resolveTokens(
      tokens,
      preferFirstAsName: preferFirstAsName,
    );
    if (resolved == null) return null;

    return ParsedCsvCourse(
      line: line,
      name: _clipName(resolved.name),
      weekday: weekday,
      periodStart: period.start,
      periodEnd: period.end,
      teacher: _cleanTeacher(teacherOverride) ?? resolved.teacher,
      location: _cleanLocation(locationOverride) ?? resolved.location,
      weekRuleText:
          weekTextOverride ??
          (weekMatch == null ? null : _normalizeWeeks(weekMatch)),
    );
  }

  /// Splits [text] into tokens with [spans] removed (fields already consumed).
  static List<String> _tokens(String text, List<({int start, int end})> spans) {
    final sorted = [
      for (final span in spans)
        if (span.end > span.start) span,
    ]..sort((a, b) => a.start.compareTo(b.start));
    final buffer = StringBuffer();
    var cursor = 0;
    for (final span in sorted) {
      if (span.start < cursor) continue;
      buffer.write(text.substring(cursor, span.start));
      buffer.write('\u0000');
      cursor = span.end;
    }
    buffer.write(text.substring(cursor));
    return buffer
        .toString()
        .split(RegExp(r'[\u0000\t|@,，;；]+|\s+'))
        .map((token) => token.trim())
        .where((token) => token.isNotEmpty)
        .toList();
  }

  /// Resolves the course name, teacher and location from the leftover tokens.
  ///
  /// HTML cells put the name first (spec: first non-empty text); copied text
  /// lines may shuffle the order, so the longest plausible token wins.
  static ({String name, String? teacher, String? location})? _resolveTokens(
    List<String> tokens, {
    required bool preferFirstAsName,
  }) {
    final pool = <String>[];
    String? location;
    for (final token in tokens) {
      if (location == null && _isLocationToken(token)) {
        location = _cleanLocation(token);
        continue;
      }
      pool.add(token);
    }
    if (pool.isEmpty) return null;

    var teacherIndex = -1;
    for (var i = 0; i < pool.length; i++) {
      if (_isTeacherMarker(pool[i])) {
        teacherIndex = i;
        break;
      }
    }

    var nameIndex = -1;
    for (var i = 0; i < pool.length; i++) {
      if (i == teacherIndex) continue;
      if (nameIndex < 0) {
        nameIndex = i;
        continue;
      }
      if (!preferFirstAsName && _betterName(pool[i], pool[nameIndex])) {
        nameIndex = i;
      }
    }
    if (nameIndex < 0) return null;

    final name = _cleanName(pool[nameIndex]);
    if (name.isEmpty || _isNoiseName(name)) return null;

    String? teacher;
    if (teacherIndex >= 0) {
      teacher = _cleanTeacher(pool[teacherIndex]);
    } else {
      for (var i = 0; i < pool.length; i++) {
        if (i == nameIndex) continue;
        if (!_isPersonToken(pool[i])) continue;
        teacher = _cleanTeacher(pool[i]);
        break;
      }
    }

    return (name: name, teacher: teacher, location: location);
  }

  static bool _betterName(String candidate, String current) {
    if (candidate.length != current.length) {
      return candidate.length > current.length;
    }
    final candidateIsPerson = _isPersonToken(candidate);
    final currentIsPerson = _isPersonToken(current);
    if (candidateIsPerson != currentIsPerson) return !candidateIsPerson;
    return false;
  }

  static ({int start, int end, int from, int to})? _periodSpan(String text) {
    final pair = _periodPattern.firstMatch(text);
    if (pair != null) return _pairSpan(pair);
    final paren = _periodParenPattern.firstMatch(text);
    if (paren != null) return _pairSpan(paren);
    final single = _periodSinglePattern.firstMatch(text);
    if (single != null) {
      final value = int.tryParse(single.group(1)!);
      if (value != null && value >= 1 && value <= _maxPeriodNo) {
        return (start: value, end: value, from: single.start, to: single.end);
      }
    }
    return null;
  }

  static ({int start, int end, int from, int to})? _pairSpan(RegExpMatch m) {
    final a = int.tryParse(m.group(1)!);
    final b = int.tryParse(m.group(2)!);
    if (a == null || b == null) return null;
    if (a < 1 || b > _maxPeriodNo || a > b) return null;
    return (start: a, end: b, from: m.start, to: m.end);
  }

  // ---- field classifiers ----------------------------------------------------

  static bool _isLocationToken(String token) {
    if (token.isEmpty) return false;
    if (RegExp(r'[楼馆室场厅]').hasMatch(token)) return true;
    if (RegExp(r'机房|校区|教学楼|实验室|广场|体育馆|中心').hasMatch(token)) {
      return true;
    }
    // A bare room number only counts when it is not part of a course name.
    return RegExp(r'^[A-Za-z]?\d{3,4}[A-Za-z]?$').hasMatch(token);
  }

  static bool _isTeacherMarker(String token) {
    return RegExp(r'(?:教授|老师|讲师|助教|教师)$').hasMatch(token);
  }

  /// Loose person-name shape: 2–4 CJK chars, optionally a comma/slash list.
  static bool _isPersonToken(String token) {
    if (token.isEmpty || token.length > 20) return false;
    if (RegExp(r'^\d').hasMatch(token)) return false;
    if (RegExp(r'[楼馆室场厅]').hasMatch(token)) return false;
    if (_isTeacherMarker(token)) return true;
    return RegExp(
      r'^[\u4e00-\u9fa5]{2,4}(?:[,、/，][\u4e00-\u9fa5]{2,4})*$',
    ).hasMatch(token);
  }

  static bool _isNoiseName(String name) {
    if (name.isEmpty) return true;
    if (!RegExp(r'[\u4e00-\u9fa5A-Za-z]').hasMatch(name)) return true;
    return RegExp(
      r'^(?:上午|下午|晚上|中午|早晨|节次|时间|星期|课程表?|备注|说明|无|空)$',
    ).hasMatch(name);
  }

  static bool _isPeriodLabel(String text) {
    if (text.isEmpty) return false;
    return RegExp(
      r'^(?:第?\s*\d{1,2}\s*(?:[-~—–－至]\s*\d{1,2})?\s*节?'
      r'|上午|下午|晚上|中午|早晨|时间|节次|日期)$',
    ).hasMatch(text);
  }

  static bool _isNameCandidateLine(String line) {
    if (line.length < 2 || line.length > 40) return false;
    if (RegExp(r'\d').hasMatch(line)) return false;
    if (_weekdayPattern.hasMatch(line)) return false;
    if (_periodSpan(line) != null) return false;
    if (_isLocationToken(line)) return false;
    if (_isTeacherMarker(line)) return false;
    if (RegExp(r'[：:。；;，,]').hasMatch(line)) return false;
    return RegExp(r'[\u4e00-\u9fa5A-Za-z]').hasMatch(line);
  }

  static bool _isIgnorableLine(String line) {
    if (line.length > 200) return true;
    return RegExp(
      r'课程名称|课程名|节次|周次|上课时间|上课地点|任课教师|备注[:：]|说明[:：]|打印|共\s*\d+\s*页',
    ).hasMatch(line);
  }

  // ---- week / weekday helpers ----------------------------------------------

  static int? _weekdayOf(Object? value) {
    if (value is num) {
      final n = value.toInt();
      if (n == 0) return 7; // some systems use 0 for Sunday
      return n >= 1 && n <= 7 ? n : null;
    }
    if (value is String) {
      final text = value.trim();
      if (text.isEmpty) return null;
      final numeric = int.tryParse(text);
      if (numeric != null) return _weekdayOf(numeric);
      final match = _weekdayPattern.firstMatch(text);
      if (match != null) return _weekdayFromChar(match.group(1));
      // Some systems expose a bare `一`..`日` instead of `周一`.
      if (text.length == 1) return _weekdayFromChar(text);
      return null;
    }
    return null;
  }

  static int? _weekdayFromChar(String? char) {
    if (char == null || char.isEmpty) return null;
    switch (char) {
      case '一':
        return 1;
      case '二':
        return 2;
      case '三':
        return 3;
      case '四':
        return 4;
      case '五':
        return 5;
      case '六':
        return 6;
      case '日':
      case '天':
        return 7;
    }
    final n = int.tryParse(char);
    if (n == null || n < 1 || n > 7) return null;
    return n;
  }

  static int? _pureWeekday(String cellText) {
    final text = _squeeze(cellText.replaceAll('\n', ' '));
    final match = RegExp(r'^(?:周|星期|礼拜)\s*([一二三四五六日天1-7])$').firstMatch(text);
    return _weekdayFromChar(match?.group(1));
  }

  static String? _normalizeWeeks(RegExpMatch match) {
    final body = match.group(1);
    if (body == null) return null;
    final parity =
        match.group(2) ?? match.group(3) ?? match.group(4) ?? match.group(5);
    final suffix = parity == '单'
        ? '单'
        : parity == '双'
        ? '双'
        : '';
    final parts = <String>[];
    for (final piece in body.split(RegExp(r'[,、，]'))) {
      final part = piece
          .replaceAll(RegExp(r'\s*[-~—–－至]\s*'), '-')
          .replaceAll(' ', '')
          .trim();
      if (part.isEmpty) continue;
      parts.add('$part$suffix');
    }
    if (parts.isEmpty) return null;
    final text = parts.join(',');
    return parseWeekRuleText(text) == null ? null : text;
  }

  /// Normalises a raw week column (`1-16周(单)`, `1-16`, `1-5,7-9`) into text
  /// that [parseWeekRuleText] accepts; null when it cannot be understood.
  static String? _weeksFromRaw(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final match = _weeksPattern.firstMatch(text);
    if (match != null) return _normalizeWeeks(match);
    var plain = text
        .replaceFirst(RegExp(r'^第\s*'), '')
        .replaceAll('周次', '')
        .replaceAll(RegExp(r'周$'), '')
        .replaceAll(RegExp(r'[、，；;]'), ',')
        .replaceAll(RegExp(r'[~—–－]'), '-')
        .replaceAll(' ', '');
    plain = plain.replaceAllMapped(
      RegExp(r'[（(]\s*([单双])\s*[)）]'),
      (m) => m.group(1)!,
    );
    if (!RegExp(r'^\d').hasMatch(plain)) return null;
    return parseWeekRuleText(plain) == null ? null : plain;
  }

  static (int, int)? _periodRange(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (RegExp(r'^\d{4}$').hasMatch(text)) {
      final a = int.tryParse(text.substring(0, 2));
      final b = int.tryParse(text.substring(2));
      if (a != null && b != null && a >= 1 && b <= _maxPeriodNo && a <= b) {
        return (a, b);
      }
    }
    final pair = RegExp(r'(\d{1,2})\s*[-~—–－至]\s*(\d{1,2})').firstMatch(text);
    if (pair != null) {
      final a = int.tryParse(pair.group(1)!);
      final b = int.tryParse(pair.group(2)!);
      if (a != null && b != null && a >= 1 && b <= _maxPeriodNo && a <= b) {
        return (a, b);
      }
    }
    final single = RegExp(r'(\d{1,2})').firstMatch(text);
    if (single != null) {
      final a = int.tryParse(single.group(1)!);
      if (a != null && a >= 1 && a <= _maxPeriodNo) return (a, a);
    }
    return null;
  }

  static int? _firstInt(Object? value) {
    if (value is num) return value.toInt();
    if (value is String) {
      final match = RegExp(r'\d{1,2}').firstMatch(value);
      if (match != null) return int.tryParse(match.group(0)!);
    }
    return null;
  }

  static String? _mapString(Map<dynamic, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = m[key];
      if (value is String) {
        final text = value.trim();
        if (text.isNotEmpty) return text;
      } else if (value is num) {
        return value.toString();
      }
    }
    return null;
  }

  // ---- text cleaning --------------------------------------------------------

  static String _cleanName(String raw) {
    var text = raw;
    final at = text.indexOf('@');
    if (at > 0) text = text.substring(0, at);
    text = text
        .replaceAll(_weeksPattern, ' ')
        .replaceAll(_periodPattern, ' ')
        .replaceAll(_periodParenPattern, ' ')
        .replaceAll(_weekdayPattern, ' ');
    text = text.replaceAll(RegExp(r'^[\s*◇◆★☆●○·\-—–_|/\\]+'), '');
    text = _squeeze(text);
    text = text.replaceAll(RegExp(r'^[\s\-—–_|,，、]+'), '');
    text = text.replaceAll(RegExp(r'[\s\-—–_|,，、]+$'), '');
    return text;
  }

  static String _clipName(String name) =>
      name.length > _maxNameLength ? name.substring(0, _maxNameLength) : name;

  static String? _cleanTeacher(String? raw) {
    if (raw == null) return null;
    var text = _squeeze(raw).replaceAll(RegExp(r'^[@:：\s]+'), '');
    text = text.replaceAll(RegExp(r'[@:：\s]+$'), '');
    if (text.isEmpty) return null;
    return text;
  }

  static String? _cleanLocation(String? raw) {
    if (raw == null) return null;
    var text = _squeeze(raw);
    text = text.replaceAll(RegExp(r'^[@:：\s]+'), '');
    text = text.replaceAll(RegExp(r'[@:：\s]+$'), '');
    if (text.isEmpty) return null;
    return text;
  }

  static String _key(ParsedCsvCourse course) =>
      '${course.name}\u0000${course.weekday}\u0000${course.periodStart}'
      '\u0000${course.periodEnd}\u0000${course.weekRuleText ?? ''}';

  // ---- HTML helpers ---------------------------------------------------------

  static String _removeElement(String html, String tag) {
    final pattern = RegExp(
      '<$tag\\b[^>]*>[\\s\\S]*?</$tag\\s*>',
      caseSensitive: false,
    );
    var out = html.replaceAll(pattern, ' ');
    final unclosed = RegExp('<$tag\\b', caseSensitive: false).firstMatch(out);
    if (unclosed != null) out = out.substring(0, unclosed.start);
    return out;
  }

  static String _tagName(String tag) {
    final match = RegExp(r'^</?\s*([a-zA-Z][a-zA-Z0-9]*)').firstMatch(tag);
    return match?.group(1)?.toLowerCase() ?? '';
  }

  /// Cell / fragment text: `<br>` becomes a newline, other tags disappear.
  static String _fragmentToText(String inner) {
    var text = inner;
    text = text.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    text = text.replaceAll(
      RegExp(r'</(?:p|div|li|tr|h[1-6])\s*>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(_tagPattern, '');
    text = _decodeEntities(text);
    final lines = <String>[];
    for (final line in text.split('\n')) {
      final trimmed = _squeeze(line);
      if (trimmed.isNotEmpty) lines.add(trimmed);
    }
    return lines.join('\n');
  }

  /// Whole document as plain text, used when the pasted HTML has no tables.
  static String _plainDocument(String html) {
    var text = html;
    text = text.replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ');
    for (final tag in const ['script', 'style', 'svg', 'head', 'noscript']) {
      text = _removeElement(text, tag);
    }
    text = text.replaceAll(
      RegExp(r'<(?:br|hr)\s*/?>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(
      RegExp(r'</(?:p|div|li|tr|h[1-6]|td|th)\s*>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(_tagPattern, '');
    text = _decodeEntities(text);
    final lines = <String>[];
    for (final line in text.split('\n')) {
      final trimmed = _squeeze(line);
      if (trimmed.isNotEmpty) lines.add(trimmed);
    }
    return lines.join('\n');
  }

  static String _decodeEntities(String text) {
    var out = text
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&ensp;', ' ')
        .replaceAll('&emsp;', ' ')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
    out = out.replaceAllMapped(
      RegExp(r'&#(\d{1,7});'),
      (m) => String.fromCharCode(int.tryParse(m.group(1)!) ?? 32),
    );
    out = out.replaceAllMapped(
      RegExp(r'&#x([0-9a-fA-F]{1,6});'),
      (m) => String.fromCharCode(int.parse(m.group(1)!, radix: 16)),
    );
    out = out.replaceAll('&amp;', '&');
    out = out.replaceAll(RegExp(r'&[a-zA-Z]{2,10};'), ' ');
    return out;
  }

  static String _squeeze(String text) =>
      text.replaceAll(RegExp(r'[\s\u00A0\u3000]+'), ' ').trim();
}

/// One `<table>` candidate for [EduHtmlParser.compressHtmlForAi].
class _AiTable {
  const _AiTable({required this.html, required this.weight});

  final String html;
  final String weight;
}

class _AiTableRow {
  const _AiTableRow(this.cells);

  final List<_AiTableCell> cells;
}

class _AiTableCell {
  const _AiTableCell({required this.text, required this.colspan});

  final String text;
  final int colspan;
}
