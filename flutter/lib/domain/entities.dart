/// Entity type identifiers used by the sync protocol. These MUST match the
/// server `sync.Entity*` constants (server/internal/sync/journal.go) and the
/// OpenAPI contract; do not invent parallel identifiers (agents/flutter-agent
/// principle 3).
class EntityTypes {
  EntityTypes._();

  static const calendar = 'academic_calendar';
  static const period = 'period_template';
  static const course = 'course';
  static const courseMeeting = 'course_meeting';
  static const recurringSchedule = 'recurring_schedule';
  static const todo = 'todo';
  static const todoBlock = 'todo_block';
  static const tag = 'tag';
  static const category = 'todo_category';
  static const override = 'occurrence_override';

  static const all = <String>{
    calendar,
    period,
    course,
    courseMeeting,
    recurringSchedule,
    todo,
    todoBlock,
    tag,
    category,
    override,
  };
}

/// Operation names on the wire (server sync.Op*).
class SyncOperations {
  SyncOperations._();

  static const create = 'create';
  static const update = 'update';
  static const delete = 'delete';
}

/// Series editing scopes (docs/domain-model.md §13).
class SeriesScopes {
  SeriesScopes._();

  static const thisOne = 'THIS';
  static const thisAndFuture = 'THIS_AND_FUTURE';
  static const all = 'ALL';
}

/// Series operation types (server series.Op*).
class SeriesOperations {
  SeriesOperations._();

  static const move = 'MOVE';
  static const update = 'UPDATE';
  static const cancel = 'CANCEL';
  static const delete = 'DELETE';
}
