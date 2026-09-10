import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/util/json_utils.dart';
import '../../domain/sync.dart';
import '../db/app_database.dart';

/// A row of the offline entity mirror decoded to Dart values.
class EntityRow {
  const EntityRow({
    required this.entityType,
    required this.entityId,
    required this.revision,
    required this.payload,
    this.updatedAt,
    this.deletedAt,
  });

  final String entityType;
  final String entityId;
  final int revision;
  final Map<String, dynamic> payload;
  final DateTime? updatedAt;
  final DateTime? deletedAt;

  bool get deleted => deletedAt != null;
}

/// Thin typed access to the drift tables plus JSON marshalling. All sync
/// bookkeeping (cursor, ops, conflicts) and the offline mirror live here.
class SyncStore {
  SyncStore(this.db);

  final AppDatabase db;

  // ---- app meta -----------------------------------------------------------

  Future<AppMetaSnapshot?> meta() async {
    final row = await (db.select(db.appMeta)
          ..where((t) => t.id.equals(AppDatabase.metaRowId)))
        .getSingleOrNull();
    if (row == null) return null;
    return AppMetaSnapshot(
      userId: row.userId,
      username: row.username,
      email: row.email,
      timezone: row.timezone,
      lastServerCursor: row.lastServerCursor,
      clockFetchedAt: row.clockFetchedAt,
      clockServerUtc: row.clockServerUtc,
    );
  }

  Future<void> saveMeta(AppMetaSnapshot meta) async {
    await db.into(db.appMeta).insertOnConflictUpdate(AppMetaCompanion.insert(
      id: const Value(AppDatabase.metaRowId),
      userId: Value(meta.userId),
      username: Value(meta.username),
      email: Value(meta.email),
      timezone: Value(meta.timezone),
      lastServerCursor: Value(meta.lastServerCursor),
      clockFetchedAt: Value(meta.clockFetchedAt),
      clockServerUtc: Value(meta.clockServerUtc),
    ));
  }

  // ---- entity mirror ------------------------------------------------------

  Future<void> upsertEntityRow(EntityRow row) async {
    await db.into(db.entities).insertOnConflictUpdate(EntitiesCompanion.insert(
          entityType: row.entityType,
          entityId: row.entityId,
          payload: jsonEncodeJsonSafe(row.payload),
          revision: row.revision,
          updatedAt: Value(row.updatedAt),
          deletedAt: Value(row.deletedAt),
        ));
  }

  Future<void> deleteEntityRow(String entityType, String entityId) async {
    await (db.delete(db.entities)
          ..where((t) =>
              t.entityType.equals(entityType) & t.entityId.equals(entityId)))
        .go();
  }

  Future<void> clearEntities() async {
    await db.delete(db.entities).go();
  }

  Future<void> clearPendingOps() async {
    await db.delete(db.pendingOps).go();
  }

  Future<void> clearConflicts() async {
    await db.delete(db.conflictOps).go();
  }

  /// Resets everything for a fresh (or different) user: mirror, queue,
  /// conflicts, cursor and profile fields. Never throws.
  Future<void> resetForNewUser() async {
    await db.transaction(() async {
      await clearEntities();
      await clearPendingOps();
      await clearConflicts();
      await db.delete(db.appMeta).go();
    });
  }

  Future<EntityRow?> entityRow(String entityType, String entityId) async {
    final row = await (db.select(db.entities)
          ..where((t) =>
              t.entityType.equals(entityType) & t.entityId.equals(entityId)))
        .getSingleOrNull();
    return row == null ? null : _fromDrift(row);
  }

  Future<List<EntityRow>> entitiesOfType(String entityType) async {
    final rows = await (db.select(db.entities)
          ..where((t) => t.entityType.equals(entityType)))
        .get();
    return rows.map(_fromDrift).toList();
  }

  /// Every mirrored row (used by the full backup export and by the
  /// local→cloud migration, which re-uploads the whole working copy).
  Future<List<EntityRow>> allEntities() async {
    final rows = await db.select(db.entities).get();
    return rows.map(_fromDrift).toList();
  }

  /// Resets only the server cursor (keeps mirror + queue). Used when pointing
  /// the same local data at a different server, whose journal cursors are
  /// unrelated to the previous server's.
  Future<void> resetCursor() async {
    final current = await meta();
    await saveMeta(
      (current ?? const AppMetaSnapshot()).copyWith(lastServerCursor: 0),
    );
  }

  Stream<List<EntityRow>> watchEntitiesOfType(String entityType) {
    final query = db.select(db.entities)
      ..where((t) => t.entityType.equals(entityType));
    return query.watch().map((rows) => rows.map(_fromDrift).toList());
  }

  Stream<List<EntityRow>> watchAll() {
    return db.select(db.entities).watch().map((rows) => rows.map(_fromDrift).toList());
  }

  EntityRow _fromDrift(Entity e) => EntityRow(
        entityType: e.entityType,
        entityId: e.entityId,
        revision: e.revision,
        payload: (jsonDecode(e.payload) as Map).cast<String, dynamic>(),
        updatedAt: e.updatedAt,
        deletedAt: e.deletedAt,
      );

  // ---- pending operations --------------------------------------------------

  Future<void> enqueueOp(PendingOperation op) async {
    await db.into(db.pendingOps).insertOnConflictUpdate(
          PendingOpsCompanion.insert(
            operationId: op.operationId,
            entityType: op.entityType,
            entityId: op.entityId,
            operation: op.operation,
            baseRevision: op.baseRevision,
            changes: jsonEncodeJsonSafe(op.changes),
            createdAt: op.createdAt ?? DateTime.now().toUtc(),
            attempts: Value(op.attempts),
            lastError: Value(op.lastError),
          ),
        );
  }

  Future<void> removeOp(String operationId) async {
    await (db.delete(db.pendingOps)
          ..where((t) => t.operationId.equals(operationId)))
        .go();
  }

  Future<PendingOperation?> pendingOp(String operationId) async {
    final row = await (db.select(db.pendingOps)
          ..where((t) => t.operationId.equals(operationId)))
        .getSingleOrNull();
    return row == null ? null : _opFromDrift(row);
  }

  Future<List<PendingOperation>> pendingOps({String? entityType, String? entityId}) async {
    final q = db.select(db.pendingOps);
    if (entityType != null) q.where((t) => t.entityType.equals(entityType));
    if (entityId != null) q.where((t) => t.entityId.equals(entityId));
    q.orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    final rows = await q.get();
    return rows.map(_opFromDrift).toList();
  }

  Stream<List<PendingOperation>> watchPendingOps() {
    final q = db.select(db.pendingOps)..orderBy([(t) => OrderingTerm.asc(t.createdAt)]);
    return q.watch().map((rows) => rows.map(_opFromDrift).toList());
  }

  Future<void> markOpFailed(String operationId, int attempts, String error) async {
    await (db.update(db.pendingOps)..where((t) => t.operationId.equals(operationId)))
        .write(PendingOpsCompanion(attempts: Value(attempts), lastError: Value(error)));
  }

  PendingOperation _opFromDrift(PendingOp row) => PendingOperation(
        operationId: row.operationId,
        entityType: row.entityType,
        entityId: row.entityId,
        operation: row.operation,
        baseRevision: row.baseRevision,
        changes: (jsonDecode(row.changes) as Map).cast<String, dynamic>(),
        createdAt: row.createdAt,
        attempts: row.attempts,
        lastError: row.lastError,
      );

  // ---- conflicts ------------------------------------------------------------

  Future<void> saveConflict(ConflictRecord conflict) async {
    await db.into(db.conflictOps).insertOnConflictUpdate(
          ConflictOpsCompanion.insert(
            operationId: conflict.operationId,
            entityType: conflict.entityType,
            entityId: conflict.entityId,
            base: jsonEncodeJsonSafe(conflict.base),
            local: jsonEncodeJsonSafe(conflict.local),
            server: jsonEncodeJsonSafe(conflict.server),
            conflictingFields: jsonEncode(conflict.conflictingFields),
            createdAt: conflict.createdAt,
          ),
        );
  }

  Future<List<ConflictRecord>> conflicts() async {
    final rows = await db.select(db.conflictOps).get();
    return rows
        .map((r) => ConflictRecord(
              operationId: r.operationId,
              entityType: r.entityType,
              entityId: r.entityId,
              base: (jsonDecode(r.base) as Map).cast<String, dynamic>(),
              local: (jsonDecode(r.local) as Map).cast<String, dynamic>(),
              server: (jsonDecode(r.server) as Map).cast<String, dynamic>(),
              conflictingFields:
                  (jsonDecode(r.conflictingFields) as List).cast<String>(),
              createdAt: r.createdAt,
            ))
        .toList();
  }

  Stream<List<ConflictRecord>> watchConflicts() {
    return db.select(db.conflictOps).watch().map((rows) => rows
        .map((r) => ConflictRecord(
              operationId: r.operationId,
              entityType: r.entityType,
              entityId: r.entityId,
              base: (jsonDecode(r.base) as Map).cast<String, dynamic>(),
              local: (jsonDecode(r.local) as Map).cast<String, dynamic>(),
              server: (jsonDecode(r.server) as Map).cast<String, dynamic>(),
              conflictingFields:
                  (jsonDecode(r.conflictingFields) as List).cast<String>(),
              createdAt: r.createdAt,
            ))
        .toList());
  }

  Future<void> removeConflict(String operationId) async {
    await (db.delete(db.conflictOps)
          ..where((t) => t.operationId.equals(operationId)))
        .go();
  }
}

class AppMetaSnapshot {
  const AppMetaSnapshot({
    this.userId,
    this.username,
    this.email,
    this.timezone,
    this.lastServerCursor = 0,
    this.clockFetchedAt,
    this.clockServerUtc,
  });

  final String? userId;
  final String? username;
  final String? email;
  final String? timezone;
  final int lastServerCursor;
  final DateTime? clockFetchedAt;
  final DateTime? clockServerUtc;

  AppMetaSnapshot copyWith({
    String? userId,
    String? username,
    String? email,
    String? timezone,
    int? lastServerCursor,
    DateTime? clockFetchedAt,
    DateTime? clockServerUtc,
  }) =>
      AppMetaSnapshot(
        userId: userId ?? this.userId,
        username: username ?? this.username,
        email: email ?? this.email,
        timezone: timezone ?? this.timezone,
        lastServerCursor: lastServerCursor ?? this.lastServerCursor,
        clockFetchedAt: clockFetchedAt ?? this.clockFetchedAt,
        clockServerUtc: clockServerUtc ?? this.clockServerUtc,
      );
}

class ConflictRecord {
  const ConflictRecord({
    required this.operationId,
    required this.entityType,
    required this.entityId,
    required this.base,
    required this.local,
    required this.server,
    required this.conflictingFields,
    required this.createdAt,
  });

  final String operationId;
  final String entityType;
  final String entityId;
  final Map<String, dynamic> base;
  final Map<String, dynamic> local;
  final Map<String, dynamic> server;
  final List<String> conflictingFields;
  final DateTime createdAt;
}
