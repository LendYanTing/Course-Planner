/// Local-only course CSV import (docs/csv-import.md).
///
/// Mirrors the server `importcsv` parser: header aliases, Chinese weekdays,
/// week-rule parsing, row-level validation and merging of rows that share
/// `(name, teacher, location)` into one course with several meetings.
/// Parsing, validation and commit all run against the local mirror; no
/// network call is ever made.
library;

import '../core/util/week_text.dart';
import '../data/api/import_api.dart';
import '../data/repo/entity_repo.dart';
import 'calendar.dart';
import 'entities.dart';
import 'week_rule.dart';

/// Result of a local CSV parse: a preview identical in shape to the server's
/// (so the existing page can render it) plus row-level errors.
class LocalCsvResult {
  const LocalCsvResult({
    required this.preview,
    required this.errors,
    required this.maxPeriod,
    this.existingPeriodNos = const <int>{},
  });

  /// `null` whenever [errors] is non-empty.
  final CourseCsvPreview? preview;

  final List<CsvFieldError> errors;

  /// Largest period number used by the CSV (also counts invalid rows that
  /// still carry a parseable period), used to offer creating templates.
  final int maxPeriod;

  /// Period numbers that already have a template in the target calendar.
  final Set<int> existingPeriodNos;

  /// True when at least one period in `1..maxPeriod` has no template yet.
  bool get needsPeriodTemplates {
    if (maxPeriod < 1) return false;
    for (var n = 1; n <= maxPeriod; n++) {
      if (!existingPeriodNos.contains(n)) return true;
    }
    return false;
  }
}

/// Stateless front door for local CSV import. The only state is the parsed row
/// cache keyed by preview id, because [CourseCsvPreview] must stay identical to
/// the server shape and therefore cannot carry the extra merged rows.
abstract final class LocalCsvImporter {
  // ---- header aliases -------------------------------------------------------

  static const _headerAliases = <String, String>{
    '课程名称': 'name',
    '课程名': 'name',
    '课名': 'name',
    'name': 'name',
    '星期': 'weekday',
    '周几': 'weekday',
    'day': 'weekday',
    'weekday': 'weekday',
    '开始节数': 'periodStart',
    '起始节次': 'periodStart',
    '开始节次': 'periodStart',
    'periodstart': 'periodStart',
    '结束节数': 'periodEnd',
    '结束节次': 'periodEnd',
    'periodend': 'periodEnd',
    '老师': 'teacher',
    '教师': 'teacher',
    'teacher': 'teacher',
    '地点': 'location',
    '教室': 'location',
    'location': 'location',
    '周数': 'weeks',
    '周次': 'weeks',
    'weeks': 'weeks',
    'week': 'weeks',
  };

  static const _requiredColumns = <String>[
    'name',
    'weekday',
    'periodStart',
    'periodEnd',
    'weeks',
  ];

  static const _columnLabels = <String, String>{
    'name': '课程名称',
    'weekday': '星期',
    'periodStart': '开始节数',
    'periodEnd': '结束节数',
    'weeks': '周数',
  };

  /// Parsed rows for previews that have not been committed yet. Keyed by the
  /// locally generated preview id.
  static final Map<String, List<_CsvRow>> _pending = <String, List<_CsvRow>>{};
  static int _previewSeq = 0;

  // ---- parse + validate -----------------------------------------------------

  /// Parses [csv] and validates every row against [calendar]'s week range.
  ///
  /// All row errors are collected (never stops at the first one). When any
  /// error exists [LocalCsvResult.preview] is `null`; otherwise the preview
  /// holds one [ParsedCsvCourse] per merged `(name, teacher, location)` group.
  static LocalCsvResult parseAndValidate({
    required String csv,
    required String calendarId,
    required AcademicCalendar calendar,
    required List<PeriodTemplate> periods,
  }) {
    final existingPeriodNos = periods.map((p) => p.periodNo).toSet();
    var text = csv;
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    final rawLines = text.split(RegExp(r'\r\n|\n|\r'));

    List<String>? headerCells;
    var headerLine = 1;
    var dataStart = 0;
    for (var i = 0; i < rawLines.length; i++) {
      final trimmed = rawLines[i].trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      headerCells = _splitLine(trimmed);
      headerLine = i + 1;
      dataStart = i + 1;
      break;
    }

    if (headerCells == null) {
      return LocalCsvResult(
        preview: null,
        errors: const [
          CsvFieldError(
            line: 1,
            field: '表头',
            code: 'CSV_EMPTY',
            message: 'CSV 内容为空',
          ),
        ],
        maxPeriod: 0,
        existingPeriodNos: existingPeriodNos,
      );
    }

    final columns = <String, int>{};
    for (var i = 0; i < headerCells.length; i++) {
      final key = _headerAliases[_normalizeHeader(headerCells[i])];
      if (key != null) columns[key] = i;
      // Unknown columns are ignored on purpose: real exports often carry
      // extra notes columns and failing the whole file is not helpful here.
    }

    final missing = [
      for (final key in _requiredColumns)
        if (!columns.containsKey(key)) _columnLabels[key]!,
    ];
    if (missing.isNotEmpty) {
      return LocalCsvResult(
        preview: null,
        errors: [
          CsvFieldError(
            line: headerLine,
            field: '表头',
            code: 'BAD_HEADER',
            message: '缺少必需列：${missing.join('、')}',
          ),
        ],
        maxPeriod: 0,
        existingPeriodNos: existingPeriodNos,
      );
    }

    var maxAllowedPeriod = 20;
    for (final p in periods) {
      if (p.periodNo > maxAllowedPeriod) maxAllowedPeriod = p.periodNo;
    }

    final errors = <CsvFieldError>[];
    final rows = <_CsvRow>[];
    var maxPeriod = 0;

    for (var i = dataStart; i < rawLines.length; i++) {
      final lineText = rawLines[i].trim();
      if (lineText.isEmpty || lineText.startsWith('#')) continue;
      final lineNo = i + 1;
      final cells = _splitLine(lineText);

      String cell(String field) {
        final idx = columns[field];
        if (idx == null || idx >= cells.length) return '';
        return cells[idx].trim();
      }

      final name = cell('name');
      final weekdayText = cell('weekday');
      final weeksText = cell('weeks');
      // Fully blank data line (e.g. trailing separators).
      if (name.isEmpty && weekdayText.isEmpty && weeksText.isEmpty) continue;

      final teacher = cell('teacher');
      final location = cell('location');
      final startText = cell('periodStart');
      final endText = cell('periodEnd');

      final rowErrors = <CsvFieldError>[];
      void add(String field, String code, String message) {
        rowErrors.add(
          CsvFieldError(
            line: lineNo,
            field: field,
            code: code,
            message: message,
          ),
        );
      }

      if (name.isEmpty) {
        add('课程名称', 'EMPTY_NAME', '课程名称不能为空');
      } else if (name.runes.length > 100) {
        add('课程名称', 'NAME_TOO_LONG', '课程名称不能超过 100 个字符');
      }

      final weekday = _parseWeekday(weekdayText);
      if (weekday == null) {
        add('星期', 'BAD_WEEKDAY', '星期必须是 1-7 或 周一～周日');
      }

      final start = int.tryParse(startText) ?? 0;
      final end = int.tryParse(endText) ?? 0;
      if (end >= 1 && end > maxPeriod) maxPeriod = end;
      if (start < 1 || end < start) {
        add('节次', 'BAD_PERIOD_RANGE', '开始节次必须 ≥1 且不大于结束节次');
      } else if (start > maxAllowedPeriod || end > maxAllowedPeriod) {
        add('节次', 'BAD_PERIOD_RANGE', '节次超出合理范围（1-$maxAllowedPeriod）');
      }

      final rule = parseWeekRuleText(weeksText);
      if (rule == null) {
        add('周数', 'BAD_WEEK_RULE', '无法解析周次（示例：1-16、1-5、7-11单）');
      } else {
        var maxWeek = 0;
        for (final seg in rule.segments) {
          if (seg.end > maxWeek) maxWeek = seg.end;
        }
        if (maxWeek > calendar.totalWeeks) {
          add('周数', 'WEEK_OUT_OF_RANGE', '周次超出学期范围（1-${calendar.totalWeeks}）');
        }
      }

      if (rowErrors.isNotEmpty) {
        errors.addAll(rowErrors);
        continue;
      }

      rows.add(
        _CsvRow(
          line: lineNo,
          name: name,
          weekday: weekday!,
          periodStart: start,
          periodEnd: end,
          teacher: teacher.isEmpty ? null : teacher,
          location: location.isEmpty ? null : location,
          weeksText: weeksText,
          rule: rule!,
        ),
      );
    }

    if (errors.isEmpty && rows.isEmpty) {
      return LocalCsvResult(
        preview: null,
        errors: [
          CsvFieldError(
            line: headerLine,
            field: '表头',
            code: 'CSV_EMPTY',
            message: 'CSV 没有可导入的课程行',
          ),
        ],
        maxPeriod: maxPeriod,
        existingPeriodNos: existingPeriodNos,
      );
    }

    if (errors.isNotEmpty) {
      return LocalCsvResult(
        preview: null,
        errors: errors,
        maxPeriod: maxPeriod,
        existingPeriodNos: existingPeriodNos,
      );
    }

    // Merge rows that describe the same course; the preview shows the first
    // row's meeting while commit restores every row from [_pending].
    final groups = <String, List<_CsvRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(row.groupKey, () => <_CsvRow>[]).add(row);
    }

    final previewId = _nextPreviewId();
    _pending[previewId] = rows;
    _prunePending();

    final preview = CourseCsvPreview(
      previewId: previewId,
      // Local previews never expire server-side; UI only displays this.
      expiresAt: '2099-12-31T23:59:59Z',
      calendarId: calendarId,
      courses: [
        for (final group in groups.values)
          ParsedCsvCourse(
            line: group.first.line,
            name: group.first.name,
            weekday: group.first.weekday,
            periodStart: group.first.periodStart,
            periodEnd: group.first.periodEnd,
            teacher: group.first.teacher,
            location: group.first.location,
            weekRuleText: group.first.weeksText,
          ),
      ],
      conflicts: const [],
    );

    return LocalCsvResult(
      preview: preview,
      errors: const [],
      maxPeriod: maxPeriod,
      existingPeriodNos: existingPeriodNos,
    );
  }

  // ---- commit ---------------------------------------------------------------

  /// Writes the previewed courses locally: one `Course` + N `CourseMeeting`
  /// per merged name, via [EntityRepo.createCourseWithMeetings].
  ///
  /// When [autoCreatePeriods] is true, missing templates in `1..maxPeriod` are
  /// filled first (45-minute periods from 08:00 with a 10-minute break).
  /// Returns the number of courses written.
  static Future<int> commit({
    required EntityRepo repo,
    required CourseCsvPreview preview,
    required String calendarId,
    required List<PeriodTemplate> periods,
    bool autoCreatePeriods = true,
  }) async {
    final rows =
        _pending.remove(preview.previewId) ?? _rowsFromPreview(preview);

    var neededMax = 0;
    for (final row in rows) {
      if (row.periodEnd > neededMax) neededMax = row.periodEnd;
    }

    if (autoCreatePeriods && neededMax > 0) {
      final existing = periods.map((p) => p.periodNo).toSet();
      for (var n = 1; n <= neededMax; n++) {
        if (!existing.add(n)) continue;
        final slot = _defaultSlot(n);
        await repo.localCreate(
          entityType: EntityTypes.period,
          snapshot: {
            'calendarId': calendarId,
            'periodNo': n,
            'startLocal': slot.start,
            'endLocal': slot.end,
          },
        );
      }
    }

    final groups = <String, List<_CsvRow>>{};
    for (final row in rows) {
      groups.putIfAbsent(row.groupKey, () => <_CsvRow>[]).add(row);
    }

    for (final group in groups.values) {
      final first = group.first;
      await repo.createCourseWithMeetings(
        courseSnapshot: {
          'calendarId': calendarId,
          'name': first.name,
          'teacher': first.teacher,
          'location': first.location,
          'color': null,
          'notes': null,
        },
        meetingSnapshots: [
          for (final row in group)
            {
              'weekday': row.weekday,
              'periodStart': row.periodStart,
              'periodEnd': row.periodEnd,
              'weekRule': row.rule.toJson(),
            },
        ],
      );
    }
    return groups.length;
  }

  // ---- helpers --------------------------------------------------------------

  static String _nextPreviewId() {
    _previewSeq++;
    return 'local-${DateTime.now().microsecondsSinceEpoch}-$_previewSeq';
  }

  static void _prunePending() {
    while (_pending.length > 8) {
      _pending.remove(_pending.keys.first);
    }
  }

  /// Fallback when the in-memory row cache was lost (e.g. process restart):
  /// rebuild one row per previewed course.
  static List<_CsvRow> _rowsFromPreview(CourseCsvPreview preview) => [
    for (final c in preview.courses)
      _CsvRow(
        line: c.line,
        name: c.name,
        weekday: c.weekday,
        periodStart: c.periodStart,
        periodEnd: c.periodEnd,
        teacher: c.teacher,
        location: c.location,
        weeksText: c.weekRuleText ?? '',
        rule: parseWeekRuleText(c.weekRuleText ?? '') ?? const WeekRule(),
      ),
  ];

  /// Default schedule: 08:00 start, 45-minute lessons, 10-minute breaks.
  /// Clamped so a template never crosses midnight (periods are capped by
  /// validation at 20, which would otherwise overflow).
  static ({String start, String end}) _defaultSlot(int periodNo) {
    var startMinute = 8 * 60 + (periodNo - 1) * 55;
    if (startMinute > 23 * 60 + 14) startMinute = 23 * 60 + 14;
    var endMinute = startMinute + 45;
    if (endMinute > 23 * 60 + 59) endMinute = 23 * 60 + 59;
    return (start: _hhmm(startMinute), end: _hhmm(endMinute));
  }

  static String _hhmm(int minute) {
    final h = (minute ~/ 60).toString().padLeft(2, '0');
    final m = (minute % 60).toString().padLeft(2, '0');
    return '$h:$m';
  }

  static String _normalizeHeader(String raw) =>
      raw.replaceAll('\uFEFF', '').trim().toLowerCase();

  /// Handles `"` quoting and `""` escapes, `,` and `，` separators.
  static List<String> _splitLine(String line) {
    final fields = <String>[];
    final buffer = StringBuffer();
    var inQuotes = false;
    for (var i = 0; i < line.length; i++) {
      final ch = line[i];
      if (inQuotes) {
        if (ch == '"') {
          if (i + 1 < line.length && line[i + 1] == '"') {
            buffer.write('"');
            i++;
          } else {
            inQuotes = false;
          }
        } else {
          buffer.write(ch);
        }
        continue;
      }
      if (ch == '"') {
        inQuotes = true;
        continue;
      }
      if (ch == ',' || ch == '，') {
        fields.add(buffer.toString().trim());
        buffer.clear();
        continue;
      }
      buffer.write(ch);
    }
    fields.add(buffer.toString().trim());
    return fields;
  }

  static int? _parseWeekday(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final numeric = int.tryParse(text);
    if (numeric != null) return numeric >= 1 && numeric <= 7 ? numeric : null;
    const digits = ['一', '二', '三', '四', '五', '六', '日'];
    for (var i = 0; i < digits.length; i++) {
      final d = digits[i];
      if (text == d || text == '周$d' || text == '星期$d' || text == '礼拜$d') {
        return i + 1;
      }
    }
    if (text == '天' || text == '周天' || text == '星期天') return 7;
    return null;
  }
}

/// One validated CSV data row. Kept beyond the preview so commit can rebuild
/// every meeting of a merged course.
class _CsvRow {
  const _CsvRow({
    required this.line,
    required this.name,
    required this.weekday,
    required this.periodStart,
    required this.periodEnd,
    required this.teacher,
    required this.location,
    required this.weeksText,
    required this.rule,
  });

  final int line;
  final String name;
  final int weekday;
  final int periodStart;
  final int periodEnd;
  final String? teacher;
  final String? location;
  final String weeksText;
  final WeekRule rule;

  String get groupKey => '$name\u0000${teacher ?? ''}\u0000${location ?? ''}';
}
