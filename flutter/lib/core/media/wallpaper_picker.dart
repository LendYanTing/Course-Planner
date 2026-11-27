import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Picks a wallpaper image with the platform's own UI and copies it into the
/// app's private storage, so the path stays readable across restarts.
///
/// * Android: `course_planner/media` MethodChannel → `ACTION_GET_CONTENT`;
///   the Kotlin side already copies the stream into `filesDir/backgrounds/`
///   and returns that absolute path.
/// * Windows: a PowerShell-hosted `System.Windows.Forms.OpenFileDialog`; the
///   chosen file is copied into `getApplicationSupportDirectory()/backgrounds/`.
/// * Any other platform: unsupported, [pickWallpaper] returns null.
///
/// Every failure path returns null instead of throwing: the settings page only
/// has to show one "nothing was picked" message.
class WallpaperPickerService {
  const WallpaperPickerService({
    Directory? directory,
    MethodChannel? mediaChannel,
  }) : _targetDirectory = directory,
       _channel = mediaChannel;

  /// Channel implemented in `MainActivity.kt`.
  static const channelName = 'course_planner/media';

  /// Name prefix of every file this service owns inside `backgrounds/`.
  static const _filePrefix = 'wallpaper_';

  static const _dialogTimeout = Duration(minutes: 10);

  /// Test seam: null means "ask path_provider for the app support directory".
  /// When set, imports land in this directory instead.
  final Directory? _targetDirectory;

  /// Test seam: null means the real platform channel.
  final MethodChannel? _channel;

  /// Opens the system photo/file picker and returns the private copy's absolute
  /// path, or null when the user cancelled or the platform is unsupported.
  Future<String?> pickWallpaper() async {
    // Web has neither path_provider directories nor the native bridges; check
    // before `defaultTargetPlatform`, which is browser-derived there.
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return _pickOnAndroid();
      case TargetPlatform.windows:
        return _pickOnWindows();
      default:
        return null;
    }
  }

  /// Copies [rawPath] (a typed or pasted local path) into the private
  /// `backgrounds/` directory and returns the copy's absolute path.
  ///
  /// Surrounding whitespace and one pair of matching `"`/`'` quotes are
  /// stripped, which is what a "Copy as path" shell action produces on
  /// Windows. Missing or unreadable files return null; the user's original
  /// file is never moved or deleted.
  Future<String?> importFromFilePath(String rawPath) async {
    try {
      final sourcePath = _normalizePath(rawPath);
      if (sourcePath == null) return null;

      final source = File(sourcePath);
      if (!source.existsSync()) {
        debugPrint('WallpaperPicker: source file does not exist');
        return null;
      }

      final directory = await _backgroundsDirectory();
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
      }

      final extension = p.extension(source.path);
      final suffix = extension.isEmpty ? '.jpg' : extension.toLowerCase();
      final target = _uniqueTarget(directory, suffix);
      await source.copy(target.path);

      // One wallpaper is enough: drop the previous private copies so repeated
      // picks do not grow the folder forever. Never touch the source file.
      _pruneOldCopies(
        directory,
        keep: {p.normalize(target.path), p.normalize(source.path)},
      );
      return target.path;
    } on Object catch (e) {
      // Type only: the path itself is private and must not be logged.
      debugPrint('WallpaperPicker: import failed (${e.runtimeType})');
      return null;
    }
  }

  // ---- Android -----------------------------------------------------------

  Future<String?> _pickOnAndroid() async {
    final channel = _channel ?? const MethodChannel(channelName);
    try {
      final path = await channel.invokeMethod<String?>('pickWallpaper');
      final trimmed = path?.trim();
      return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    } on MissingPluginException {
      debugPrint('WallpaperPicker: media channel is unavailable');
      return null;
    } on PlatformException catch (e) {
      debugPrint('WallpaperPicker: pickWallpaper failed (${e.code})');
      return null;
    } on Object {
      debugPrint('WallpaperPicker: pickWallpaper failed');
      return null;
    }
  }

  // ---- Windows -----------------------------------------------------------

  /// WinForms needs an STA thread, hence `-STA`. Output is forced to UTF-8 so
  /// a Chinese path survives the pipe back into Dart.
  static const _windowsDialogScript = r'''
Add-Type -AssemblyName System.Windows.Forms;
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8;
$dialog = New-Object System.Windows.Forms.OpenFileDialog;
$dialog.Title = '选择背景壁纸';
$dialog.Filter = '图片文件 (*.jpg;*.jpeg;*.png;*.webp)|*.jpg;*.jpeg;*.png;*.webp|所有文件 (*.*)|*.*';
$dialog.CheckFileExists = $true;
$dialog.Multiselect = $false;
if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $dialog.FileName }
''';

  Future<String?> _pickOnWindows() async {
    try {
      final result = await Process.run(
        'powershell',
        const ['-NoProfile', '-STA', '-Command', _windowsDialogScript],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(_dialogTimeout);
      if (result.exitCode != 0) {
        debugPrint('WallpaperPicker: file dialog exited ${result.exitCode}');
        return null;
      }
      final picked = result.stdout.toString().trim();
      if (picked.isEmpty) return null;
      return await importFromFilePath(picked);
    } on Object {
      // PowerShell missing, dialog timed out, non-UTF-8 output, …
      debugPrint('WallpaperPicker: file dialog failed');
      return null;
    }
  }

  // ---- Shared helpers ----------------------------------------------------

  Future<Directory> _backgroundsDirectory() async {
    final override = _targetDirectory;
    if (override != null) return override;
    final support = await getApplicationSupportDirectory();
    return Directory(p.join(support.path, 'backgrounds'));
  }

  File _uniqueTarget(Directory directory, String suffix) {
    var stamp = DateTime.now().millisecondsSinceEpoch;
    var candidate = File(p.join(directory.path, '$_filePrefix$stamp$suffix'));
    var attempts = 0;
    // Same-millisecond picks are rare; the microsecond step only guards the
    // "never overwrite an existing file" rule.
    while (candidate.existsSync() && attempts < 8) {
      stamp = DateTime.now().microsecondsSinceEpoch;
      candidate = File(p.join(directory.path, '$_filePrefix$stamp$suffix'));
      attempts++;
    }
    return candidate;
  }

  void _pruneOldCopies(Directory directory, {required Set<String> keep}) {
    try {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        if (!p.basename(entity.path).startsWith(_filePrefix)) continue;
        if (keep.contains(p.normalize(entity.path))) continue;
        try {
          entity.deleteSync();
        } on Object {
          // Best effort: one stale copy must not fail the import.
        }
      }
    } on Object {
      // Best effort.
    }
  }

  /// Trims whitespace and peels one pair of matching quotes. Returns null for
  /// an empty result.
  static String? _normalizePath(String rawPath) {
    var value = rawPath.trim();
    // PowerShell may prepend a UTF-8 BOM when its output is piped back.
    if (value.startsWith('\uFEFF')) value = value.substring(1).trim();
    if (value.length >= 2) {
      final first = value[0];
      final last = value[value.length - 1];
      final quoted =
          (first == '"' && last == '"') || (first == "'" && last == "'");
      if (quoted) value = value.substring(1, value.length - 1).trim();
    }
    return value.isEmpty ? null : value;
  }
}

final wallpaperPickerProvider = Provider<WallpaperPickerService>(
  (ref) => const WallpaperPickerService(),
);
