// ignore_for_file: prefer_initializing_formals
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Where a backup was saved. Android returns the SAF display name (the user's
/// chosen document), Windows returns the real file path.
class BackupSaveTarget {
  const BackupSaveTarget({required this.label, this.path});

  /// Human-readable location shown in the success dialog.
  final String label;

  /// Real filesystem path when the platform exposes one (Windows).
  final String? path;
}

/// A backup file chosen by the user through the system open dialog.
class PickedBackupFile {
  const PickedBackupFile({required this.path, required this.displayName});

  /// Path the app can read. On Android this is a private cache copy of the
  /// document the user picked.
  final String path;

  /// Name shown to the user.
  final String displayName;
}

/// System save/open dialogs for backup files.
///
/// * Android: Storage Access Framework (`ACTION_CREATE_DOCUMENT` /
///   `ACTION_OPEN_DOCUMENT`) through the `course_planner/backup` channel, so the
///   user picks a real public location (Downloads, Drive, …) instead of an app
///   private directory.
/// * Windows: `System.Windows.Forms.SaveFileDialog` / `OpenFileDialog`
///   through PowerShell.
/// * Any other platform (or a cancelled dialog): null.
///
/// Failures never throw; the caller shows a single "cancelled / unavailable"
/// message.
class BackupFileService {
  const BackupFileService({
    MethodChannel? channel,
    TargetPlatform? platform,
    Directory? tempDirectory,
  })  : _channel = channel,
        _platform = platform,
        _tempDirectory = tempDirectory;

  /// Channel implemented in `MainActivity.kt`.
  static const channelName = 'course_planner/backup';

  static const _dialogTimeout = Duration(minutes: 10);

  /// Test seam: null means the real platform channel.
  final MethodChannel? _channel;

  /// Test seam: null means `defaultTargetPlatform`.
  final TargetPlatform? _platform;

  /// Test seam: null means `getTemporaryDirectory()`.
  final Directory? _tempDirectory;

  TargetPlatform get _target => _platform ?? defaultTargetPlatform;

  /// Opens the system save dialog and writes [json] to the chosen document.
  Future<BackupSaveTarget?> saveJson({
    required String suggestedName,
    required String json,
  }) async {
    if (kIsWeb) return null;
    switch (_target) {
      case TargetPlatform.android:
        return _saveOnAndroid(suggestedName, json);
      case TargetPlatform.windows:
        return _saveOnWindows(suggestedName, json);
      default:
        return null;
    }
  }

  /// Opens the system file picker and returns a readable copy of the chosen
  /// backup document.
  Future<PickedBackupFile?> pickJson() async {
    if (kIsWeb) return null;
    switch (_target) {
      case TargetPlatform.android:
        return _pickOnAndroid();
      case TargetPlatform.windows:
        return _pickOnWindows();
      default:
        return null;
    }
  }

  // ---- Android -----------------------------------------------------------

  Future<BackupSaveTarget?> _saveOnAndroid(
    String suggestedName,
    String json,
  ) async {
    Directory? tempDir;
    try {
      final channel = _channel ?? const MethodChannel(channelName);
      tempDir = _tempDirectory ?? await getTemporaryDirectory();
      final temp = File(p.join(
        tempDir.path,
        'backup_export_${DateTime.now().microsecondsSinceEpoch}.json',
      ));
      await temp.writeAsString(json, flush: true);
      final raw = await channel.invokeMethod<Object?>('saveBackup', {
        'name': suggestedName,
        'path': temp.path,
      });
      final map = _asMap(raw);
      if (map == null) return null;
      final name = _stringOf(map['name']);
      final uri = _stringOf(map['uri']);
      return BackupSaveTarget(
        label: name.isNotEmpty ? name : (uri.isNotEmpty ? uri : suggestedName),
      );
    } on MissingPluginException {
      debugPrint('BackupFileService: backup channel is unavailable');
      return null;
    } on PlatformException catch (e) {
      debugPrint('BackupFileService: saveBackup failed (${e.code})');
      return null;
    } on Object {
      debugPrint('BackupFileService: saveBackup failed');
      return null;
    } finally {
      if (tempDir != null) {
        try {
          tempDir.listSync().whereType<File>().forEach((f) {
            if (p.basename(f.path).startsWith('backup_export_')) {
              f.deleteSync();
            }
          });
        } on Object {
          // Best effort.
        }
      }
    }
  }

  Future<PickedBackupFile?> _pickOnAndroid() async {
    try {
      final channel = _channel ?? const MethodChannel(channelName);
      final raw = await channel.invokeMethod<Object?>('pickBackup');
      final map = _asMap(raw);
      if (map == null) return null;
      final path = _stringOf(map['path']);
      if (path.isEmpty) return null;
      final name = _stringOf(map['name']);
      return PickedBackupFile(
        path: path,
        displayName: name.isNotEmpty ? name : p.basename(path),
      );
    } on MissingPluginException {
      debugPrint('BackupFileService: backup channel is unavailable');
      return null;
    } on PlatformException catch (e) {
      debugPrint('BackupFileService: pickBackup failed (${e.code})');
      return null;
    } on Object {
      debugPrint('BackupFileService: pickBackup failed');
      return null;
    }
  }

  // ---- Windows -----------------------------------------------------------

  Future<BackupSaveTarget?> _saveOnWindows(
    String suggestedName,
    String json,
  ) async {
    try {
      final script = '''
Add-Type -AssemblyName System.Windows.Forms;
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8;
\$dialog = New-Object System.Windows.Forms.SaveFileDialog;
\$dialog.Title = '保存 Course Planner 备份';
\$dialog.Filter = 'Course Planner 备份 (*.json)|*.json|所有文件 (*.*)|*.*';
\$dialog.FileName = '${_psEscape(suggestedName)}';
\$dialog.OverwritePrompt = \$true;
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$dialog.FileName }
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-STA', '-Command', script],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(_dialogTimeout);
      if (result.exitCode != 0) return null;
      final chosen = result.stdout.toString().trim();
      if (chosen.isEmpty) return null;
      await File(chosen).writeAsString(json, flush: true);
      return BackupSaveTarget(label: chosen, path: chosen);
    } on Object {
      debugPrint('BackupFileService: save dialog failed');
      return null;
    }
  }

  Future<PickedBackupFile?> _pickOnWindows() async {
    try {
      const script = '''
Add-Type -AssemblyName System.Windows.Forms;
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8;
\$dialog = New-Object System.Windows.Forms.OpenFileDialog;
\$dialog.Title = '选择 Course Planner 备份';
\$dialog.Filter = 'Course Planner 备份 (*.json)|*.json|所有文件 (*.*)|*.*';
\$dialog.CheckFileExists = \$true;
\$dialog.Multiselect = \$false;
if (\$dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output \$dialog.FileName }
''';
      final result = await Process.run(
        'powershell',
        ['-NoProfile', '-STA', '-Command', script],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(_dialogTimeout);
      if (result.exitCode != 0) return null;
      final chosen = result.stdout.toString().trim();
      if (chosen.isEmpty) return null;
      return PickedBackupFile(
        path: chosen,
        displayName: p.basename(chosen),
      );
    } on Object {
      debugPrint('BackupFileService: open dialog failed');
      return null;
    }
  }

  // ---- helpers -----------------------------------------------------------

  static Map<dynamic, dynamic>? _asMap(Object? value) {
    if (value is Map) return value;
    if (value is String && value.isNotEmpty) {
      try {
        final decoded = jsonDecode(value);
        if (decoded is Map) return decoded;
      } on FormatException {
        return null;
      }
    }
    return null;
  }

  static String _stringOf(Object? value) =>
      value is String ? value.trim() : '';

  static String _psEscape(String value) => value.replaceAll("'", "''");
}

final backupFileServiceProvider = Provider<BackupFileService>(
  (ref) => const BackupFileService(),
);
