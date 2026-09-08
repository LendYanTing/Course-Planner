import '../../domain/entities.dart';
import '../../domain/sync.dart';
import '../local/sync_store.dart';

/// In-memory view over the offline mirror + operation queue + conflicts.
///
/// Produced by combining the three drift watch streams so every UI feature
/// derives from one consistent snapshot (docs/sync-protocol.md §5).
class EntitiesSnapshot {
  const EntitiesSnapshot({
    required this.rows,
    required this.pendingOps,
    required this.conflicts,
  });

  final List<EntityRow> rows;
  final List<PendingOperation> pendingOps;
  final List<ConflictRecord> conflicts;

  List<EntityRow> rowsOf(String entityType) =>
      rows.where((r) => r.entityType == entityType).toList();

  /// Rows whose canonical state has been touched by at least one queued op.
  Map<String, List<PendingOperation>> get pendingByEntity {
    final map = <String, List<PendingOperation>>{};
    for (final op in pendingOps) {
      map.putIfAbsent('${op.entityType}:${op.entityId}', () => []).add(op);
    }
    return map;
  }
}

/// One entity after overlaying queued local operations onto the canonical
/// server snapshot. This is what the UI renders (optimistic local update).
class EffectiveEntity {
  const EffectiveEntity({
    required this.payload,
    required this.revision,
    this.locallyDeleted = false,
    this.hasPendingOp = false,
    this.isLocalCreate = false,
  });

  final Map<String, dynamic> payload;
  final int revision;
  final bool locallyDeleted;
  final bool hasPendingOp;

  /// True when the row exists only locally (create not yet acknowledged).
  final bool isLocalCreate;
}

/// Applies [op.changes] over [base] (shallow field merge — same semantics as
/// the server's field-aware update).
Map<String, dynamic> overlayChanges(Map<String, dynamic> base, Map<String, dynamic> changes) {
  final out = Map<String, dynamic>.from(base);
  out.addAll(changes);
  return out;
}

/// Builds the effective entity list for [entityType] from a snapshot:
/// canonical rows overlaid by queued updates, local creates included,
/// locally-deleted entities excluded.
List<EffectiveEntity> effectiveFor(EntitiesSnapshot snapshot, String entityType) {
  final pendingByEntity = <String, List<PendingOperation>>{};
  for (final op in snapshot.pendingOps) {
    pendingByEntity.putIfAbsent('${op.entityType}:${op.entityId}', () => []).add(op);
  }

  final out = <EffectiveEntity>[];
  final seen = <String>{};

  // Local-only creates may not have a canonical row yet.
  for (final entry in pendingByEntity.entries) {
    if (!entry.key.startsWith('$entityType:')) continue;
    final id = entry.key.substring(entityType.length + 1);
    final createOps = entry.value.where((o) => o.operation == SyncOperations.create).toList();
    if (createOps.isEmpty) continue;
    if (rowsOf(snapshot, entityType, id) != null) continue; // canonical exists
    final created = createOps.last;
    final deletedAfter = entry.value.any((o) => o.operation == SyncOperations.delete);
    if (deletedAfter) continue;
    out.add(EffectiveEntity(
      payload: Map<String, dynamic>.from(created.changes),
      revision: 0,
      hasPendingOp: true,
      isLocalCreate: true,
    ));
    seen.add(id);
  }

  for (final row in snapshot.rowsOf(entityType)) {
    if (seen.contains(row.entityId)) continue;
    final ops = pendingByEntity['$entityType:${row.entityId}'] ?? const <PendingOperation>[];
    var payload = Map<String, dynamic>.from(row.payload);
    // A canonical tombstone stays hidden unless a queued local update
    // revives the entity optimistically (it will surface as a conflict if
    // the server really deleted it).
    var locallyDeleted = row.deletedAt != null;
    var hasPending = false;
    for (final op in ops) {
      hasPending = true;
      switch (op.operation) {
        case SyncOperations.update:
          payload = overlayChanges(payload, op.changes);
          if (locallyDeleted) locallyDeleted = false;
          break;
        case SyncOperations.delete:
          locallyDeleted = true;
          break;
        case SyncOperations.create:
          break; // server ack arrives via pull; nothing to overlay
      }
    }
    out.add(EffectiveEntity(
      payload: payload,
      revision: row.revision,
      locallyDeleted: locallyDeleted,
      hasPendingOp: hasPending,
    ));
  }

  // Entities that are (or were locally marked) deleted do not surface.
  return out.where((e) => !e.locallyDeleted).toList();
}

EntityRow? rowsOf(EntitiesSnapshot snapshot, String entityType, String id) {
  for (final r in snapshot.rowsOf(entityType)) {
    if (r.entityId == id) return r;
  }
  return null;
}
