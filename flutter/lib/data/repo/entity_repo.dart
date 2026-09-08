import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../domain/entities.dart';
import '../../domain/sync.dart';
import '../db/app_database.dart';
import '../local/sync_store.dart';

/// Local-first mutation entry point (agents/flutter-agent.md §7-8,
/// docs/sync-protocol.md §5).
///
/// Every mutation:
/// 1. writes the local working copy,
/// 2. appends a pending operation,
/// 3. lets the UI render immediately (optimistic update),
/// 4. the sync engine pushes in the background.
class EntityRepo {
  EntityRepo(this.db, this.store) : _uuid = const Uuid();

  final AppDatabase db;
  final SyncStore store;
  final Uuid _uuid;

  /// Local create: full entity snapshot (server fields minus revision).
  Future<String> localCreate({
    required String entityType,
    required Map<String, dynamic> snapshot,
  }) async {
    final id = _uuid.v4();
    final opId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final payload = Map<String, dynamic>.from(snapshot);
    final clean = Map<String, dynamic>.from(payload)..remove('revision');
    clean['id'] = id;
    await db.transaction(() async {
      await store.upsertEntityRow(EntityRow(
        entityType: entityType,
        entityId: id,
        revision: 0,
        payload: clean,
        updatedAt: now,
      ));
      await store.enqueueOp(PendingOperation(
        operationId: opId,
        entityType: entityType,
        entityId: id,
        operation: SyncOperations.create,
        baseRevision: 0,
        changes: clean,
        createdAt: now,
      ));
    });
    return id;
  }

  /// Local update: [changes] holds the exact fields to change (shallow).
  /// Uses the canonical row revision as the optimistic base.
  Future<void> localUpdate({
    required String entityType,
    required String entityId,
    required Map<String, dynamic> changes,
  }) async {
    final row = await store.entityRow(entityType, entityId);
    final baseRevision = row?.revision ?? 0;
    final opId = _uuid.v4();
    await store.enqueueOp(PendingOperation(
      operationId: opId,
      entityType: entityType,
      entityId: entityId,
      operation: SyncOperations.update,
      baseRevision: baseRevision,
      changes: Map<String, dynamic>.from(changes),
      createdAt: DateTime.now().toUtc(),
    ));
  }

  /// Local delete: keeps the row (tombstone semantics are server-side);
  /// UI hides it because a delete op is queued.
  Future<void> localDelete({
    required String entityType,
    required String entityId,
  }) async {
    final row = await store.entityRow(entityType, entityId);
    final baseRevision = row?.revision ?? 0;
    final opId = _uuid.v4();
    await store.enqueueOp(PendingOperation(
      operationId: opId,
      entityType: entityType,
      entityId: entityId,
      operation: SyncOperations.delete,
      baseRevision: baseRevision,
      changes: const {},
      createdAt: DateTime.now().toUtc(),
    ));
  }

  // ---- convenience: atomic insert of an entity plus nested children --------

  /// Creates a course together with its first meetings as one local
  /// transaction (each entity gets its own create op).
  Future<String> createCourseWithMeetings({
    required Map<String, dynamic> courseSnapshot,
    required List<Map<String, dynamic>> meetingSnapshots,
  }) async {
    final courseId = _uuid.v4();
    final now = DateTime.now().toUtc();
    final courseClean = Map<String, dynamic>.from(courseSnapshot)
      ..remove('revision')
      ..['id'] = courseId;

    await db.transaction(() async {
      await store.upsertEntityRow(EntityRow(
        entityType: EntityTypes.course,
        entityId: courseId,
        revision: 0,
        payload: courseClean,
        updatedAt: now,
      ));
      await store.enqueueOp(PendingOperation(
        operationId: _uuid.v4(),
        entityType: EntityTypes.course,
        entityId: courseId,
        operation: SyncOperations.create,
        baseRevision: 0,
        changes: courseClean,
        createdAt: now,
      ));

      for (final m in meetingSnapshots) {
        final meetingId = _uuid.v4();
        final clean = Map<String, dynamic>.from(m)
          ..remove('revision')
          ..['id'] = meetingId
          ..['courseId'] = courseId;
        await store.upsertEntityRow(EntityRow(
          entityType: EntityTypes.courseMeeting,
          entityId: meetingId,
          revision: 0,
          payload: clean,
          updatedAt: now,
        ));
        await store.enqueueOp(PendingOperation(
          operationId: _uuid.v4(),
          entityType: EntityTypes.courseMeeting,
          entityId: meetingId,
          operation: SyncOperations.create,
          baseRevision: 0,
          changes: clean,
          createdAt: now,
        ));
      }
    });
    return courseId;
  }

  /// Packs an arbitrary map to JSON text (helper for callers that persist
  /// raw payloads, e.g. UI state).
  static String jsonEncodeMap(Map<String, dynamic> m) => jsonEncode(m);
}
