import '../../domain/sync.dart';
import 'api_response.dart';
import 'http_client.dart';

/// Sync endpoints (docs/api.md §15, docs/sync-protocol.md).
class SyncApi {
  SyncApi(this._http);

  final ApiHttp _http;

  /// GET /sync/state → current server cursor.
  Future<int> serverCursor() async {
    final res = await _http.get('/sync/state');
    final data = unwrapDataObject(res);
    return (data['serverCursor'] as num?)?.toInt() ?? 0;
  }

  /// GET /sync/changes?after=...&limit=...
  Future<SyncChangesPage> changes({required int after, int limit = 500}) async {
    final res = await _http.get('/sync/changes', query: {
      'after': after,
      'limit': limit,
    });
    final data = unwrapDataObject(res);
    return SyncChangesPage(
      changes: data['changes'] is List
          ? (data['changes'] as List)
              .whereType<Map>()
              .map((e) => SyncChange.fromJson(Map<String, dynamic>.from(e)))
              .toList()
          : const [],
      nextCursor: (data['nextCursor'] as num?)?.toInt() ?? after,
      hasMore: data['hasMore'] == true,
    );
  }

  /// POST /sync/push.
  Future<SyncPushResult> push({
    required int baseCursor,
    required List<PendingOperation> operations,
  }) async {
    final res = await _http.post('/sync/push', body: {
      'baseCursor': baseCursor,
      'operations': operations
          .map((o) => {
                'operationId': o.operationId,
                'entityType': o.entityType,
                'entityId': o.entityId,
                'operation': o.operation,
                'baseRevision': o.baseRevision,
                'changes': o.changes,
              })
          .toList(),
    });
    return SyncPushResult.fromJson(
        Map<String, dynamic>.from(res.data as Map));
  }
}

class SyncChangesPage {
  const SyncChangesPage({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<SyncChange> changes;
  final int nextCursor;
  final bool hasMore;
}
