import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../core/error/api_exception.dart';
import '../data/api/sync_api.dart';
import '../data/db/app_database.dart';
import '../data/local/sync_store.dart';
import '../domain/entities.dart';
import '../domain/sync.dart';

/// Result of one sync cycle.
class SyncCycleResult {
  const SyncCycleResult({
    this.pushed = 0,
    this.pulled = 0,
    this.conflictCount = 0,
    this.error,
  });

  final int pushed;
  final int pulled;
  final int conflictCount;
  final String? error;

  bool get ok => error == null;
}

/// The offline-first sync engine (docs/sync-protocol.md).
///
/// Cycle order is deliberately pull → push → pull:
/// 1. pull remote journal so [SyncStore] cursor == server cursor,
/// 2. push queued operations with that cursor as baseCursor,
/// 3. pull again so the journal entries produced by accepted/merged pushes
///    land in the local mirror (canonical snapshots, never the optimistic
///    overlay).
class SyncEngine {
  SyncEngine({
    required this.db,
    required this.store,
    required this.api,
  });

  final AppDatabase db;
  final SyncStore store;
  final SyncApi api;
  final _uuid = const Uuid();

  /// How many pages to fetch per cycle before failing over to the next run.
  static const _maxPagesPerPull = 20;

  /// Pulls every journal page from [after] until the journal is drained,
  /// applying payloads to the local mirror. Returns the count applied.
  Future<int> pull({required int after}) async {
    var cursor = after;
    var applied = 0;
    for (var page = 0; page < _maxPagesPerPull; page++) {
      final pageData = await api.changes(after: cursor);
      if (pageData.changes.isEmpty) break;
      for (final change in pageData.changes) {
        await _applyChange(change);
        applied++;
      }
      cursor = pageData.nextCursor;
      if (!pageData.hasMore) break;
    }
    final meta = await store.meta();
    final nextCursor = cursor > (meta?.lastServerCursor ?? 0) ? cursor : meta?.lastServerCursor ?? 0;
    await store.saveMeta((meta ?? const AppMetaSnapshot()).copyWith(lastServerCursor: nextCursor));
    return applied;
  }

  /// Full authoritative pull starting from cursor 0 (first login or hard
  /// refresh). Rebuilds the mirror from the whole journal.
  Future<int> initialPull() => pull(after: 0);

  /// One sync cycle. Never throws: transport errors are captured in the
  /// result and queued operations are preserved.
  Future<SyncCycleResult> syncOnce() async {
    final meta = await store.meta();
    final cursor = meta?.lastServerCursor ?? 0;
    debugPrint('[engine] syncOnce start cursor=$cursor');
    try {
      var pulled = 0;
      // 1. catch up on remote changes first
      final syncState = await api.serverCursor();
      debugPrint('[engine] serverCursor=$syncState');
      if (syncState > cursor) {
        pulled = await pull(after: cursor);
      }
      // 2. push pending operations
      final ops = await store.pendingOps();
      var pushed = 0;
      if (ops.isNotEmpty) {
        final fresh = await store.meta();
        final base = fresh?.lastServerCursor ?? 0;
        debugPrint('[engine] pushing ${ops.length} ops base=$base');
        final result = await api.push(baseCursor: base, operations: ops);
        debugPrint('[engine] push result accepted=${result.accepted.length} '
            'merged=${result.merged.length} conflicts=${result.conflicts.length}');
        await _handlePushResult(result, ops);
        pushed = ops.length;
      }
      // 3. fetch journal entries produced by the push (accepted + merged)
      final afterPush = await store.meta();
      final tail = afterPush?.lastServerCursor ?? 0;
      final state2 = await api.serverCursor();
      debugPrint('[engine] after-push serverCursor=$state2');
      if (state2 > tail) {
        pulled += await pull(after: tail);
      }
      final conflicts = await store.conflicts();
      debugPrint('[engine] syncOnce done pulled=$pulled pushed=$pushed conflicts=${conflicts.length}');
      return SyncCycleResult(
        pushed: pushed,
        pulled: pulled,
        conflictCount: conflicts.length,
      );
    } on ApiException catch (e) {
      debugPrint('[engine] syncOnce ApiException code=${e.code} msg=${e.message}');
      if (e is NetworkException) {
        return SyncCycleResult(error: 'offline');
      }
      return SyncCycleResult(error: e.message);
    } catch (e) {
      debugPrint('[engine] syncOnce error: $e');
      return SyncCycleResult(error: '$e');
    }
  }

  /// Hard refresh (docs/sync-protocol.md §16): preserve pending ops, wipe the
  /// mirror, rebuild from the journal, replay operations locally.
  Future<void> hardRefresh() async {
    final meta = await store.meta();
    // pause: nothing else runs while we hold the db transaction queue
    await store.clearEntities();
    await store.saveMeta((meta ?? const AppMetaSnapshot()).copyWith(lastServerCursor: 0));
    await pull(after: 0);
    await replayPending();
  }

  /// Wipes every local row (mirror, queue, conflicts, meta). Used on logout
  /// and on account switches so one user's data never leaks to another.
  Future<void> resetLocalData() => store.resetForNewUser();

  /// Re-applies queued operations onto the freshly rebuilt mirror so local
  /// optimistic state survives a hard refresh / cache wipe.
  Future<void> replayPending() async {
    final ops = await store.pendingOps();
    for (final op in ops.where((o) => o.operation == SyncOperations.create)) {
      await store.upsertEntityRow(EntityRow(
        entityType: op.entityType,
        entityId: op.entityId,
        revision: 0,
        payload: Map<String, dynamic>.from(op.changes),
        updatedAt: DateTime.now().toUtc(),
      ));
    }
    // update/delete ops only overlay; the canonical rows rebuilt above are
    // authoritative until the next push round.
  }

  // ---- push response handling ----------------------------------------------

  Future<void> _handlePushResult(SyncPushResult result, List<PendingOperation> sent) async {
    final byId = {for (final o in sent) o.operationId: o};

    // Accepted + auto-merged operations: drop them; canonical snapshots
    // arrive through the follow-up pull.
    for (final opId in [...result.accepted, ...result.merged]) {
      await store.removeOp(opId);
    }

    for (final conflict in result.conflicts) {
      final op = byId[conflict.operationId];
      if (op != null) {
        await store.removeOp(op.operationId);
      }
      // Reflect the server's current truth in the mirror immediately so the
      // conflict screen compares real states.
      await _upsertFromPayload(
        conflict.entityType,
        conflict.entityId,
        conflict.server,
      );
      await store.saveConflict(ConflictRecord(
        operationId: conflict.operationId,
        entityType: conflict.entityType,
        entityId: conflict.entityId,
        base: conflict.base,
        local: conflict.local,
        server: conflict.server,
        conflictingFields: conflict.conflictingFields,
        createdAt: DateTime.now().toUtc(),
      ));
    }

    final meta = await store.meta();
    await store.saveMeta((meta ?? const AppMetaSnapshot())
        .copyWith(lastServerCursor: result.serverCursor));
  }

  // ---- conflict resolution (docs/sync-protocol.md §12) ----------------------

  /// Resolves [conflict]. [keepLocal] keeps the local version (re-enqueues an
  /// operation against the server's current state); otherwise the server
  /// version wins and queued edits for that entity are dropped.
  Future<void> resolveConflict(ConflictRecord conflict, {required bool keepLocal}) async {
    final entityKey = '${conflict.entityType}:${conflict.entityId}';
    final otherOps = await store.pendingOps();
    final queued = otherOps
        .where((o) => '${o.entityType}:${o.entityId}' == entityKey)
        .toList();
    await store.removeConflict(conflict.operationId);

    if (!keepLocal) {
      // Server wins: drop every queued op for the entity.
      for (final op in queued) {
        await store.removeOp(op.operationId);
      }
      await _upsertFromPayload(conflict.entityType, conflict.entityId, conflict.server);
      return;
    }

    // Drop the old queued ops; fold everything into one fresh operation based
    // on the server's current revision.
    for (final op in queued) {
      await store.removeOp(op.operationId);
    }

    final wantsDelete = queued.any((o) => o.operation == SyncOperations.delete) ||
        conflict.local.isEmpty;
    if (wantsDelete) {
      await store.enqueueOp(PendingOperation(
        operationId: _uuid.v4(),
        entityType: conflict.entityType,
        entityId: conflict.entityId,
        operation: SyncOperations.delete,
        baseRevision: _serverRevision(conflict.server),
        changes: const {},
        createdAt: DateTime.now().toUtc(),
      ));
      return;
    }

    // Desired final state = server state overlaid with every local difference.
    final serverRev = _serverRevision(conflict.server);
    final diff = _diffMaps(conflict.server, conflict.local);
    await store.enqueueOp(PendingOperation(
      operationId: _uuid.v4(),
      entityType: conflict.entityType,
      entityId: conflict.entityId,
      operation: SyncOperations.update,
      baseRevision: serverRev,
      changes: diff,
      createdAt: DateTime.now().toUtc(),
    ));
  }

  int _serverRevision(Map<String, dynamic> server) {
    final v = server['revision'];
    return v is num ? v.toInt() : 0;
  }

  /// Field differences `local` introduces over `server` (shallow, JSON-aware).
  Map<String, dynamic> _diffMaps(Map<String, dynamic> server, Map<String, dynamic> local) {
    final diff = <String, dynamic>{};
    for (final entry in local.entries) {
      if (entry.key == 'revision' || entry.key == 'deletedAt') continue;
      final sv = server[entry.key];
      if (!_deepEquals(sv, entry.value)) {
        diff[entry.key] = entry.value;
      }
    }
    return diff;
  }

  bool _deepEquals(Object? a, Object? b) {
    if (a is Map && b is Map) {
      final am = Map<String, dynamic>.from(a);
      final bm = Map<String, dynamic>.from(b);
      if (am.length != bm.length) return false;
      for (final k in am.keys) {
        if (!bm.containsKey(k) || !_deepEquals(am[k], bm[k])) return false;
      }
      return true;
    }
    if (a is List && b is List) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (!_deepEquals(a[i], b[i])) return false;
      }
      return true;
    }
    return a == b;
  }

  // ---- journal application ---------------------------------------------------

  Future<void> _applyChange(SyncChange change) async {
    // Do not clobber optimistic local rows with stale server payloads when a
    // queued operation already targets the entity — the push round resolves
    // it (docs/sync-protocol.md normal/concurrent cases).
    final pending = await store.pendingOps(
      entityType: change.entityType,
      entityId: change.entityId,
    );
    if (pending.isNotEmpty) {
      return;
    }
    await _upsertFromPayload(change.entityType, change.entityId, change.payload);
  }

  Future<void> _upsertFromPayload(
    String entityType,
    String entityId,
    Map<String, dynamic> payload,
  ) async {
    final revValue = payload['revision'];
    final revision = revValue is num ? revValue.toInt() : 0;
    final deletedRaw = payload['deletedAt'];
    final deletedAt = deletedRaw is String ? DateTime.tryParse(deletedRaw)?.toUtc() : null;
    await store.upsertEntityRow(EntityRow(
      entityType: entityType,
      entityId: entityId,
      revision: revision,
      payload: Map<String, dynamic>.from(payload),
      updatedAt: deletedAt ?? DateTime.now().toUtc(),
      deletedAt: deletedAt,
    ));
  }
}
