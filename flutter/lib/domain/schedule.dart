import '../core/util/json_utils.dart';
import 'week_rule.dart';

/// Rule kinds for RecurringSchedule (server schedule.Rule).
enum ScheduleRuleKind {
  daily('daily'),
  weekly('weekly'),
  byAcademicWeek('by_academic_week');

  const ScheduleRuleKind(this.wire);
  final String wire;

  static ScheduleRuleKind? tryFromWire(String? s) {
    switch (s) {
      case 'daily':
        return daily;
      case 'weekly':
        return weekly;
      case 'by_academic_week':
        return byAcademicWeek;
    }
    return null;
  }
}

/// User-defined recurring arrangement rule (docs/domain-model.md §6). Shape
/// mirrors the server `schedule.Rule` JSONB payload exactly.
class ScheduleRule {
  const ScheduleRule({
    required this.kind,
    this.startLocal,
    this.endLocal,
    this.weekdays = const [],
    this.dateStart,
    this.dateEnd,
    this.calendarId,
    this.weekRule,
    this.periodStart = 0,
    this.periodEnd = 0,
  });

  factory ScheduleRule.fromJson(Map<String, dynamic> m) {
    final kind = ScheduleRuleKind.tryFromWire(readStringOrNull(m, 'kind'));
    return ScheduleRule(
      kind: kind ?? ScheduleRuleKind.daily,
      startLocal: readStringOrNull(m, 'startLocal'),
      endLocal: readStringOrNull(m, 'endLocal'),
      weekdays: readIntList(m, 'weekdays'),
      dateStart: readStringOrNull(m, 'dateStart'),
      dateEnd: readStringOrNull(m, 'dateEnd'),
      calendarId: readStringOrNull(m, 'calendarId'),
      weekRule: m.containsKey('weekRule') ? WeekRule.fromJson(m['weekRule']) : null,
      periodStart: readInt(m, 'periodStart'),
      periodEnd: readInt(m, 'periodEnd'),
    );
  }

  final ScheduleRuleKind kind;

  /// `HH:MM` local times for daily/weekly rules (and optional explicit times
  /// for by_academic_week).
  final String? startLocal;
  final String? endLocal;

  /// ISO weekdays 1..7 (weekly / by_academic_week).
  final List<int> weekdays;

  /// `YYYY-MM-DD` bounds for daily/weekly rules.
  final String? dateStart;
  final String? dateEnd;

  /// Academic calendar + week rule for by_academic_week.
  final String? calendarId;
  final WeekRule? weekRule;
  final int periodStart;
  final int periodEnd;

  Map<String, dynamic> toJson() => {
        'kind': kind.wire,
        if (startLocal != null) 'startLocal': startLocal,
        if (endLocal != null) 'endLocal': endLocal,
        if (weekdays.isNotEmpty) 'weekdays': weekdays,
        if (dateStart != null) 'dateStart': dateStart,
        if (dateEnd != null) 'dateEnd': dateEnd,
        if (calendarId != null) 'calendarId': calendarId,
        if (weekRule != null && !weekRule!.isEmpty) 'weekRule': weekRule!.toJson(),
        if (periodStart > 0) 'periodStart': periodStart,
        if (periodEnd > 0) 'periodEnd': periodEnd,
      };
}

/// A user-defined recurring schedule (docs/domain-model.md §6).
class RecurringSchedule {
  const RecurringSchedule({
    required this.id,
    required this.title,
    required this.rule,
    required this.revision,
    this.color,
    this.notes,
    this.deletedAt,
  });

  factory RecurringSchedule.fromJson(Map<String, dynamic> m) =>
      RecurringSchedule(
        id: readString(m, 'id'),
        title: readString(m, 'title'),
        rule: ScheduleRule.fromJson(readMap(m, 'rule')),
        revision: readInt(m, 'revision'),
        color: readStringOrNull(m, 'color'),
        notes: readStringOrNull(m, 'notes'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String title;
  final ScheduleRule rule;
  final String? color;
  final String? notes;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'color': color,
        'rule': rule.toJson(),
        'notes': notes,
        'revision': revision,
      };
}
