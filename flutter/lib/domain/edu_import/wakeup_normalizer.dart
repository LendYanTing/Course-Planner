/// Normalises the commercial timetable interchange format (`IClassesItem[]`)
/// and the JSON of four common education systems (JinZhi, ShuWei/EAMS,
/// Qiangzhi 2017 Vue, Chaoxing) into [ParsedCsvCourse] rows.
///
/// Phase 10 Step 1. Every public entry point is total: malformed input yields
/// an empty list instead of throwing. Rows are capped at 500, course names at
/// 100 characters, periods are clamped to `1..20` and week numbers are kept in
/// `parseWeekRuleText` syntax (`1-8`, `1-9单`, `2-8双,12-14`).
library;

import '../../core/util/week_text.dart';
import '../../data/api/import_api.dart';

const int _maxCourses = 500;
const int _maxNameLength = 100;
const int _maxPeriodNo = 20;
const int _maxWeekNo = 60;

/// Result of [WakeupFormatNormalizer.fromAnyJsonWithSource].
typedef VendorJsonParse = ({List<ParsedCsvCourse> courses, String? source});

/// Week/period/vendor normalisation shared by the HTML parser and the AI
/// extractor fallback.
abstract final class WakeupFormatNormalizer {
  // ---- week helpers ---------------------------------------------------------

  /// Compresses explicit week numbers into `parseWeekRuleText` syntax.
  ///
  /// Runs of `+1` become `a-b`; runs of `+2` with at least three weeks become
  /// `a-b单` / `a-b双`; everything else stays a single number.
  static String compressWeekNumsToText(List<int> weekNums) {
    try {
      final weeks = <int>{
        for (final week in weekNums)
          if (week >= 1) week,
      }.toList()..sort();
      if (weeks.isEmpty) return '';
      final parts = <String>[];
      var index = 0;
      while (index < weeks.length) {
        final start = weeks[index];
        var end = index;
        while (end + 1 < weeks.length && weeks[end + 1] == weeks[end] + 1) {
          end++;
        }
        if (end > index) {
          parts.add('$start-${weeks[end]}');
          index = end + 1;
          continue;
        }
        end = index;
        while (end + 1 < weeks.length && weeks[end + 1] == weeks[end] + 2) {
          end++;
        }
        if (end - index >= 2) {
          final parity = start.isOdd ? '单' : '双';
          parts.add('$start-${weeks[end]}$parity');
          index = end + 1;
          continue;
        }
        parts.add('$start');
        index++;
      }
      return parts.join(',');
    } on Object {
      return '';
    }
  }

  /// JinZhi `ZCBH` bitmap (`"10101..."`) to 1-based week numbers.
  static List<int> weekNumsFromZcbh(String zcbh) {
    try {
      final text = zcbh.trim();
      final weeks = <int>[];
      for (var i = 0; i < text.length; i++) {
        if (text[i] == '1') weeks.add(i + 1);
      }
      return weeks;
    } on Object {
      return const [];
    }
  }

  // ---- unified IClassesItem[] ----------------------------------------------

  /// Converts `IClassesItem[]` (a list, or a map wrapping it in `data` /
  /// `classes`) into rows; each `classTimeLoc` becomes its own row.
  static List<ParsedCsvCourse> fromIClassesItems(
    Object? json, {
    List<String>? fallbackPeriods,
  }) {
    try {
      return _fromIClasses(json, fallbackPeriods);
    } on Object {
      return const <ParsedCsvCourse>[];
    }
  }

  // ---- vendor JSON ----------------------------------------------------------

  /// JinZhi `arrangedList` / `datas.getMyScheduleDetail.arrangedList` / `rows`.
  static List<ParsedCsvCourse> fromJinZhi(Object? json) {
    try {
      return _fromJinZhi(json);
    } on Object {
      return const <ParsedCsvCourse>[];
    }
  }

  /// ShuWei/EAMS `studentTableVms[].activities[]` or `lessons[]`.
  static List<ParsedCsvCourse> fromShuWei(Object? json) {
    try {
      return _fromShuWei(json);
    } on Object {
      return const <ParsedCsvCourse>[];
    }
  }

  /// Qiangzhi 2017 Vue rows carrying `xq1`..`xq7`.
  static List<ParsedCsvCourse> fromQiangzhiVue(Object? json) {
    try {
      return _fromQiangzhiVue(json);
    } on Object {
      return const <ParsedCsvCourse>[];
    }
  }

  /// Chaoxing `sdpkkbList` / `data` rows.
  static List<ParsedCsvCourse> fromChaoxing(Object? json) {
    try {
      return _fromChaoxing(json);
    } on Object {
      return const <ParsedCsvCourse>[];
    }
  }

  /// Detects any supported vendor shape and returns the matching rows.
  ///
  /// Unknown or unsupported shapes (e.g. Zhengfang, handled by
  /// `EduHtmlParser`) yield `[]`.
  static List<ParsedCsvCourse> fromAnyJson(Object? json) =>
      fromAnyJsonWithSource(json).courses;

  /// Like [fromAnyJson] but also reports which parser matched, so the caller
  /// can expose a `source` such as `jinzhi-json` or `chaoxing-json`.
  static VendorJsonParse fromAnyJsonWithSource(Object? json) {
    try {
      final source = _detectSource(json, 0);
      if (source == null) {
        return (courses: const <ParsedCsvCourse>[], source: null);
      }
      final courses = switch (source) {
        'iclasses-json' => _fromIClasses(json, null),
        'jinzhi-json' => _fromJinZhi(json),
        'shuwei-json' => _fromShuWei(json),
        'qiangzhi-vue' => _fromQiangzhiVue(json),
        'chaoxing-json' => _fromChaoxing(json),
        _ => const <ParsedCsvCourse>[],
      };
      if (courses.isEmpty) {
        return (courses: const <ParsedCsvCourse>[], source: null);
      }
      return (courses: courses, source: source);
    } on Object {
      return (courses: const <ParsedCsvCourse>[], source: null);
    }
  }

  // ---- IClassesItem[] internals --------------------------------------------

  static List<ParsedCsvCourse> _fromIClasses(
    Object? json,
    List<String>? fallbackPeriods,
  ) {
    final sink = _CourseSink();
    for (final item in _iclassesItems(json)) {
      if (sink.isFull) break;
      if (item is! Map) continue;
      final name = _firstString(item, const [
        'courseName',
        'course_name',
        'name',
      ]);
      if (name == null) continue;
      final locations = _asObjectList(
        item['classTimeLoc'] ?? item['classTimeLocs'],
      );
      final effective = locations.isEmpty && item.containsKey('weekDay')
          ? <Object?>[item]
          : locations;
      for (final location in effective) {
        if (sink.isFull) break;
        if (location is! Map) continue;
        final weekday = _weekdayOf(
          location['weekDay'] ?? location['weekday'] ?? location['dayOfWeek'],
        );
        if (weekday == null) continue;
        final periods = _periodsFromIndexList(
          location['classTimeDailyIdxList'] ??
              location['periods'] ??
              location['sections'],
          fallbackPeriods,
        );
        sink.add(
          name: name,
          weekday: weekday,
          periodStart: periods.$1,
          periodEnd: periods.$2,
          teacher: _teacherText(
            location['teacher'] ??
                location['teachers'] ??
                location['teacherName'],
          ),
          location: _firstString(location, const [
            'location',
            'placeName',
            'room',
          ]),
          weekText: _weekTextFromAny(
            location['weekNums'] ?? location['weeks'] ?? location['weekText'],
          ),
        );
      }
    }
    return sink.courses;
  }

  static List<Object?> _iclassesItems(Object? json) {
    if (json is List) return json;
    if (json is! Map) return const [];
    for (final key in const ['classes', 'data', 'items', 'list']) {
      final value = json[key];
      if (value is List) return value;
      if (value is Map) {
        final nested = _iclassesItems(value);
        if (nested.isNotEmpty) return nested;
      }
    }
    if (json.containsKey('courseName') && json.containsKey('classTimeLoc')) {
      return [json];
    }
    return const [];
  }

  static (int, int) _periodsFromIndexList(
    Object? value,
    List<String>? fallbackPeriods,
  ) {
    final numbers = <int>[];
    if (value is List) {
      for (final entry in value) {
        final number = _firstInt(entry);
        if (number != null) numbers.add(number);
      }
    } else {
      final number = _firstInt(value);
      if (number != null) numbers.add(number);
    }
    if (numbers.isNotEmpty) {
      return _clampRange(numbers.first, numbers.last);
    }
    if (fallbackPeriods != null) {
      for (final raw in fallbackPeriods) {
        final parsed = _periodRangeFromText(raw);
        if (parsed != null) return parsed;
      }
    }
    return (1, 2);
  }

  // ---- JinZhi internals -----------------------------------------------------

  static List<ParsedCsvCourse> _fromJinZhi(Object? json) {
    final sink = _CourseSink();
    for (final entry in _jinZhiEntries(json)) {
      if (sink.isFull) break;
      if (entry is! Map) continue;
      _addJinZhiEntry(entry, sink);
    }
    return sink.courses;
  }

  static List<Object?> _jinZhiEntries(Object? json) {
    if (json is List) return json;
    if (json is! Map) return const [];
    final direct = json['arrangedList'];
    if (direct is List) return direct;
    for (final key in const ['datas', 'data']) {
      final nested = json[key];
      if (nested is! Map) continue;
      final list = nested['arrangedList'];
      if (list is List) return list;
      final detail = nested['getMyScheduleDetail'];
      if (detail is Map) {
        final arranged = detail['arrangedList'];
        if (arranged is List) return arranged;
      }
    }
    final detail = json['getMyScheduleDetail'];
    if (detail is Map) {
      final arranged = detail['arrangedList'];
      if (arranged is List) return arranged;
    }
    final rows = json['rows'];
    if (rows is List) return rows;
    return const [];
  }

  static void _addJinZhiEntry(Map<dynamic, dynamic> entry, _CourseSink sink) {
    final name = _firstString(entry, const [
      'courseName',
      'KCMC',
      'kcmc',
      'KCM',
      'kcm',
    ]);
    if (name == null) return;
    final weekday = _weekdayOf(
      entry['dayOfWeek'] ?? entry['XQ'] ?? entry['xq'] ?? entry['XQMC'],
    );
    if (weekday == null) return;
    final periods = _periodRangeFromValues(
      entry['beginSection'] ??
          entry['KSJCDM'] ??
          entry['KSJC'] ??
          entry['JCFADM'],
      entry['endSection'] ?? entry['JSJCDM'] ?? entry['JSJC'],
    );
    final start = periods?.$1 ?? 1;
    final end = periods?.$2 ?? start;
    final locationRaw = _firstString(entry, const ['placeName', 'JASMC']);
    final teacherRaw = _firstString(entry, const [
      'JSXM',
      'teacherName',
      'SKJS',
    ]);
    final weeksAndTeachers = _firstString(entry, const ['weeksAndTeachers']);

    if (weeksAndTeachers != null && weeksAndTeachers.contains('/')) {
      final places = _splitLocations(locationRaw);
      final segments = weeksAndTeachers
          .split(';')
          .map((segment) => segment.trim())
          .where((segment) => segment.isNotEmpty)
          .toList();
      for (var index = 0; index < segments.length; index++) {
        if (sink.isFull) return;
        final segment = segments[index];
        final slash = segment.indexOf('/');
        final weekPart = slash >= 0 ? segment.substring(0, slash) : segment;
        final teacherPart = slash >= 0
            ? segment.substring(slash + 1).replaceAll(RegExp(r'\[.*?\]'), '')
            : null;
        final weekText = _weekTextFromString(weekPart);
        if (weekText == null) continue;
        sink.add(
          name: name,
          weekday: weekday,
          periodStart: start,
          periodEnd: end,
          teacher: teacherPart ?? teacherRaw,
          location: places.isEmpty
              ? null
              : places[index < places.length ? index : 0],
          weekText: weekText,
        );
      }
      return;
    }

    String? weekText;
    final zcbh = _firstString(entry, const ['ZCBH']);
    if (zcbh != null &&
        zcbh.length >= 2 &&
        RegExp(r'^[01]+$').hasMatch(zcbh)) {
      final numbers = weekNumsFromZcbh(zcbh);
      if (numbers.isNotEmpty) weekText = compressWeekNumsToText(numbers);
    }
    weekText ??= _weekTextFromAny(
      entry['ZCMC'] ?? entry['week'] ?? entry['weeks'],
    );
    final places = _splitLocations(locationRaw);
    sink.add(
      name: name,
      weekday: weekday,
      periodStart: start,
      periodEnd: end,
      teacher: teacherRaw,
      location: places.isEmpty ? null : places.first,
      weekText: weekText,
    );
  }

  static List<String> _splitLocations(String? raw) {
    if (raw == null) return const [];
    final places = <String>[];
    for (final part in raw.split(';')) {
      final value = _cleanOptional(part);
      if (value != null) places.add(value);
    }
    return places;
  }

  // ---- ShuWei internals -----------------------------------------------------

  static List<ParsedCsvCourse> _fromShuWei(Object? json) {
    final sink = _CourseSink();
    for (final activity in _shuWeiEntries(json)) {
      if (sink.isFull) break;
      if (activity is! Map) continue;
      final name =
          _firstString(activity, const [
            'courseName',
            'course_name',
            'name',
          ]) ??
          _nestedCourseName(activity['course']);
      if (name == null) continue;
      final weekday = _weekdayOf(
        activity['weekday'] ?? activity['weekDay'] ?? activity['dayOfWeek'],
      );
      if (weekday == null) continue;
      final periods = _periodRangeFromValues(
        activity['startUnit'] ?? activity['startUnitNum'],
        activity['endUnit'] ?? activity['endUnitNum'],
      );
      final start = periods?.$1 ?? 1;
      final end = periods?.$2 ?? start;
      sink.add(
        name: name,
        weekday: weekday,
        periodStart: start,
        periodEnd: end,
        teacher: _teacherText(
          activity['teachers'] ??
              activity['teacherNames'] ??
              activity['teacher'],
        ),
        location: _firstString(activity, const ['room', 'campus', 'location']),
        weekText: _weekTextFromAny(
          activity['weekIndexes'] ??
              activity['weeksStr'] ??
              activity['weekNums'],
        ),
      );
    }
    return sink.courses;
  }

  static List<Object?> _shuWeiEntries(Object? json) {
    if (json is List) {
      final out = <Object?>[];
      for (final entry in json) {
        if (entry is! Map) continue;
        if (entry.containsKey('studentTableVms') ||
            entry.containsKey('studentTableVm') ||
            entry.containsKey('activities') ||
            entry.containsKey('lessons')) {
          out.addAll(_shuWeiEntries(entry));
        } else {
          out.add(entry);
        }
      }
      return out;
    }
    if (json is! Map) return const [];
    final out = <Object?>[];
    final vms = json['studentTableVms'];
    if (vms is List) {
      for (final vm in vms) {
        if (vm is! Map) continue;
        final activities = vm['activities'] ?? vm['lessons'];
        if (activities is List) out.addAll(activities);
      }
    }
    final single = json['studentTableVm'];
    if (single is Map) {
      final activities = single['activities'];
      if (activities is List) out.addAll(activities);
    }
    for (final key in const ['activities', 'lessons']) {
      final list = json[key];
      if (list is List) out.addAll(list);
    }
    if (out.isNotEmpty) return out;
    final data = json['data'];
    if (data is Map) return _shuWeiEntries(data);
    if (json.containsKey('courseName') ||
        json.containsKey('startUnit') ||
        json.containsKey('weekIndexes')) {
      return [json];
    }
    return const [];
  }

  static String? _nestedCourseName(Object? value) {
    if (value is Map) {
      return _firstString(value, const ['nameZh', 'name', 'courseName']);
    }
    return _textOf(value);
  }

  // ---- Qiangzhi 2017 Vue internals -----------------------------------------

  static List<ParsedCsvCourse> _fromQiangzhiVue(Object? json) {
    final sink = _CourseSink();
    for (final row in _qzRows(json)) {
      if (sink.isFull) break;
      if (row is! Map) continue;
      final rowPeriods = _periodRangeFromJcsj(row['jcsj'] ?? row['xsjc']);
      final rowWeeks = _firstString(row, const ['zc']);
      for (var day = 1; day <= 7; day++) {
        if (sink.isFull) break;
        for (final cell in _qzCells(row['xq$day'])) {
          if (sink.isFull) break;
          _addQzCell(cell, day, rowPeriods, rowWeeks, sink);
        }
      }
    }
    return sink.courses;
  }

  static List<Object?> _qzRows(Object? json) {
    if (json is List) return json;
    if (json is! Map) return const [];
    if (_hasXqKey(json)) return [json];
    for (final key in const ['data', 'rows', 'list', 'result']) {
      final value = json[key];
      if (value is List) return value;
      if (value is Map) {
        final nested = _qzRows(value);
        if (nested.isNotEmpty) return nested;
      }
    }
    return const [];
  }

  static List<Object?> _qzCells(Object? value) {
    if (value is List) {
      final out = <Object?>[];
      for (final entry in value) {
        if (entry is List) {
          out.addAll(_qzCells(entry));
        } else {
          out.add(entry);
        }
      }
      return out;
    }
    if (value is Map) return [value];
    if (value is String) {
      final text = value.trim();
      return text.isEmpty ? const [] : [text];
    }
    return const [];
  }

  static void _addQzCell(
    Object? cell,
    int weekday,
    (int, int)? rowPeriods,
    String? rowWeeks,
    _CourseSink sink,
  ) {
    if (cell is String) {
      _addQzHtmlCell(cell, weekday, rowPeriods, sink);
      return;
    }
    if (cell is! Map) return;
    final name = _cleanVendorName(
      _firstString(cell, const ['kcname', 'ktname', 'courseName', 'kcmc']),
    );
    if (name == null) return;
    final zc = _firstString(cell, const ['zc', 'sksj']) ?? rowWeeks;
    final weekText = zc == null ? null : _weekTextFromString(zc);
    (int, int)? periods;
    if (zc != null) {
      final match = RegExp(
        r'(\d{1,2})\s*-\s*(\d{1,2})\s*节',
      ).firstMatch(zc);
      if (match != null) {
        final start = int.tryParse(match.group(1)!);
        final end = int.tryParse(match.group(2)!);
        if (start != null && end != null) periods = _clampRange(start, end);
      }
    }
    periods ??= _periodRangeFromJcsj(cell['jcsj']);
    periods ??= rowPeriods;
    periods ??= (1, 2);
    sink.add(
      name: name,
      weekday: weekday,
      periodStart: periods.$1,
      periodEnd: periods.$2,
      teacher: _firstString(cell, const ['lsname', 'teacher']),
      location: _firstString(cell, const ['js', 'bjname', 'location']),
      weekText: weekText,
    );
  }

  static void _addQzHtmlCell(
    String html,
    int weekday,
    (int, int)? rowPeriods,
    _CourseSink sink,
  ) {
    final lines = _htmlToLines(html);
    if (lines.isEmpty) return;
    final joined = lines.join(' ');
    String? weekText;
    for (final line in lines) {
      if (!line.contains('周')) continue;
      weekText = _weekTextFromString(line);
      if (weekText != null) break;
    }
    (int, int)? periods;
    final range = RegExp(
      r'(\d{1,2})\s*[-~—–－]\s*(\d{1,2})\s*节',
    ).firstMatch(joined);
    if (range != null) {
      final start = int.tryParse(range.group(1)!);
      final end = int.tryParse(range.group(2)!);
      if (start != null && end != null) periods = _clampRange(start, end);
    }
    periods ??= rowPeriods;
    String? name;
    String? teacher;
    String? location;
    for (final line in lines) {
      if (line.contains('周') || line.contains('节')) continue;
      if (name == null) {
        name = line;
        continue;
      }
      if (location == null && _looksLikeLocation(line)) {
        location = line;
        continue;
      }
      if (teacher == null && _looksLikeTeacher(line)) teacher = line;
    }
    if (name == null) return;
    sink.add(
      name: _cleanVendorName(name),
      weekday: weekday,
      periodStart: periods?.$1 ?? 1,
      periodEnd: periods?.$2 ?? periods?.$1 ?? 1,
      teacher: teacher,
      location: location,
      weekText: weekText,
    );
  }

  static List<String> _htmlToLines(String html) {
    var text = html.replaceAll(
      RegExp(r'<br\s*/?>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(
      RegExp(r'</(?:p|div|li|tr)\s*>', caseSensitive: false),
      '\n',
    );
    text = text.replaceAll(RegExp(r'<[^>]*>'), ' ');
    text = _decodeEntities(text);
    return [
      for (final line in text.split('\n'))
        if (_squeeze(line).isNotEmpty) _squeeze(line),
    ];
  }

  static bool _looksLikeLocation(String line) {
    if (line.isEmpty) return false;
    if (RegExp(r'[楼馆室场厅]').hasMatch(line)) return true;
    if (RegExp(r'机房|校区|教学楼|实验室|广场|体育馆|中心').hasMatch(line)) {
      return true;
    }
    return RegExp(r'^[A-Za-z]?\d{3,4}[A-Za-z]?$').hasMatch(line);
  }

  static bool _looksLikeTeacher(String line) {
    if (line.isEmpty || line.length > 20) return false;
    if (RegExp(r'(?:教授|老师|讲师|助教|教师)$').hasMatch(line)) return true;
    return RegExp(r'^[\u4e00-\u9fa5]{2,4}$').hasMatch(line);
  }

  // ---- Chaoxing internals ---------------------------------------------------

  static List<ParsedCsvCourse> _fromChaoxing(Object? json) {
    final sink = _CourseSink();
    for (final entry in _chaoxingEntries(json)) {
      if (sink.isFull) break;
      if (entry is! Map) continue;
      final name = _chaoxingName(entry);
      if (name == null) continue;
      final weekday = _weekdayOf(entry['xingqi'] ?? entry['weekday']);
      if (weekday == null) continue;
      final periods = _periodRangeFromValues(entry['djc'], null);
      sink.add(
        name: name,
        weekday: weekday,
        periodStart: periods?.$1 ?? 1,
        periodEnd: periods?.$2 ?? periods?.$1 ?? 1,
        teacher: _stripTags(_textOf(entry['tmc']) ?? ''),
        location: _stripTags(_textOf(entry['croommc']) ?? ''),
        weekText: _weekTextFromAny(entry['zcstr'] ?? entry['weeks']),
      );
    }
    return sink.courses;
  }

  static List<Object?> _chaoxingEntries(Object? json) {
    if (json is List) return json;
    if (json is! Map) return const [];
    final list = json['sdpkkbList'];
    if (list is List) return list;
    final data = json['data'];
    if (data is List) return data;
    if (data is Map) return _chaoxingEntries(data);
    if (json.containsKey('kcmc')) return [json];
    return const [];
  }

  static String? _chaoxingName(Map<dynamic, dynamic> entry) {
    final raw = _textOf(entry['kcmc']);
    if (raw != null) {
      final anchor = RegExp(
        r'<a\b[^>]*>([\s\S]*?)</a\s*>',
        caseSensitive: false,
      ).firstMatch(raw);
      final name = _squeeze(_stripTags(anchor?.group(1) ?? raw));
      if (name.isNotEmpty) return name;
    }
    return _firstString(entry, const ['jxbmc', 'ktmc']);
  }

  // ---- detection ------------------------------------------------------------

  static String? _detectSource(Object? json, int depth) {
    if (depth > 4) return null;
    if (json is List) return _detectList(json, depth);
    if (json is Map) return _detectMap(json, depth);
    return null;
  }

  static String? _detectList(List<dynamic> list, int depth) {
    for (final entry in list) {
      if (entry is! Map) continue;
      final source = _detectMap(entry, depth + 1);
      if (source != null) return source;
    }
    return null;
  }

  static String? _detectMap(Map<dynamic, dynamic> map, int depth) {
    if (depth > 4) return null;
    if (map['arrangedList'] is List) return 'jinzhi-json';
    final datas = map['datas'];
    if (datas is Map) {
      if (datas['arrangedList'] is List) return 'jinzhi-json';
      final detail = datas['getMyScheduleDetail'];
      if (detail is Map && detail['arrangedList'] is List) {
        return 'jinzhi-json';
      }
      final nested = _detectMap(datas, depth + 1);
      if (nested != null) return nested;
    }
    final detail = map['getMyScheduleDetail'];
    if (detail is Map && detail['arrangedList'] is List) {
      return 'jinzhi-json';
    }
    if (map['studentTableVms'] is List || map['studentTableVm'] is Map) {
      return 'shuwei-json';
    }
    if (map['activities'] is List || map['lessons'] is List) {
      return 'shuwei-json';
    }
    if (map['sdpkkbList'] is List) return 'chaoxing-json';
    if (_hasXqKey(map)) return 'qiangzhi-vue';
    if (map['kbList'] is List) return null; // new Zhengfang, handled elsewhere
    if (_looksIClasses(map)) return 'iclasses-json';
    for (final key in const ['data', 'classes', 'rows', 'result', 'list']) {
      final value = map[key];
      if (value is List) {
        final source = _detectList(value, depth + 1);
        if (source != null) return source;
      } else if (value is Map) {
        final source = _detectMap(value, depth + 1);
        if (source != null) return source;
      }
    }
    if (_looksShuWei(map)) return 'shuwei-json';
    if (map.containsKey('kcmc') &&
        (map.containsKey('xqj') || map.containsKey('jcs'))) {
      return null; // Zhengfang row
    }
    if (map.containsKey('kcmc')) return 'chaoxing-json';
    if (map.containsKey('KCMC') ||
        map.containsKey('ZCBH') ||
        map.containsKey('weeksAndTeachers') ||
        map.containsKey('KSJCDM') ||
        (map.containsKey('dayOfWeek') && map.containsKey('beginSection'))) {
      return 'jinzhi-json';
    }
    return null;
  }

  static bool _hasXqKey(Map<dynamic, dynamic> map) {
    for (var day = 1; day <= 7; day++) {
      if (map.containsKey('xq$day')) return true;
    }
    return false;
  }

  static bool _looksIClasses(Map<dynamic, dynamic> map) =>
      map['classTimeLoc'] is List &&
      (map.containsKey('courseName') || map.containsKey('course_name'));

  static bool _looksShuWei(Map<dynamic, dynamic> map) =>
      (map.containsKey('courseName') || map['course'] is Map) &&
      (map.containsKey('startUnit') ||
          map.containsKey('endUnit') ||
          map.containsKey('weekIndexes') ||
          map.containsKey('weekday'));
}

// ---- shared helpers ---------------------------------------------------------

class _CourseSink {
  final List<ParsedCsvCourse> courses = <ParsedCsvCourse>[];
  final Set<String> _seen = <String>{};

  bool get isFull => courses.length >= _maxCourses;

  void add({
    required String? name,
    required int weekday,
    required int periodStart,
    required int periodEnd,
    String? teacher,
    String? location,
    String? weekText,
  }) {
    if (isFull) return;
    final cleanName = _clipName(_cleanNameText(name));
    if (cleanName.isEmpty || weekday < 1 || weekday > 7) return;
    final range = _clampRange(periodStart, periodEnd);
    final row = ParsedCsvCourse(
      line: courses.length + 1,
      name: cleanName,
      weekday: weekday,
      periodStart: range.$1,
      periodEnd: range.$2,
      teacher: _cleanOptional(teacher),
      location: _cleanOptional(location),
      weekRuleText: _cleanOptional(weekText),
    );
    final key =
        '${row.name}\u0000${row.weekday}\u0000${row.periodStart}'
        '\u0000${row.periodEnd}\u0000${row.weekRuleText ?? ''}'
        '\u0000${row.teacher ?? ''}\u0000${row.location ?? ''}';
    if (!_seen.add(key)) return;
    courses.add(row);
  }
}

String? _cleanNameText(String? raw) {
  if (raw == null) return null;
  var text = _squeeze(_stripTags(raw));
  text = text.replaceFirst(RegExp(r'^\*+\s*'), '');
  if (text.isEmpty) return null;
  return text;
}

String _clipName(String? name) {
  final text = name ?? '';
  return text.length > _maxNameLength
      ? text.substring(0, _maxNameLength)
      : text;
}

String? _cleanVendorName(String? raw) {
  final text = _cleanNameText(raw);
  if (text == null) return null;
  return _squeeze(text);
}

String? _cleanOptional(String? raw) {
  if (raw == null) return null;
  var text = _squeeze(raw);
  if (text.isEmpty) return null;
  final lower = text.toLowerCase();
  if (text == '-' || text == '—' || text == '–' || lower == 'null') return null;
  text = text.replaceAll(RegExp(r'^[@:：,，、\s]+'), '');
  text = text.replaceAll(RegExp(r'[@:：,，、\s]+$'), '');
  return text.isEmpty ? null : text;
}

(int, int) _clampRange(int start, int end) {
  var first = _clampPeriod(start);
  var last = _clampPeriod(end);
  if (last < first) {
    final swap = first;
    first = last;
    last = swap;
  }
  return (first, last);
}

int _clampPeriod(int value) {
  if (value < 1) return 1;
  if (value > _maxPeriodNo) return _maxPeriodNo;
  return value;
}

(int, int)? _periodRangeFromValues(Object? startValue, Object? endValue) {
  if (endValue == null) {
    if (startValue is String) {
      final parsed = _periodRangeFromText(startValue);
      if (parsed != null) return parsed;
    }
  }
  final start = _firstInt(startValue);
  final end = _firstInt(endValue);
  if (start == null && end == null) return null;
  final resolvedStart = start ?? end!;
  final resolvedEnd = end ?? start!;
  return _clampRange(resolvedStart, resolvedEnd);
}

(int, int)? _periodRangeFromText(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return null;
  final pair = RegExp(
    r'(\d{1,2})\s*[-~—–－至]\s*(\d{1,2})',
  ).firstMatch(text);
  int? start;
  int? end;
  if (pair != null) {
    start = int.tryParse(pair.group(1)!);
    end = int.tryParse(pair.group(2)!);
  } else {
    final single = RegExp(r'\d{1,2}').firstMatch(text);
    if (single != null) {
      start = int.tryParse(single.group(0)!);
      end = start;
    }
  }
  if (start == null) return null;
  return _clampRange(start, end ?? start);
}

(int, int)? _periodRangeFromJcsj(Object? raw) {
  if (raw is List) {
    for (final entry in raw) {
      if (entry is Map) {
        final parsed = _periodRangeFromJcsj(entry['jcsj']);
        if (parsed != null) return parsed;
      }
      final parsed = _periodRangeFromJcsj(entry);
      if (parsed != null) return parsed;
    }
    return null;
  }
  if (raw is! String) return null;
  final text = raw.trim();
  if (text.isEmpty) return null;
  final range = RegExp(r'(\d{1,2})\s*-\s*(\d{1,2})').firstMatch(text);
  if (range != null) {
    final start = int.tryParse(range.group(1)!);
    final end = int.tryParse(range.group(2)!);
    if (start != null && end != null) return _clampRange(start, end);
  }
  final numbers = <int>[];
  for (final match in RegExp(r'\d{2}').allMatches(text)) {
    final value = int.tryParse(match.group(0)!);
    if (value != null) numbers.add(value);
  }
  if (numbers.isEmpty) return _periodRangeFromText(text);
  numbers.sort();
  return _clampRange(numbers.first, numbers.last);
}

String? _weekTextFromAny(Object? value) {
  if (value is List) {
    final weeks = <int>[];
    for (final entry in value) {
      final number = _firstInt(entry);
      if (number != null && number >= 1) weeks.add(number);
    }
    if (weeks.isEmpty) return null;
    final compact = WakeupFormatNormalizer.compressWeekNumsToText(weeks);
    return _validatedWeekText(compact.isEmpty ? null : compact);
  }
  if (value is num) {
    if (value < 1) return null;
    return WakeupFormatNormalizer.compressWeekNumsToText([value.toInt()]);
  }
  if (value is String) return _weekTextFromString(value);
  return null;
}

String? _weekTextFromString(String raw) {
  var text = _stripTags(raw).trim();
  if (text.isEmpty) return null;
  // Period clauses are part of Qiangzhi's combined `zc` string.
  text = text.replaceAll(
    RegExp(r'第?\s*\d{1,2}\s*(?:[-~—–－至]\s*\d{1,2})?\s*节'),
    ' ',
  );
  text = text.replaceAll(
    RegExp(r'\[\s*\d{1,2}\s*(?:[-~—–－至]\s*\d{1,2})?\s*节?\s*\]'),
    ' ',
  );
  final bracket = text.indexOf('[');
  if (bracket > 0) text = text.substring(0, bracket);
  text = text.replaceAllMapped(
    RegExp(r'[（(]\s*([单双])\s*周?\s*[)）]'),
    (match) => match.group(1)!,
  );
  text = text.replaceAll(RegExp(r'[（(]\s*周\s*[)）]'), '');
  text = text.replaceAll(RegExp(r'[（(][^()）]*[)）]'), '');
  text = text.replaceAll('周次', '').replaceAll('第', '');
  text = text.replaceAll('周', '');
  text = text.replaceAll(RegExp(r'[、，；;]'), ',');
  text = text.replaceAll(RegExp(r'[~—–－至]'), '-');
  text = text.replaceAll(RegExp(r'[^0-9\-,单双]'), '');
  if (!RegExp(r'\d').hasMatch(text)) return null;
  final weeks = <int>[];
  for (final part in text.split(',')) {
    if (part.isEmpty) continue;
    var parity = 0;
    var body = part;
    if (body.endsWith('单')) {
      parity = 1;
      body = body.substring(0, body.length - 1);
    } else if (body.endsWith('双')) {
      parity = 2;
      body = body.substring(0, body.length - 1);
    }
    body = body.replaceAll(RegExp(r'[单双]'), '');
    if (body.isEmpty) continue;
    int? start;
    int? end;
    final dash = body.indexOf('-');
    if (dash >= 0) {
      start = int.tryParse(body.substring(0, dash));
      end = int.tryParse(body.substring(dash + 1)) ?? start;
    } else {
      start = int.tryParse(body);
      end = start;
    }
    if (start == null || end == null) continue;
    var from = start;
    var to = end;
    if (from < 1) from = 1;
    if (to < 1) to = 1;
    if (from > _maxWeekNo) from = _maxWeekNo;
    if (to > _maxWeekNo) to = _maxWeekNo;
    if (to < from) continue;
    for (var week = from; week <= to; week++) {
      if (parity == 1 && week.isEven) continue;
      if (parity == 2 && week.isOdd) continue;
      weeks.add(week);
    }
  }
  if (weeks.isEmpty) return null;
  weeks.sort();
  final compact = WakeupFormatNormalizer.compressWeekNumsToText(weeks);
  return _validatedWeekText(compact.isEmpty ? null : compact);
}

int? _weekdayOf(Object? value) {
  int? number;
  if (value is num) {
    number = value.toInt();
  } else if (value is String) {
    final text = value.trim();
    if (text.isEmpty) return null;
    number = int.tryParse(text);
    if (number == null) {
      final match = RegExp(
        r'(?:周|星期|礼拜)\s*([一二三四五六日天1-7])',
      ).firstMatch(text);
      final token = match?.group(1) ?? (text.length == 1 ? text : null);
      number = _weekdayFromChar(token);
    }
  }
  if (number == null) return null;
  if (number == 0 || number == 7) return 7;
  if (number >= 1 && number <= 6) return number;
  return null;
}

int? _weekdayFromChar(String? token) {
  if (token == null || token.isEmpty) return null;
  switch (token) {
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
  final number = int.tryParse(token);
  if (number == null) return null;
  if (number == 0 || number == 7) return 7;
  return number >= 1 && number <= 6 ? number : null;
}

String? _teacherText(Object? value) {
  if (value is List) {
    final names = <String>[];
    for (final entry in value) {
      if (entry is Map) {
        final name = _firstString(entry, const [
          'name',
          'nameZh',
          'teacherName',
          'label',
        ]);
        if (name != null) names.add(name.split('&nbsp').first.trim());
      } else {
        final text = _textOf(entry);
        if (text != null) {
          final name = text.split('&nbsp').first.trim();
          if (name.isNotEmpty) names.add(name);
        }
      }
    }
    return names.isEmpty ? null : names.join(',');
  }
  return _textOf(value);
}

List<Object?> _asObjectList(Object? value) => value is List ? value : const [];

String? _firstString(Map<dynamic, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final text = _textOf(map[key]);
    if (text != null && text.trim().isNotEmpty) return text.trim();
  }
  return null;
}

String? _textOf(Object? value) {
  if (value is String) return value;
  if (value is num) return value.toString();
  return null;
}

int? _firstInt(Object? value) {
  if (value is num) return value.toInt();
  if (value is String) {
    final match = RegExp(r'\d{1,3}').firstMatch(value);
    if (match != null) return int.tryParse(match.group(0)!);
  }
  return null;
}

String _stripTags(String html) {
  var text = html.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), ' ');
  text = text.replaceAll(RegExp(r'<[^>]*>'), '');
  return _decodeEntities(text);
}

String _decodeEntities(String text) {
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
    (match) => String.fromCharCode(int.tryParse(match.group(1)!) ?? 32),
  );
  out = out.replaceAllMapped(
    RegExp(r'&#x([0-9a-fA-F]{1,6});'),
    (match) => String.fromCharCode(int.parse(match.group(1)!, radix: 16)),
  );
  out = out.replaceAll('&amp;', '&');
  return out;
}

String _squeeze(String text) =>
    text.replaceAll(RegExp(r'[\s\u00A0\u3000]+'), ' ').trim();

// Kept so `parseWeekRuleText` stays part of the public contract checked by the
// normaliser: week text is only emitted when that parser accepts it.
String? _validatedWeekText(String? text) {
  if (text == null || text.isEmpty) return null;
  return parseWeekRuleText(text) == null ? null : text;
}
