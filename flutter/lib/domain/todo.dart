import '../core/util/json_utils.dart';

/// Todo kinds (docs/domain-model.md §7).
enum TodoType {
  oneOff('one_off'),
  project('project');

  const TodoType(this.wire);
  final String wire;

  static TodoType fromWire(String? s) =>
      s == 'project' ? project : oneOff;
}

/// Todo lifecycle status.
enum TodoStatus {
  todo('todo'),
  inProgress('in_progress'),
  completed('completed'),
  cancelled('cancelled');

  const TodoStatus(this.wire);
  final String wire;

  static TodoStatus fromWire(String? s) {
    switch (s) {
      case 'completed':
        return completed;
      case 'in_progress':
        return inProgress;
      case 'cancelled':
        return cancelled;
      default:
        return todo;
    }
  }
}

/// Todo priority.
enum TodoPriority {
  low('low'),
  normal('normal'),
  high('high'),
  urgent('urgent');

  const TodoPriority(this.wire);
  final String wire;

  static TodoPriority fromWire(String? s) {
    switch (s) {
      case 'low':
        return low;
      case 'high':
        return high;
      case 'urgent':
        return urgent;
      default:
        return normal;
    }
  }
}

/// Block lifecycle status.
enum BlockStatus {
  scheduled('scheduled'),
  inProgress('in_progress'),
  completed('completed'),
  skipped('skipped');

  const BlockStatus(this.wire);
  final String wire;

  static BlockStatus fromWire(String? s) {
    switch (s) {
      case 'in_progress':
        return inProgress;
      case 'completed':
        return completed;
      case 'skipped':
        return skipped;
      default:
        return scheduled;
    }
  }
}

/// A todo item (docs/domain-model.md §7).
class Todo {
  const Todo({
    required this.id,
    required this.title,
    required this.type,
    required this.priority,
    required this.status,
    required this.revision,
    this.description,
    this.categoryId,
    this.tagIds = const [],
    this.estimatedMinutes,
    this.color,
    this.deadlineAt,
    this.deletedAt,
  });

  factory Todo.fromJson(Map<String, dynamic> m) => Todo(
        id: readString(m, 'id'),
        title: readString(m, 'title'),
        type: TodoType.fromWire(readStringOrNull(m, 'type')),
        description: readStringOrNull(m, 'description'),
        categoryId: readStringOrNull(m, 'categoryId'),
        tagIds: readStringList(m, 'tagIds'),
        priority: TodoPriority.fromWire(readStringOrNull(m, 'priority')),
        status: TodoStatus.fromWire(readStringOrNull(m, 'status')),
        estimatedMinutes: readIntOrNull(m, 'estimatedMinutes'),
        color: readStringOrNull(m, 'color'),
        deadlineAt: parseUtc(readStringOrNull(m, 'deadlineAt')),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String title;
  final TodoType type;
  final String? description;
  final String? categoryId;
  final List<String> tagIds;
  final TodoPriority priority;
  final TodoStatus status;
  final int? estimatedMinutes;
  final String? color;
  final DateTime? deadlineAt; // UTC
  final int revision;
  final DateTime? deletedAt;

  bool get isCompleted => status == TodoStatus.completed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'type': type.wire,
        'description': description,
        'categoryId': categoryId,
        'tagIds': tagIds,
        'priority': priority.wire,
        'status': status.wire,
        'estimatedMinutes': estimatedMinutes,
        'color': color,
        if (deadlineAt != null) 'deadlineAt': formatUtc(deadlineAt!),
        'revision': revision,
      };
}

/// One scheduled execution window of a todo (docs/domain-model.md §8).
class TodoBlock {
  const TodoBlock({
    required this.id,
    required this.todoId,
    required this.startAt,
    required this.endAt,
    required this.status,
    required this.revision,
    this.blockNote,
    this.deletedAt,
  });

  factory TodoBlock.fromJson(Map<String, dynamic> m) => TodoBlock(
        id: readString(m, 'id'),
        todoId: readString(m, 'todoId'),
        startAt: parseUtc(readStringOrNull(m, 'startAt')) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        endAt: parseUtc(readStringOrNull(m, 'endAt')) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
        blockNote: readStringOrNull(m, 'blockNote'),
        status: BlockStatus.fromWire(readStringOrNull(m, 'status')),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String todoId;
  final DateTime startAt; // UTC
  final DateTime endAt; // UTC
  final String? blockNote;
  final BlockStatus status;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {
        'id': id,
        'todoId': todoId,
        'startAt': formatUtc(startAt),
        'endAt': formatUtc(endAt),
        'blockNote': blockNote,
        'status': status.wire,
        'revision': revision,
      };
}

/// User tag (docs/domain-model.md §10).
class Tag {
  const Tag({
    required this.id,
    required this.name,
    required this.revision,
    this.color,
    this.deletedAt,
  });

  factory Tag.fromJson(Map<String, dynamic> m) => Tag(
        id: readString(m, 'id'),
        name: readString(m, 'name'),
        color: readStringOrNull(m, 'color'),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String name;
  final String? color;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'revision': revision};
}

/// User todo category (docs/domain-model.md §11).
class Category {
  const Category({
    required this.id,
    required this.name,
    required this.revision,
    this.color,
    this.deletedAt,
  });

  factory Category.fromJson(Map<String, dynamic> m) => Category(
        id: readString(m, 'id'),
        name: readString(m, 'name'),
        color: readStringOrNull(m, 'color'),
        revision: readInt(m, 'revision'),
        deletedAt: parseUtc(readStringOrNull(m, 'deletedAt')),
      );

  final String id;
  final String name;
  final String? color;
  final int revision;
  final DateTime? deletedAt;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'color': color, 'revision': revision};
}
