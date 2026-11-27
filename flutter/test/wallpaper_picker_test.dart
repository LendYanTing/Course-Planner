import 'dart:convert';
import 'dart:io';

import 'package:course_planner/core/media/wallpaper_picker.dart';
import 'package:course_planner/presentation/settings/appearance_settings_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/memory_prefs.dart';

/// 1 × 1 transparent PNG, enough for `Image.file` to decode without errors.
final _pngBytes = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Test double for [WallpaperPickerService]: never touches the platform.
class _FakeWallpaperPicker implements WallpaperPickerService {
  _FakeWallpaperPicker({this.pickedPath, this.importedPath});

  final String? pickedPath;
  final String? importedPath;

  int pickCalls = 0;
  String? lastImportedRaw;

  @override
  Future<String?> pickWallpaper() async {
    pickCalls++;
    return pickedPath;
  }

  @override
  Future<String?> importFromFilePath(String rawPath) async {
    lastImportedRaw = rawPath;
    return importedPath;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('wallpaper_picker_test_');
  });
  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  File sourceImage([String name = 'source.png']) {
    final file = File(p.join(tempDir.path, name));
    file.writeAsBytesSync(_pngBytes);
    return file;
  }

  Directory targetDirectory() => Directory(p.join(tempDir.path, 'backgrounds'));

  group('importFromFilePath', () {
    test('copies the file into backgrounds/ and keeps the source', () async {
      final source = sourceImage();
      final service = WallpaperPickerService(
        directory: targetDirectory(),
      );

      final imported = await service.importFromFilePath(source.path);

      expect(imported, isNotNull);
      final copy = File(imported!);
      expect(copy.existsSync(), isTrue);
      expect(copy.readAsBytesSync(), _pngBytes);
      expect(p.dirname(copy.path), targetDirectory().path);
      expect(p.basename(copy.path), startsWith('wallpaper_'));
      expect(p.extension(copy.path), '.png');
      // The user's original file is never moved or deleted.
      expect(source.existsSync(), isTrue);
    });

    test('returns null for a path that does not exist', () async {
      final service = WallpaperPickerService(
        directory: targetDirectory(),
      );

      expect(
        await service.importFromFilePath(p.join(tempDir.path, 'missing.png')),
        isNull,
      );
      expect(targetDirectory().existsSync(), isFalse);
    });

    test('trims whitespace and peels matching quotes', () async {
      final source = sourceImage();
      final service = WallpaperPickerService(
        directory: targetDirectory(),
      );

      final quoted = await service.importFromFilePath('  "${source.path}"  ');
      expect(quoted, isNotNull);
      expect(File(quoted!).existsSync(), isTrue);

      final singleQuoted =
          await service.importFromFilePath(" '${source.path}' ");
      expect(singleQuoted, isNotNull);
      expect(File(singleQuoted!).existsSync(), isTrue);
    });

    test('returns null for empty or blank input', () async {
      final service = WallpaperPickerService(
        directory: targetDirectory(),
      );

      expect(await service.importFromFilePath(''), isNull);
      expect(await service.importFromFilePath('   '), isNull);
      expect(await service.importFromFilePath('""'), isNull);
    });

    test('never overwrites the previous copy', () async {
      final first = sourceImage('first.png');
      final second = sourceImage('second.png');
      final service = WallpaperPickerService(
        directory: targetDirectory(),
      );

      final firstCopy = await service.importFromFilePath(first.path);
      final secondCopy = await service.importFromFilePath(second.path);

      expect(firstCopy, isNotNull);
      expect(secondCopy, isNotNull);
      expect(firstCopy, isNot(secondCopy));
      // The newest pick replaces the stale private copy.
      expect(File(firstCopy!).existsSync(), isFalse);
      expect(File(secondCopy!).readAsBytesSync(), _pngBytes);
    });
  });

  group('pickWallpaper on Android', () {
    const channel = MethodChannel(WallpaperPickerService.channelName);

    void mockHandler(Future<Object?> Function(MethodCall call) handler) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, handler);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding
            .instance
            .defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
    }

    test('returns the private path reported by the native side', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockHandler((call) async {
        expect(call.method, 'pickWallpaper');
        return '/data/user/0/app/files/backgrounds/wallpaper_1.jpg';
      });

      expect(
        await const WallpaperPickerService().pickWallpaper(),
        '/data/user/0/app/files/backgrounds/wallpaper_1.jpg',
      );
    });

    test('turns a cancelled pick into null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockHandler((call) async => null);

      expect(await const WallpaperPickerService().pickWallpaper(), isNull);
    });

    test('never throws when the channel reports an error', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      mockHandler(
        (call) async => throw PlatformException(code: 'copy_failed'),
      );

      expect(await const WallpaperPickerService().pickWallpaper(), isNull);
    });
  });

  test('pickWallpaper returns null on unsupported platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.linux;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);

    expect(await const WallpaperPickerService().pickWallpaper(), isNull);
  });

  // ---- Appearance page integration ---------------------------------------

  Widget page(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: const AppearanceSettingsPage(),
      ),
    );
  }

  ProviderContainer containerWith(WallpaperPickerService picker) {
    final container = ProviderContainer(
      overrides: [
        prefStoreProvider.overrideWithValue(MemoryPrefs()),
        wallpaperPickerProvider.overrideWithValue(picker),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// A tall surface keeps every settings tile built (and tappable) without
  /// scrolling-dependent finders.
  void useTallSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 3600);
    addTearDown(tester.view.reset);
  }

  testWidgets('the pick button stores the image, shows it and clears it',
      (tester) async {
    useTallSurface(tester);
    final image = sourceImage('picked.png');
    final picker = _FakeWallpaperPicker(pickedPath: image.path);
    final container = containerWith(picker);

    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    final pickButton = find.byKey(const ValueKey('wallpaper-pick-button'));
    expect(pickButton, findsOneWidget);
    await tester.ensureVisible(pickButton);
    await tester.pumpAndSettle();
    await tester.tap(pickButton);
    await tester.pumpAndSettle();

    expect(picker.pickCalls, 1);
    expect(container.read(backgroundConfigProvider).imagePath, image.path);
    expect(find.text('已设置壁纸'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('wallpaper-image-thumbnail')),
      findsOneWidget,
    );
    expect(find.text('清除图片'), findsOneWidget);

    await tester.tap(find.text('清除图片'));
    await tester.pumpAndSettle();

    expect(container.read(backgroundConfigProvider).imagePath, isNull);
    expect(
      find.byKey(const ValueKey('wallpaper-image-thumbnail')),
      findsNothing,
    );
    expect(find.text('清除图片'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a null pick shows the unsupported-platform hint',
      (tester) async {
    useTallSurface(tester);
    final container = containerWith(_FakeWallpaperPicker());

    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    final pickButton = find.byKey(const ValueKey('wallpaper-pick-button'));
    await tester.ensureVisible(pickButton);
    await tester.pumpAndSettle();
    await tester.tap(pickButton);
    await tester.pumpAndSettle();

    expect(container.read(backgroundConfigProvider).imagePath, isNull);
    expect(find.text('未选择图片或该平台不支持'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the advanced path field expands and imports the typed path',
      (tester) async {
    useTallSurface(tester);
    final imported = p.join(targetDirectory().path, 'wallpaper_1.jpg');
    final picker = _FakeWallpaperPicker(importedPath: imported);
    final container = containerWith(picker);

    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    final advanced = find.text('高级：手动输入图片路径');
    expect(advanced, findsOneWidget);
    // Collapsed by default: the legacy keys are not built yet.
    expect(find.byKey(const ValueKey('wallpaper-path-field')), findsNothing);

    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();

    final field = find.byKey(const ValueKey('wallpaper-path-field'));
    expect(field, findsOneWidget);
    expect(
      find.byKey(const ValueKey('wallpaper-path-apply')),
      findsOneWidget,
    );

    await tester.enterText(field, r'"C:\walls\photo.png"');
    await tester.tap(find.byKey(const ValueKey('wallpaper-path-apply')));
    await tester.pumpAndSettle();

    expect(picker.lastImportedRaw, r'"C:\walls\photo.png"');
    expect(container.read(backgroundConfigProvider).imagePath, imported);
    expect(tester.takeException(), isNull);
  });
}
