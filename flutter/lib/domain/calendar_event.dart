import '../core/util/json_utils.dart';

/// Event categories of the unified calendar projection
/// (docs/domain-model.md §14).
enum EventType {
  course('course'),
  recurringSchedule('recurring_schedule'),
  todoBlock('todo_block'),
  deadline('deadline');

  const EventType(this.wire);
  final String wire;

  static EventType fromWire(String? s) {
    switch (s) {
      case 'recurring_schedule':
        return recurringSchedule;
      case 'todo_block':
        return todoBlock;
      case 'deadline':
        return deadline;
      default:
        return course;
    }
  }
}

/// Conflict state of a projected event (docs/domain-model.md §15).
enum ConflictState {
  none('none'),
  soft('soft_conflict'),
  hard('hard_conflict');

  const ConflictState(this.wire);
  final String wire;

  static ConflictState fromWire(String? s) {
    switch (s) {
      case 'soft_conflict':
        return soft;
      case 'hard_conflict':
        return hard;
      default:
        return none;
    }
  }
}

/// Unified calendar event used by week/month views (docs/api.md §11).
class CalendarEvent {
  const CalendarEvent({
    required this.id,
    required this.type,
    required this.title,
    required this.startAt,
    required this.sourceType,
    required this.sourceId,
    required this.conflictState,
    this.endAt,
    this.metadata = const {},
  });

  factory CalendarEvent.fromJson(Map<String, dynamic> m) {
    final source = readMap(m, 'source');
    return CalendarEvent(
      id: readString(m, 'id'),
      type: EventType.fromWire(readStringOrNull(m, 'type')),
      title: readString(m, 'title'),
      startAt: parseUtc(readStringOrNull(m, 'startAt')) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      endAt: parseUtc(readStringOrNull(m, 'endAt')),
      sourceType: readString(source, 'type'),
      sourceId: readString(source, 'id'),
      conflictState: ConflictState.fromWire(readStringOrNull(m, 'conflictState')),
      metadata: readMap(m, 'metadata'),
    );
  }

  final String id;
  final EventType type;
  final String title;
  final DateTime startAt; // UTC
  final DateTime? endAt; // UTC; null for deadline point events
  final String sourceType;
  final String sourceId;
  final ConflictState conflictState;
  final Map<String, dynamic> metadata;

  bool get hasEnd => endAt != null;

  bool overlapsUtc(DateTime s, DateTime e) {
    final end = endAt ?? startAt;
    return startAt.isBefore(e) && end.isAfter(s);
  }
}
