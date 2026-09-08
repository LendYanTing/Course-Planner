import '../core/util/json_utils.dart';

/// An academic semester (docs/domain-model.md §2). Mirror of the server
/// `academic_calendars` snapshot.
class AcademicCalendar {
  const AcademicCalendar({
    required this.id,
    required this.name,
    required this.firstDay,
    required this.totalWeeks,
    required this.revision,
    this.createdAt,
    this.updatedAt,
    this.deletedAt,
  });

  factory AcademicCalendar.fromJson(Map<String, dynamic> m) => AcademicCalendar(
        id: readString(m, 'id'),
        name: readString(m, 'name'),
        firstDay: readString(m, 'firstDay'),
        totalWeeks: readInt(m, 'totalWeeks'),
        revision: readInt(m, 'revision'),
        createdAt: parseUtc(readStringOrNull(m, 'createdAt')),
        updatedAt: parseUtc(readStringOrNull(m, 'updatedAt')),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String name;

  /// Local date `YYYY-MM-DD` of the semester's first day (week 1, Monday).
  final String firstDay;
  final int totalWeeks;
  final int revision;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'firstDay': firstDay,
        'totalWeeks': totalWeeks,
        'revision': revision,
      };
}

/// A lesson-period time template of a calendar (docs/domain-model.md §3).
/// Times are local `HH:MM` and never cross midnight.
class PeriodTemplate {
  const PeriodTemplate({
    required this.id,
    required this.calendarId,
    required this.periodNo,
    required this.startLocal,
    required this.endLocal,
    required this.revision,
    this.deletedAt,
  });

  factory PeriodTemplate.fromJson(Map<String, dynamic> m) => PeriodTemplate(
        id: readString(m, 'id'),
        calendarId: readString(m, 'calendarId'),
        periodNo: readInt(m, 'periodNo'),
        startLocal: readString(m, 'startLocal'),
        endLocal: readString(m, 'endLocal'),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String calendarId;
  final int periodNo;
  final String startLocal;
  final String endLocal;
  final int revision;
  final DateTime? deletedAt;

  int get startMinute {
    final p = startLocal.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }

  int get endMinute {
    final p = endLocal.split(':');
    return int.parse(p[0]) * 60 + int.parse(p[1]);
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'calendarId': calendarId,
        'periodNo': periodNo,
        'startLocal': startLocal,
        'endLocal': endLocal,
        'revision': revision,
      };
}
