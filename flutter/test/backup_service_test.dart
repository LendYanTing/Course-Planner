import 'dart:convert';

import 'package:course_planner/core/config/app_config.dart';
import 'package:course_planner/data/auth/server_store.dart';
import 'package:course_planner/data/backup/backup_service.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/sync.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

/// The full local backup must capture the whole working copy **plus** the
/// per-server credentials, so an install can be restored verbatim.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  late AppDatabase db;
  late SyncStore store;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    store = SyncStore(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('backup document contains data, queue, conflicts, meta and tokens',
      () async {
    await store.saveMeta(const AppMetaSnapshot(
      userId: 'u1',
      username: 'webdev',
      timezone: 'Asia/Shanghai',
      lastServerCursor: 7,
    ));
    await store.upsertEntityRow(EntityRow(
      entityType: EntityTypes.todo,
      entityId: 't1',
      revision: 3,
      payload: {'id': 't1', 'title': '生化大作业', 'revision': 3},
    ));
    await store.enqueueOp(PendingOperation(
      operationId: 'op1',
      entityType: EntityTypes.todo,
      entityId: 't1',
      operation: SyncOperations.update,
      baseRevision: 3,
      changes: {'title': '改名'},
      createdAt: DateTime.now().toUtc(),
    ));
    await store.saveConflict(ConflictRecord(
      operationId: 'op2',
      entityType: EntityTypes.todo,
      entityId: 't1',
      base: const {'title': 'a'},
      local: const {'title': 'b'},
      server: const {'title': 'c'},
      conflictingFields: const ['title'],
      createdAt: DateTime.now().toUtc(),
    ));

    const serverA = 'https://a.example.com/api/v1';
    const serverB = 'https://b.example.com/api/v1';
    // The service reads tokens by *scoped* key; return one for every
    // non-default server and none for the legacy (null) scope.
    final requestedKeys = <String?>[];

    final backup = BackupService(
      store: store,
      readKnownServers: () async => const [
        KnownServer(baseUrl: serverA, username: 'webdev'),
        KnownServer(baseUrl: serverB, username: 'other'),
      ],
      activeServer: () async => serverA,
      readToken: (key) async {
        requestedKeys.add(key);
        return key == null ? null : 'refresh-token-for-$key';
      },
    );

    final doc = await backup.build();

    expect(doc['format'], 'course_planner_backup');
    expect(doc['formatVersion'], 1);
    expect(doc['activeServer'], serverA);
    expect((doc['servers'] as List), hasLength(2));
    expect((doc['entities'] as List).single['entityId'], 't1');
    expect((doc['pendingOps'] as List).single['operationId'], 'op1');
    expect((doc['conflicts'] as List).single['operationId'], 'op2');
    expect((doc['meta'] as Map)['timezone'], 'Asia/Shanghai');
    expect((doc['meta'] as Map)['lastServerCursor'], 7);
    // Tokens are keyed by server url (both known servers), so the backup can
    // restore a signed-in install on either one.
    expect((doc['tokens'] as Map).keys, containsAll([serverA, serverB]));
    expect(requestedKeys, isNotEmpty);

    // The document must be JSON-encodable as-is (no DateTime leakage).
    expect(() => jsonEncode(doc), returnsNormally);
  });

  test('import applies only the selected categories, local-first', () async {
    const serverB = 'https://b.example.com/api/v1';
    final doc = <String, dynamic>{
      'format': 'course_planner_backup',
      'formatVersion': 1,
      'exportedAt': '2026-09-10T00:00:00Z',
      'activeServer': serverB,
      'servers': [
        {'baseUrl': serverB, 'username': 'webdev'},
      ],
      'tokens': {serverB: 'refresh-B'},
      'entities': [
        {'entityType': 'course', 'entityId': 'c1', 'revision': 1, 'payload': {'id': 'c1', 'name': '高数'}},
        {'entityType': 'todo', 'entityId': 't1', 'revision': 2, 'payload': {'id': 't1', 'title': '作业'}},
        {'entityType': 'todo_block', 'entityId': 'b1', 'revision': 1, 'payload': {'id': 'b1', 'todoId': 't1'}},
        {'entityType': 'tag', 'entityId': 'g1', 'revision': 1, 'payload': {'id': 'g1', 'name': '重要'}},
      ],
      'pendingOps': [],
      'conflicts': [],
    };

    var useServerCalled = '';
    final appliedTokens = <String, String>{};
    final remembered = <KnownServer>[];
    var enqueueCalls = 0;

    final svc = BackupService(
      store: store,
      readKnownServers: () async => const [],
      activeServer: () async => AppConfig.apiBaseUrl,
      readToken: (key) async => null,
    );

    // Preview must reflect the selection, not the whole document.
    final onlyTodos = const BackupSelection(todos: true);
    final preview = svc.preview(doc, onlyTodos);
    expect(preview.entitiesByType.keys, containsAll(['todo', 'todo_block']));
    expect(preview.entitiesByType.containsKey('course'), isFalse);
    expect(preview.servers, 0);
    expect(preview.tokens, 0);

    final result = await svc.importDocument(
      doc,
      onlyTodos,
      useServer: (url) async => useServerCalled = url,
      applyToken: (url, token) async => appliedTokens[url] = token,
      rememberServers: (servers) async => remembered.addAll(servers),
      enqueueUploads: () async {
        enqueueCalls++;
        return 2;
      },
    );

    // Only the todo category landed.
    expect(result.entities, 2);
    expect((await store.entitiesOfType('todo')).single.entityId, 't1');
    expect((await store.entitiesOfType('todo_block')).single.entityId, 'b1');
    expect(await store.entitiesOfType('course'), isEmpty);
    expect(await store.entitiesOfType('tag'), isEmpty);
    // Server / credential categories were NOT selected.
    expect(useServerCalled, isEmpty);
    expect(appliedTokens, isEmpty);
    expect(remembered, isEmpty);
    // Local-first: the imported rows are queued for upload and the cursor was
    // reset (a foreign cursor is meaningless on this server).
    expect(enqueueCalls, 1);
    expect(result.queuedUploads, 2);
    expect((await store.meta())?.lastServerCursor, 0);
  });

  test('import of server + credentials applies them to the right scopes',
      () async {
    const serverB = 'https://b.example.com/api/v1';
    final doc = <String, dynamic>{
      'format': 'course_planner_backup',
      'activeServer': serverB,
      'servers': [
        {'baseUrl': serverB, 'username': 'webdev'},
      ],
      'tokens': {serverB: 'refresh-B'},
      'entities': const [],
      'pendingOps': const [],
      'conflicts': const [],
    };

    var useServerCalled = '';
    final appliedTokens = <String, String>{};
    final remembered = <KnownServer>[];

    final svc = BackupService(
      store: store,
      readKnownServers: () async => const [],
      activeServer: () async => AppConfig.apiBaseUrl,
      readToken: (key) async => null,
    );

    final result = await svc.importDocument(
      doc,
      const BackupSelection(servers: true, credentials: true),
      useServer: (url) async => useServerCalled = url,
      applyToken: (url, token) async => appliedTokens[url] = token,
      rememberServers: (servers) async => remembered.addAll(servers),
      enqueueUploads: () async => 0,
    );

    expect(useServerCalled, serverB);
    expect(appliedTokens[serverB], 'refresh-B');
    expect(remembered.single.baseUrl, serverB);
    expect(remembered.single.username, 'webdev');
    expect(result.serversApplied, 1);
    expect(result.credentialsApplied, 1);
    // No entity category selected → nothing queued.
    expect(result.queuedUploads, 0);
  });
}
