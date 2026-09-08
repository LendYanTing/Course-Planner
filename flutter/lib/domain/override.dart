import '../core/util/json_utils.dart';

/// Series types for occurrence overrides (server override package).
class SeriesTypes {
  SeriesTypes._();

  static const courseMeeting = 'course_meeting';
  static const recurringSchedule = 'recurring_schedule';
}

/// Override actions (docs/domain-model.md §12).
enum OverrideAction {
  move('move'),
  update('update'),
  cancel('cancel');

  const OverrideAction(this.wire);
  final String wire;

  static OverrideAction fromWire(String? s) {
    switch (s) {
      case 'update':
        return update;
      case 'cancel':
        return cancel;
      default:
        return move;
    }
  }
}

/// Occurrence-level patch of a recurring series (docs/domain-model.md §12).
class OccurrenceOverride {
  const OccurrenceOverride({
    required this.id,
    required this.seriesType,
    required this.seriesId,
    required this.occurrenceDateLocal,
    required this.action,
    required this.revision,
    this.replacementStartAt,
    this.replacementEndAt,
    this.metadata = const {},
    this.deletedAt,
  });

  factory OccurrenceOverride.fromJson(Map<String, dynamic> m) =>
      OccurrenceOverride(
        id: readString(m, 'id'),
        seriesType: readString(m, 'seriesType'),
        seriesId: readString(m, 'seriesId'),
        occurrenceDateLocal: readString(m, 'occurrenceDateLocal'),
        action: OverrideAction.fromWire(readStringOrNull(m, 'action')),
        replacementStartAt: parseUtc(readStringOrNull(m, 'replacementStartAt')),
        replacementEndAt: parseUtc(readStringOrNull(m, 'replacementEndAt')),
        metadata: readMap(m, 'metadata'),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String seriesType;
  final String seriesId;

  /// Local `YYYY-MM-DD` of the occurrence being overridden.
  final String occurrenceDateLocal;
  final OverrideAction action;
  final DateTime? replacementStartAt; // UTC
  final DateTime? replacementEndAt; // UTC
  final Map<String, dynamic> metadata;
  final int revision;
  final DateTime? deletedAt;
}
