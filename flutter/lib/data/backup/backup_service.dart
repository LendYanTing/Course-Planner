import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/config/app_config.dart';
import '../../domain/entities.dart';
import '../../domain/sync.dart';
import '../auth/server_store.dart';
import '../local/sync_store.dart';

/// Result of a full local export.
class BackupResult {
  const BackupResult({
    required this.path,
    required this.entityCount,
    required this.pendingCount,
    required this.conflictCount,
    required this.serverCount,
    required this.bytes,
  });

  final String path;
  final int entityCount;
  final int pendingCount;
  final int conflictCount;
  final int serverCount;
  final int bytes;
}

/// Which parts of a backup document to restore. Every category the user cares
/// about (server address, credentials, semesters/courses, todos, taxonomy) is
/// a separate switch in the UI.
class BackupSelection {
  const BackupSelection({
    this.servers = false,
    this.credentials = false,
    this.academic = false,
    this.todos = false,
    this.taxonomy = false,
    this.queue = false,
  });

  /// Active server + the known-server list.
  final bool servers;

  /// Refresh tokens (signs the install in on the imported servers).
  final bool credentials;

  /// Semesters, period templates, courses, meetings, schedules, overrides.
  final bool academic;

  /// Todos and their time blocks.
  final bool todos;

  /// Tags and todo categories.
  final bool taxonomy;

  /// Unpushed operations and unresolved conflicts.
  final bool queue;

  BackupSelection copyWith({
    bool? servers,
    bool? credentials,
    bool? academic,
    bool? todos,
    bool? taxonomy,
    bool? queue,
  }) =>
      BackupSelection(
        servers: servers ?? this.servers,
        credentials: credentials ?? this.credentials,
        academic: academic ?? this.academic,
        todos: todos ?? this.todos,
        taxonomy: taxonomy ?? this.taxonomy,
        queue: queue ?? this.queue,
      );

  bool get isEmpty =>
      !servers && !credentials && !academic && !todos && !taxonomy && !queue;

  static const all = BackupSelection(
    servers: true,
    credentials: true,
    academic: true,
    todos: true,
    taxonomy: true,
    queue: true,
  );
}

/// Entity types belonging to each selectable data category.
const _academicTypes = <String>{
  EntityTypes.calendar,
  EntityTypes.period,
  EntityTypes.course,
  EntityTypes.courseMeeting,
  EntityTypes.recurringSchedule,
  EntityTypes.override,
};
const _todoTypes = <String>{EntityTypes.todo, EntityTypes.todoBlock};
const _taxonomyTypes = <String>{EntityTypes.tag, EntityTypes.category};

/// What an import would/did change.
class BackupImportPreview {
  const BackupImportPreview({
    required this.entitiesByType,
    required this.pendingOps,
    required this.conflicts,
    required this.servers,
    required this.tokens,
    required this.activeServer,
    required this.exportedAt,
  });

  final Map<String, int> entitiesByType;
  final int pendingOps;
  final int conflicts;
  final int servers;
  final int tokens;
  final String? activeServer;
  final String? exportedAt;

  int get totalEntities =>
      entitiesByType.values.fold(0, (a, b) => a + b);
}

/// Summary of an applied import.
class BackupImportResult {
  const BackupImportResult({
    required this.entities,
    required this.queuedUploads,
    required this.serversApplied,
    required this.credentialsApplied,
  });

  final int entities;
  final int queuedUploads;
  final int serversApplied;
  final int credentialsApplied;
}

/// Full local backup: dumps the entire offline working copy (mirror, operation
/// queue, conflicts, meta, known servers) **plus the stored refresh tokens**,
/// so an install can be restored verbatim — including staying signed in.
///
/// The file is written as UTF-8 JSON into the application documents
/// directory; the caller surfaces the path (the app has no file-picker
/// dependency, so we don't prompt for a location).
class BackupService {
  BackupService({
    required this.store,
    required this.readKnownServers,
    required this.activeServer,
    required this.readToken,
  });

  static const formatVersion = 1;

  final SyncStore store;

  /// Injected so the exporter stays free of platform channels (and testable).
  final Future<List<KnownServer>> Function() readKnownServers;
  final Future<String> Function() activeServer;
  final Future<String?> Function(String? serverKey) readToken;

  /// Builds the backup document (no I/O beyond reading the DB/prefs).
  Future<Map<String, dynamic>> build() async {
    final entities = await store.allEntities();
    final ops = await store.pendingOps();
    final conflicts = await store.conflicts();
    final meta = await store.meta();
    final servers = await readKnownServers();
    final active = await activeServer();

    // Refresh tokens for every server this install knows about (scoped keys).
    final tokens = <String, String>{};
    for (final s in servers) {
      final token = await readToken(AppConfig.tokenServerKey(s.baseUrl));
      if (token != null && token.isNotEmpty) tokens[s.baseUrl] = token;
    }
    // The active server may not be in the known list yet (first run).
    if (!tokens.containsKey(active)) {
      final token = await readToken(AppConfig.tokenServerKey(active));
      if (token != null && token.isNotEmpty) tokens[active] = token;
    }

    return {
      'format': 'course_planner_backup',
      'formatVersion': formatVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'activeServer': active,
      'servers': servers.map((s) => s.toJson()).toList(),
      // Tokens are secrets; the file is written next to the app data.
      'tokens': tokens,
      'meta': meta == null
          ? null
          : {
              'userId': meta.userId,
              'username': meta.username,
              'email': meta.email,
              'timezone': meta.timezone,
              'lastServerCursor': meta.lastServerCursor,
              'clockFetchedAt': meta.clockFetchedAt?.toIso8601String(),
              'clockServerUtc': meta.clockServerUtc?.toIso8601String(),
            },
      'entities': [
        for (final e in entities)
          {
            'entityType': e.entityType,
            'entityId': e.entityId,
            'revision': e.revision,
            'updatedAt': e.updatedAt?.toIso8601String(),
            'deletedAt': e.deletedAt?.toIso8601String(),
            'payload': e.payload,
          },
      ],
      'pendingOps': [
        for (final o in ops)
          {
            'operationId': o.operationId,
            'entityType': o.entityType,
            'entityId': o.entityId,
            'operation': o.operation,
            'baseRevision': o.baseRevision,
            'changes': o.changes,
            'createdAt': o.createdAt?.toIso8601String(),
            'attempts': o.attempts,
            'lastError': o.lastError,
          },
      ],
      'conflicts': [
        for (final c in conflicts)
          {
            'operationId': c.operationId,
            'entityType': c.entityType,
            'entityId': c.entityId,
            'base': c.base,
            'local': c.local,
            'server': c.server,
            'conflictingFields': c.conflictingFields,
            'createdAt': c.createdAt.toIso8601String(),
          },
      ],
    };
  }

  /// Writes the backup and returns where it landed.
  Future<BackupResult> export() async {
    final doc = await build();
    final json = const JsonEncoder.withIndent('  ').convert(doc);
    final dir = await getApplicationDocumentsDirectory();
    final stamp = DateTime.now()
        .toUtc()
        .toIso8601String()
        .replaceAll(RegExp(r'[:.]'), '-');
    final file = File('${dir.path}${Platform.pathSeparator}course_planner_backup_$stamp.json');
    await file.writeAsString(json, flush: true);

    return BackupResult(
      path: file.path,
      entityCount: (doc['entities'] as List).length,
      pendingCount: (doc['pendingOps'] as List).length,
      conflictCount: (doc['conflicts'] as List).length,
      serverCount: (doc['tokens'] as Map).length,
      bytes: utf8.encode(json).length,
    );
  }

  // ---- import --------------------------------------------------------------

  /// Backup files previously written by [export] (newest first), plus any
  /// other `*.json` in the app documents directory. The app has no file-picker
  /// dependency, so the UI lists these and also accepts a pasted path.
  Future<List<FileSystemEntity>> listBackups() async {
    final dir = await getApplicationDocumentsDirectory();
    if (!await dir.exists()) return const [];
    final files = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.json'))
        .toList()
      ..sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }

  /// Reads and validates a backup document from [path].
  Future<Map<String, dynamic>> readBackup(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const FormatException('文件不存在');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) throw const FormatException('不是有效的备份文件');
    final doc = decoded.cast<String, dynamic>();
    if (doc['format'] != 'course_planner_backup') {
      throw const FormatException('不是 Course Planner 备份文件');
    }
    return doc;
  }

  /// Summarises a document so the user can see what they are about to import.
  BackupImportPreview preview(Map<String, dynamic> doc, BackupSelection sel) {
    final counts = <String, int>{};
    for (final raw in (doc['entities'] as List? ?? const [])) {
      if (raw is! Map) continue;
      final type = raw['entityType'];
      if (type is! String) continue;
      if (!_selectedEntityTypes(sel).contains(type)) continue;
      counts[type] = (counts[type] ?? 0) + 1;
    }
    return BackupImportPreview(
      entitiesByType: counts,
      pendingOps:
          sel.queue ? (doc['pendingOps'] as List? ?? const []).length : 0,
      conflicts: sel.queue ? (doc['conflicts'] as List? ?? const []).length : 0,
      servers: sel.servers ? (doc['servers'] as List? ?? const []).length : 0,
      tokens: sel.credentials ? (doc['tokens'] as Map? ?? const {}).length : 0,
      activeServer: doc['activeServer'] as String?,
      exportedAt: doc['exportedAt'] as String?,
    );
  }

  Set<String> _selectedEntityTypes(BackupSelection sel) => {
        if (sel.academic) ..._academicTypes,
        if (sel.todos) ..._todoTypes,
        if (sel.taxonomy) ..._taxonomyTypes,
      };

  /// Applies the selected categories **local-first**: imported entities are
  /// mirrored locally AND queued as pending creates, so the next sync pushes
  /// them to the target server (the same semantics as 本地覆盖云端) and a
  /// pull cannot silently overwrite them.
  ///
  /// The journal cursor is reset because cursors belong to the server that
  /// produced them, and [AppMetaSnapshot.lastServerCursor] from another
  /// install is meaningless.
  Future<BackupImportResult> importDocument(
    Map<String, dynamic> doc,
    BackupSelection sel, {
    required Future<void> Function(String serverBaseUrl) useServer,
    required Future<void> Function(String serverBaseUrl, String token) applyToken,
    required Future<void> Function(List<KnownServer> servers) rememberServers,
    required Future<int> Function() enqueueUploads,
  }) async {
    var serverCount = 0;
    var credentialCount = 0;

    if (sel.servers) {
      final active = doc['activeServer'];
      final known = <KnownServer>[
        for (final raw in (doc['servers'] as List? ?? const []))
          if (raw is Map && KnownServer.fromJson(raw.cast<String, dynamic>()) != null)
            KnownServer.fromJson(raw.cast<String, dynamic>())!,
      ];
      await rememberServers(known);
      serverCount = known.length;
      if (active is String && active.isNotEmpty) {
        await useServer(active);
      }
    }

    if (sel.credentials) {
      final tokens = doc['tokens'];
      if (tokens is Map) {
        for (final entry in tokens.entries) {
          final url = entry.key;
          final token = entry.value;
          if (url is! String || token is! String || token.isEmpty) continue;
          await applyToken(url, token);
          credentialCount++;
        }
      }
    }

    final wanted = _selectedEntityTypes(sel);
    var entityCount = 0;
    if (wanted.isNotEmpty) {
      for (final raw in (doc['entities'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final type = m['entityType'];
        final id = m['entityId'];
        if (type is! String || id is! String || !wanted.contains(type)) continue;
        final payload = m['payload'];
        await store.upsertEntityRow(EntityRow(
          entityType: type,
          entityId: id,
          revision: m['revision'] is num ? (m['revision'] as num).toInt() : 0,
          payload: payload is Map
              ? Map<String, dynamic>.from(payload)
              : <String, dynamic>{},
          updatedAt: _parseTs(m['updatedAt']) ?? DateTime.now().toUtc(),
          deletedAt: _parseTs(m['deletedAt']),
        ));
        entityCount++;
      }
      await store.resetCursor();
    }

    if (sel.queue) {
      for (final raw in (doc['pendingOps'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final opId = m['operationId'];
        final type = m['entityType'];
        final id = m['entityId'];
        if (opId is! String || type is! String || id is! String) continue;
        await store.enqueueOp(PendingOperation(
          operationId: opId,
          entityType: type,
          entityId: id,
          operation: m['operation'] is String ? m['operation'] as String : SyncOperations.update,
          baseRevision:
              m['baseRevision'] is num ? (m['baseRevision'] as num).toInt() : 0,
          changes: m['changes'] is Map
              ? Map<String, dynamic>.from(m['changes'] as Map)
              : <String, dynamic>{},
          createdAt: _parseTs(m['createdAt']) ?? DateTime.now().toUtc(),
          attempts: m['attempts'] is num ? (m['attempts'] as num).toInt() : 0,
          lastError: m['lastError'] as String?,
        ));
      }
      for (final raw in (doc['conflicts'] as List? ?? const [])) {
        if (raw is! Map) continue;
        final m = raw.cast<String, dynamic>();
        final opId = m['operationId'];
        if (opId is! String) continue;
        await store.saveConflict(ConflictRecord(
          operationId: opId,
          entityType: m['entityType'] as String? ?? '',
          entityId: m['entityId'] as String? ?? '',
          base: m['base'] is Map ? Map<String, dynamic>.from(m['base'] as Map) : const {},
          local: m['local'] is Map ? Map<String, dynamic>.from(m['local'] as Map) : const {},
          server: m['server'] is Map ? Map<String, dynamic>.from(m['server'] as Map) : const {},
          conflictingFields: (m['conflictingFields'] as List? ?? const [])
              .whereType<String>()
              .toList(),
          createdAt: _parseTs(m['createdAt']) ?? DateTime.now().toUtc(),
        ));
      }
    }

    // Imported data wins locally: queue it so the next sync uploads it.
    var queued = 0;
    if (entityCount > 0) {
      queued = await enqueueUploads();
    }

    return BackupImportResult(
      entities: entityCount,
      queuedUploads: queued,
      serversApplied: serverCount,
      credentialsApplied: credentialCount,
    );
  }

  DateTime? _parseTs(Object? v) {
    if (v is! String) return null;
    return DateTime.tryParse(v)?.toUtc();
  }
}
