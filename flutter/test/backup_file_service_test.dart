import 'dart:convert';
import 'dart:io';

import 'package:course_planner/core/config/app_config.dart';
import 'package:course_planner/data/backup/backup_file_service.dart';
import 'package:course_planner/data/backup/backup_service.dart';
import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

class _FakeFileService extends BackupFileService {
  _FakeFileService(this.target);

  final BackupSaveTarget? target;
  String? seenName;
  String? seenJson;

  @override
  Future<BackupSaveTarget?> saveJson({
    required String suggestedName,
    required String json,
  }) async {
    seenName = suggestedName;
    seenJson = json;
    return target;
  }
}

/// Backup export goes through the system save dialog (SAF on Android,
/// SaveFileDialog on Windows) and never reports an app-private path.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel(BackupFileService.channelName),
    (call) async {
      switch (call.method) {
        case 'saveBackup':
          return {'uri': 'content://downloads/42', 'name': 'backup.json'};
        case 'pickBackup':
          return {'path': r'C:\tmp\picked.json', 'name': 'picked.json'};
        default:
          return null;
      }
    },
  );
  configureHostSqlite();

  late Directory tempDir;
  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('backup_svc_');
  });
  tearDownAll(() async {
    await tempDir.delete(recursive: true);
  });

  group('BackupFileService', () {
    test('android save returns the document display name', () async {
      final service = BackupFileService(
        platform: TargetPlatform.android,
        tempDirectory: tempDir,
      );
      final target = await service.saveJson(
        suggestedName: 'course_planner_backup.json',
        json: '{"format":"course_planner_backup"}',
      );
      expect(target, isNotNull);
      expect(target!.label, 'backup.json');
    });

    test('android pick returns the cached path and name', () async {
      final service = BackupFileService(
        platform: TargetPlatform.android,
        tempDirectory: tempDir,
      );
      final picked = await service.pickJson();
      expect(picked, isNotNull);
      expect(picked!.displayName, 'picked.json');
      expect(picked.path, r'C:\tmp\picked.json');
    });

    test('unsupported platforms return null', () async {
      const service = BackupFileService(platform: TargetPlatform.linux);
      expect(
        await service.saveJson(suggestedName: 'x.json', json: '{}'),
        isNull,
      );
      expect(await service.pickJson(), isNull);
    });
  });

  group('BackupService.exportViaPicker', () {
    late AppDatabase db;
    late SyncStore store;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = SyncStore(db);
    });

    tearDown(() async => db.close());

    BackupService service() => BackupService(
          store: store,
          readKnownServers: () async => const [],
          activeServer: () async => AppConfig.apiBaseUrl,
          readToken: (key) async => null,
        );

    test('asks the picker and returns where the user saved it', () async {
      await store.upsertEntityRow(EntityRow(
        entityType: EntityTypes.todo,
        entityId: 't1',
        revision: 1,
        payload: const {'id': 't1', 'title': '写作业', 'revision': 1},
      ));
      final files = _FakeFileService(
        const BackupSaveTarget(label: r'C:\Users\me\Downloads\backup.json'),
      );

      final result = await service().exportViaPicker(files: files);

      expect(result, isNotNull);
      expect(result!.path, contains('backup.json'));
      expect(result.entityCount, 1);
      expect(files.seenName, endsWith('.json'));
      final decoded = jsonDecode(files.seenJson!) as Map<String, dynamic>;
      expect(decoded['format'], 'course_planner_backup');
      expect((decoded['entities'] as List).single['entityId'], 't1');
    });

    test('returns null when the dialog is cancelled', () async {
      final files = _FakeFileService(null);
      expect(await service().exportViaPicker(files: files), isNull);
    });
  });

  test('readBackup accepts a file copied out by the SAF picker', () async {
    final dir = await Directory.systemTemp.createTemp('backup_pick_');
    addTearDown(() async => dir.delete(recursive: true));
    final file = File('${dir.path}/picked.json');
    await file.writeAsString(jsonEncode({
      'format': 'course_planner_backup',
      'formatVersion': 1,
      'entities': <Object>[],
      'pendingOps': <Object>[],
      'conflicts': <Object>[],
    }));

    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final svc = BackupService(
      store: SyncStore(db),
      readKnownServers: () async => const [],
      activeServer: () async => AppConfig.apiBaseUrl,
      readToken: (key) async => null,
    );
    final doc = await svc.readBackup(file.path);
    expect(doc['format'], 'course_planner_backup');
  });
}
