import '../core/util/json_utils.dart';

/// One journal entry returned by GET /sync/changes (docs/sync-protocol.md,
/// server sync.Change).
class SyncChange {
  const SyncChange({
    required this.syncSeq,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.revision,
    required this.payload,
    this.createdAt,
  });

  factory SyncChange.fromJson(Map<String, dynamic> m) => SyncChange(
        syncSeq: readInt(m, 'syncSeq'),
        entityType: readString(m, 'entityType'),
        entityId: readString(m, 'entityId'),
        operation: readString(m, 'operation'),
        revision: readInt(m, 'revision'),
        payload: readMap(m, 'payload'),
        createdAt: parseUtc(readStringOrNull(m, 'createdAt')),
      );

  final int syncSeq;
  final String entityType;
  final String entityId;
  final String operation;
  final int revision;
  final Map<String, dynamic> payload;
  final DateTime? createdAt;
}

/// A client-side pending operation (docs/sync-protocol.md §4).
class PendingOperation {
  const PendingOperation({
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.operation,
    required this.baseRevision,
    required this.changes,
    this.createdAt,
    this.attempts = 0,
    this.lastError,
  });

  factory PendingOperation.fromJson(Map<String, dynamic> m) => PendingOperation(
        operationId: readString(m, 'operationId'),
        entityType: readString(m, 'entityType'),
        entityId: readString(m, 'entityId'),
        operation: readString(m, 'operation'),
        baseRevision: readInt(m, 'baseRevision'),
        changes: readMap(m, 'changes'),
        createdAt: parseUtc(readStringOrNull(m, 'createdAt')),
        attempts: readInt(m, 'attempts'),
        lastError: readStringOrNull(m, 'lastError'),
      );

  final String operationId;
  final String entityType;
  final String entityId;
  final String operation;
  final int baseRevision;

  /// Full client-side entity snapshot for `create`; partial field map for
  /// `update`; empty for `delete`.
  final Map<String, dynamic> changes;
  final DateTime? createdAt;
  final int attempts;
  final String? lastError;

  Map<String, dynamic> toJson() => {
        'operationId': operationId,
        'entityType': entityType,
        'entityId': entityId,
        'operation': operation,
        'baseRevision': baseRevision,
        'changes': changes,
        if (createdAt != null) 'createdAt': formatUtc(createdAt!),
        'attempts': attempts,
        if (lastError != null) 'lastError': lastError,
      };
}

/// One field-level conflict returned by the push endpoint
/// (docs/sync-protocol.md §13).
class SyncConflict {
  const SyncConflict({
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.base,
    required this.local,
    required this.server,
    required this.conflictingFields,
  });

  factory SyncConflict.fromJson(Map<String, dynamic> m) => SyncConflict(
        operationId: readString(m, 'operationId'),
        entityType: readString(m, 'entityType'),
        entityId: readString(m, 'entityId'),
        base: readMap(m, 'base'),
        local: readMap(m, 'local'),
        server: readMap(m, 'server'),
        conflictingFields: readStringList(m, 'conflictingFields'),
      );

  final String operationId;
  final String entityType;
  final String entityId;
  final Map<String, dynamic> base;
  final Map<String, dynamic> local;
  final Map<String, dynamic> server;
  final List<String> conflictingFields;
}

/// Push response payload (docs/sync-protocol.md §13).
class SyncPushResult {
  const SyncPushResult({
    required this.accepted,
    required this.merged,
    required this.conflicts,
    required this.serverCursor,
  });

  factory SyncPushResult.fromJson(Map<String, dynamic> m) {
    final data = readMap(m, 'data');
    final conflictsRaw = data['conflicts'];
    return SyncPushResult(
      accepted: readStringList(data, 'accepted'),
      merged: readStringList(data, 'merged'),
      conflicts: conflictsRaw is List
          ? conflictsRaw
              .whereType<Map>()
              .map((e) => SyncConflict.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      serverCursor: readInt(data, 'serverCursor'),
    );
  }

  final List<String> accepted;
  final List<String> merged;
  final List<SyncConflict> conflicts;
  final int serverCursor;
}
