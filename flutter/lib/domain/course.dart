import '../core/util/json_utils.dart';
import 'week_rule.dart';

/// A school course (docs/domain-model.md §4).
class Course {
  const Course({
    required this.id,
    required this.calendarId,
    required this.name,
    required this.revision,
    this.teacher,
    this.location,
    this.color,
    this.notes,
    this.deletedAt,
  });

  factory Course.fromJson(Map<String, dynamic> m) => Course(
        id: readString(m, 'id'),
        calendarId: readString(m, 'calendarId'),
        name: readString(m, 'name'),
        revision: readInt(m, 'revision'),
        teacher: readStringOrNull(m, 'teacher'),
        location: readStringOrNull(m, 'location'),
        color: readStringOrNull(m, 'color'),
        notes: readStringOrNull(m, 'notes'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String calendarId;
  final String name;
  final String? teacher;
  final String? location;
  final String? color;
  final String? notes;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'calendarId': calendarId,
        'name': name,
        'teacher': teacher,
        'location': location,
        'color': color,
        'notes': notes,
        'revision': revision,
      };
}

/// One recurring meeting of a course, e.g. "Monday periods 1-3, weeks 1-16"
/// (docs/domain-model.md §5).
class CourseMeeting {
  const CourseMeeting({
    required this.id,
    required this.courseId,
    required this.weekday,
    required this.periodStart,
    required this.periodEnd,
    required this.weekRule,
    required this.revision,
    this.deletedAt,
  });

  factory CourseMeeting.fromJson(Map<String, dynamic> m) => CourseMeeting(
        id: readString(m, 'id'),
        courseId: readString(m, 'courseId'),
        weekday: readInt(m, 'weekday'),
        periodStart: readInt(m, 'periodStart'),
        periodEnd: readInt(m, 'periodEnd'),
        weekRule: WeekRule.fromJson(m['weekRule']),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String courseId;
  final int weekday; // 1=Monday..7=Sunday (ISO)
  final int periodStart;
  final int periodEnd;
  final WeekRule weekRule;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'courseId': courseId,
        'weekday': weekday,
        'periodStart': periodStart,
        'periodEnd': periodEnd,
        'weekRule': weekRule.toJson(),
        'revision': revision,
      };
}
