import 'dart:convert';

import 'package:course_planner/app/theme.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Theme mode / Monet / background / course-card preferences (phase 3 Step 1)
/// plus the theme entry points the app root mounts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith(MemoryPrefs prefs) {
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// Lets the controllers' async `_restore()` finish.
  Future<void> settle() => pumpEventQueue();

  group('ThemeConfigController', () {
    test('defaults to system / Monet on / indigo seed', () {
      final container = containerWith(MemoryPrefs());
      final config = container.read(themeConfigProvider);

      expect(config.mode, ThemeMode.system);
      expect(config.useWallpaperMonet, isTrue);
      expect(config.seedColorHex, '#3F51B5');
      expect(config, const ThemeConfig());
    });

    test('setters update state and persist one JSON blob per key', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      final notifier = container.read(themeConfigProvider.notifier);

      await notifier.setMode(ThemeMode.dark);
      await notifier.setSeedHex('#26A69A');
      await notifier.setUseWallpaperMonet(false);

      final config = container.read(themeConfigProvider);
      expect(config.mode, ThemeMode.dark);
      expect(config.seedColorHex, '#26A69A');
      expect(config.useWallpaperMonet, isFalse);

      final raw = await prefs.read('theme_config');
      expect(raw, isNotNull);
      final json = jsonDecode(raw!) as Map<String, dynamic>;
      expect(json['mode'], 'dark');
      expect(json['seedColorHex'], '#26A69A');
      expect(json['useWallpaperMonet'], false);
    });

    test('restores a persisted config in a fresh container', () async {
      final prefs = MemoryPrefs();
      final first = containerWith(prefs);
      await first.read(themeConfigProvider.notifier).setMode(ThemeMode.light);
      await first
          .read(themeConfigProvider.notifier)
          .setUseWallpaperMonet(false);

      final second = containerWith(prefs);
      expect(second.read(themeConfigProvider), const ThemeConfig());
      await settle();

      final restored = second.read(themeConfigProvider);
      expect(restored.mode, ThemeMode.light);
      expect(restored.useWallpaperMonet, isFalse);
      expect(restored.seedColorHex, '#3F51B5');
    });

    test('setSeedHex normalises input and ignores malformed values', () async {
      final container = containerWith(MemoryPrefs());
      final notifier = container.read(themeConfigProvider.notifier);

      await notifier.setSeedHex('26a69a');
      expect(container.read(themeConfigProvider).seedColorHex, '#26A69A');

      await notifier.setSeedHex('not-a-colour');
      expect(container.read(themeConfigProvider).seedColorHex, '#26A69A');
    });

    test('malformed persisted JSON keeps the defaults', () async {
      final container = containerWith(
        MemoryPrefs(const {'theme_config': '{"mode":42}'}),
      );
      await settle();
      expect(container.read(themeConfigProvider), const ThemeConfig());
    });
  });

  group('BackgroundConfigController', () {
    test('defaults to no background', () {
      final config = containerWith(MemoryPrefs())
          .read(backgroundConfigProvider);

      expect(config.imagePath, isNull);
      expect(config.presetId, isNull);
      expect(config.blurSigma, 0.0);
      expect(config.scrimOpacity, 0.25);
      expect(config.hasBackground, isFalse);
    });

    test('clamps blur and scrim to their documented ranges', () async {
      final container = containerWith(MemoryPrefs());
      final notifier = container.read(backgroundConfigProvider.notifier);

      await notifier.setBlurSigma(30);
      expect(container.read(backgroundConfigProvider).blurSigma, 25.0);
      await notifier.setBlurSigma(-4);
      expect(container.read(backgroundConfigProvider).blurSigma, 0.0);

      await notifier.setScrimOpacity(1.0);
      expect(container.read(backgroundConfigProvider).scrimOpacity, 0.85);
      await notifier.setScrimOpacity(-0.5);
      expect(container.read(backgroundConfigProvider).scrimOpacity, 0.0);
    });

    test('preset id survives a round trip and counts as a background',
        () async {
      final prefs = MemoryPrefs();
      final first = containerWith(prefs);
      final notifier = first.read(backgroundConfigProvider.notifier);

      await notifier.setPresetId('aurora');
      await notifier.setBlurSigma(12);
      await notifier.setScrimOpacity(0.4);
      expect(first.read(backgroundConfigProvider).hasBackground, isTrue);

      final second = containerWith(prefs);
      second.read(backgroundConfigProvider); // build kicks off the async restore
      await settle();
      final restored = second.read(backgroundConfigProvider);

      expect(restored.presetId, 'aurora');
      expect(restored.imagePath, isNull);
      expect(restored.blurSigma, 12.0);
      expect(restored.scrimOpacity, 0.4);
      expect(restored.hasBackground, isTrue);
    });

    test('image and preset are mutually exclusive', () async {
      final container = containerWith(MemoryPrefs());
      final notifier = container.read(backgroundConfigProvider.notifier);

      await notifier.setPresetId('nebula');
      await notifier.setImagePath(r'C:\walls\lotus.png');
      var config = container.read(backgroundConfigProvider);
      expect(config.imagePath, r'C:\walls\lotus.png');
      expect(config.presetId, isNull);

      await notifier.setPresetId('nebula');
      config = container.read(backgroundConfigProvider);
      expect(config.imagePath, isNull);
      expect(config.presetId, 'nebula');

      await notifier.clear();
      config = container.read(backgroundConfigProvider);
      expect(config.hasBackground, isFalse);
    });

    test('persisted out-of-range values are clamped on restore', () async {
      final container = containerWith(
        MemoryPrefs(const {
          'background_config':
              '{"presetId":"dawn","blurSigma":99,"scrimOpacity":2.0}',
        }),
      );
      container.read(backgroundConfigProvider); // build kicks off the async restore
      await settle();
      final config = container.read(backgroundConfigProvider);

      expect(config.presetId, 'dawn');
      expect(config.blurSigma, 25.0);
      expect(config.scrimOpacity, 0.85);
    });

    test('hasBackground ignores whether the file exists', () {
      const config = BackgroundConfig(imagePath: r'C:\missing\x.png');
      expect(config.hasBackground, isTrue);
      expect(const BackgroundConfig(imagePath: '').hasBackground, isFalse);
    });
  });

  group('CourseCardStyleController', () {
    test('defaults match the previous hard-coded tile values', () {
      final style = containerWith(MemoryPrefs()).read(courseCardStyleProvider);

      expect(style.opacity, 0.92);
      expect(style.borderRadius, 8.0);
      expect(style.margin, 1.5);
      expect(style.fontScale, 1.0);
      expect(style.rowHeight, 54.0);
    });

    test('every setter clamps to its documented range', () async {
      final container = containerWith(MemoryPrefs());
      final notifier = container.read(courseCardStyleProvider.notifier);

      await notifier.setOpacity(0.1);
      await notifier.setBorderRadius(40);
      await notifier.setMargin(9);
      await notifier.setFontScale(3);
      await notifier.setRowHeight(200);

      var style = container.read(courseCardStyleProvider);
      expect(style.opacity, 0.30);
      expect(style.borderRadius, 16.0);
      expect(style.margin, 4.0);
      expect(style.fontScale, 1.30);
      expect(style.rowHeight, 90.0);

      await notifier.setOpacity(1.5);
      await notifier.setBorderRadius(0);
      await notifier.setMargin(0);
      await notifier.setFontScale(0.1);
      await notifier.setRowHeight(10);

      style = container.read(courseCardStyleProvider);
      expect(style.opacity, 1.0);
      expect(style.borderRadius, 4.0);
      expect(style.margin, 0.5);
      expect(style.fontScale, 0.85);
      expect(style.rowHeight, 44.0);
    });

    test('JSON round trip keeps every knob and clamps corrupt numbers',
        () async {
      const style = CourseCardStyle(
        opacity: 0.75,
        borderRadius: 12,
        margin: 2.5,
        fontScale: 1.15,
        rowHeight: 72,
      );
      final decoded = CourseCardStyle.fromJson(
        jsonDecode(jsonEncode(style.toJson())) as Map<String, dynamic>,
      );
      expect(decoded, style);

      final corrupt = CourseCardStyle.fromJson(const {
        'opacity': 2,
        'borderRadius': -1,
        'margin': 0,
        'fontScale': 9,
        'rowHeight': 1000,
      });
      expect(corrupt.opacity, 1.0);
      expect(corrupt.borderRadius, 4.0);
      expect(corrupt.margin, 0.5);
      expect(corrupt.fontScale, 1.30);
      expect(corrupt.rowHeight, 90.0);
    });

    test('settings survive a container restart', () async {
      final prefs = MemoryPrefs();
      final first = containerWith(prefs);
      final notifier = first.read(courseCardStyleProvider.notifier);

      await notifier.setRowHeight(72);
      await notifier.setFontScale(1.2);

      final second = containerWith(prefs);
      second.read(courseCardStyleProvider); // build kicks off the async restore
      await settle();
      final restored = second.read(courseCardStyleProvider);

      expect(restored.rowHeight, 72.0);
      expect(restored.fontScale, 1.2);
      expect(restored.opacity, 0.92);
    });

    test('reset restores every default', () async {
      final container = containerWith(MemoryPrefs());
      final notifier = container.read(courseCardStyleProvider.notifier);

      await notifier.setOpacity(0.4);
      await notifier.reset();

      expect(
        container.read(courseCardStyleProvider),
        const CourseCardStyle(),
      );
    });
  });

  group('AppTheme custom scheme', () {
    final customLight =
        ColorScheme.fromSeed(seedColor: const Color(0xFF26A69A));
    final customDark = ColorScheme.fromSeed(
      seedColor: const Color(0xFF26A69A),
      brightness: Brightness.dark,
    );

    test('light/dark use the given scheme instead of the seeded one', () {
      final light = AppTheme.light(UiVariant.material3, customLight);
      expect(light.colorScheme.primary, customLight.primary);
      expect(light.colorScheme.surface, customLight.surface);

      final dark = AppTheme.dark(UiVariant.material3, customDark);
      expect(dark.colorScheme.primary, customDark.primary);
      expect(dark.colorScheme.surface, customDark.surface);
    });

    test('no-argument builders still use the indigo seed', () {
      final defaultLight = AppTheme.light();
      expect(
        defaultLight.colorScheme.primary,
        ColorScheme.fromSeed(seedColor: AppTheme.seed).primary,
      );
    });

    test('HyperOS keeps its surface ladder on top of the custom scheme', () {
      final theme = AppTheme.light(UiVariant.hyperOS, customLight);
      expect(theme.extension<AppStyleTokens>()!.variant, UiVariant.hyperOS);
      expect(theme.colorScheme.primary, customLight.primary);
      expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF2F3F5));
    });
  });

  group('wallpaperColorSchemeProvider', () {
    test('missing file yields null so the seed scheme stays in use', () async {
      final container = containerWith(MemoryPrefs());
      final scheme = await container.read(
        wallpaperColorSchemeProvider(
          (path: '/nope.png', brightness: Brightness.light),
        ).future,
      );
      expect(scheme, isNull);
    });
  });
}
