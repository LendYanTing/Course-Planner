import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/media/wallpaper_picker.dart';
import 'package:course_planner/presentation/settings/appearance_settings_page.dart';
import 'package:course_planner/presentation/widgets/calendar_background.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Never touches the platform: the appearance page now copies typed paths into
/// private storage through [WallpaperPickerService].
class _FakeWallpaperPicker implements WallpaperPickerService {
  const _FakeWallpaperPicker({this.importedPath});

  final String? importedPath;

  @override
  Future<String?> pickWallpaper() async => null;

  @override
  Future<String?> importFromFilePath(String rawPath) async => importedPath;
}

/// Phase 3 appearance page: section layout, theme seeds, wallpaper choices,
/// live card-style sliders, the reset action and the `CalendarBackground`
/// render layer.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A container is used (instead of a bare `ProviderScope`) so the tests can
  /// both pump the page and read the providers it writes to.
  ProviderContainer createContainer([MemoryPrefs? prefs]) {
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(prefs ?? MemoryPrefs())],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget page(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: const AppearanceSettingsPage(),
      ),
    );
  }

  Widget calendar(
    ProviderContainer container, {
    required Widget child,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: CalendarBackground(child: child),
      ),
    );
  }

  /// A tall surface keeps every settings card built, so plain `find.text`
  /// assertions do not depend on the scroll offset.
  void useTallSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 3200);
    addTearDown(tester.view.reset);
  }

  testWidgets('renders the phase-3 sections, 8 seed swatches and reset action',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(page(createContainer()));
    await tester.pumpAndSettle();

    for (final title in ['实时预览', '主题与取色', '背景壁纸', '课程卡片与课表']) {
      expect(find.text(title), findsOneWidget, reason: 'missing section $title');
    }

    // The phase 2 pickers moved into the course card but keep their labels.
    for (final row in [
      '界面风格引擎',
      '底栏外观',
      '课表文字行数',
      '月视图格子高度',
      '中午分界点',
    ]) {
      expect(find.text(row), findsOneWidget, reason: 'missing row $row');
    }

    for (final hex in const [
      '3F51B5',
      '26A69A',
      'EC407A',
      'FFA000',
      '7E57C2',
      '9CCC65',
      '78909C',
      '29B6F6',
    ]) {
      expect(
        find.byKey(ValueKey('seed-swatch-$hex')),
        findsOneWidget,
        reason: 'missing seed swatch $hex',
      );
    }

    expect(find.text('从背景壁纸自动取色'), findsOneWidget);
    expect(find.text('设置本地背景图后生效'), findsOneWidget);
    expect(find.text('恢复默认外观'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('theme mode segment and seed swatch update themeConfigProvider',
      (tester) async {
    useTallSurface(tester);
    final container = createContainer();
    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(container.read(themeConfigProvider).mode, ThemeMode.dark);

    await tester.tap(find.byKey(const ValueKey('seed-swatch-EC407A')));
    await tester.pumpAndSettle();
    expect(container.read(themeConfigProvider).seedColorHex, '#EC407A');

    expect(tester.takeException(), isNull);
  });

  testWidgets('a preset wallpaper is stored and painted by the preview',
      (tester) async {
    useTallSurface(tester);
    final container = ProviderContainer(
      overrides: [
        prefStoreProvider.overrideWithValue(MemoryPrefs()),
        // The apply action now imports the typed path into private storage.
        wallpaperPickerProvider.overrideWithValue(
          const _FakeWallpaperPicker(importedPath: r'C:\walls\photo.jpg'),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('wallpaper-preset-lotus')));
    await tester.pumpAndSettle();

    final config = container.read(backgroundConfigProvider);
    expect(config.presetId, 'lotus');
    expect(config.hasBackground, isTrue);
    // The live preview now paints the preset gradient layer.
    expect(find.byKey(calendarBackgroundPresetKey), findsOneWidget);

    // The legacy path field lives in the advanced expansion tile.
    await tester.tap(find.text('高级：手动输入图片路径'));
    await tester.pumpAndSettle();

    // A typed local path replaces the preset (the two sources are exclusive).
    await tester.enterText(
      find.byKey(const ValueKey('wallpaper-path-field')),
      r'C:\walls\photo.jpg',
    );
    await tester.tap(find.byKey(const ValueKey('wallpaper-path-apply')));
    await tester.pumpAndSettle();

    final edited = container.read(backgroundConfigProvider);
    expect(edited.imagePath, r'C:\walls\photo.jpg');
    expect(edited.presetId, isNull);

    expect(tester.takeException(), isNull);
  });

  testWidgets('card sliders drive courseCardStyleProvider and label values',
      (tester) async {
    useTallSurface(tester);
    final container = createContainer();
    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    final slider = find.byKey(const ValueKey('card-opacity-slider'));
    expect(slider, findsOneWidget);

    // Drive the slider's callback directly: a synthetic drag would depend on
    // the track geometry, while this still proves the wiring to the provider.
    final widget = tester.widget<Slider>(slider);
    expect(widget.onChanged, isNotNull);
    widget.onChanged!(0.55);
    await tester.pumpAndSettle();
    expect(
      container.read(courseCardStyleProvider).opacity,
      closeTo(0.55, 0.001),
    );
    expect(find.text('55%'), findsOneWidget);

    // Direct controller writes repaint the row's value label too.
    await container.read(courseCardStyleProvider.notifier).setOpacity(0.5);
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);

    expect(tester.takeException(), isNull);
  });

  testWidgets('CalendarBackground returns its child when no background is set',
      (tester) async {
    final container = createContainer();
    await tester.pumpWidget(
      calendar(container, child: const Text('页面内容')),
    );
    await tester.pump();

    expect(find.text('页面内容'), findsOneWidget);
    expect(find.byKey(calendarBackgroundPresetKey), findsNothing);
    expect(find.byKey(calendarBackgroundFallbackKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('CalendarBackground paints a preset gradient under the child',
      (tester) async {
    final container = createContainer();
    await container
        .read(backgroundConfigProvider.notifier)
        .setPresetId('aurora');

    await tester.pumpWidget(
      calendar(
        container,
        child: const SizedBox.expand(child: Center(child: Text('页面内容'))),
      ),
    );
    await tester.pump();

    expect(find.byKey(calendarBackgroundPresetKey), findsOneWidget);
    expect(find.text('页面内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unreadable local image falls back to a gradient',
      (tester) async {
    final container = createContainer();
    await container
        .read(backgroundConfigProvider.notifier)
        .setImagePath(r'C:\definitely-missing\wallpaper.png');

    await tester.pumpWidget(
      calendar(container, child: const Text('页面内容')),
    );
    await tester.pump();

    expect(find.byKey(calendarBackgroundFallbackKey), findsOneWidget);
    expect(find.text('页面内容'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('恢复默认外观 resets every appearance preference',
      (tester) async {
    useTallSurface(tester);
    final container = createContainer();

    await container.read(courseCardStyleProvider.notifier).setOpacity(0.4);
    await container.read(courseCardStyleProvider.notifier).setRowHeight(80);
    await container.read(themeConfigProvider.notifier).setMode(ThemeMode.dark);
    await container.read(themeConfigProvider.notifier).setSeedHex('#EC407A');
    await container
        .read(backgroundConfigProvider.notifier)
        .setPresetId('nebula');
    await container.read(backgroundConfigProvider.notifier).setBlurSigma(14);
    await container
        .read(bottomBarStyleProvider.notifier)
        .set(BottomBarStyle.solidCapsule);
    await container.read(tileTextLinesProvider.notifier).setTitle(4);
    await container.read(monthCellHeightProvider.notifier).set(120);
    await container.read(noonBoundaryProvider.notifier).set(14 * 60);

    await tester.pumpWidget(page(container));
    await tester.pumpAndSettle();

    await tester.tap(find.text('恢复默认外观'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('恢复'));
    await tester.pumpAndSettle();

    expect(container.read(courseCardStyleProvider), const CourseCardStyle());

    final theme = container.read(themeConfigProvider);
    expect(theme.mode, ThemeMode.system);
    expect(theme.seedColorHex, ThemeConfig.defaultSeedHex);
    expect(theme.useWallpaperMonet, isTrue);

    final background = container.read(backgroundConfigProvider);
    expect(background.hasBackground, isFalse);
    expect(background.blurSigma, 0.0);
    expect(background.scrimOpacity, 0.25);

    expect(container.read(bottomBarStyleProvider), BottomBarStyle.liquidGlass);
    expect(
      container.read(tileTextLinesProvider),
      TileTextLinesController.defaults,
    );
    expect(
      container.read(monthCellHeightProvider),
      MonthCellHeightController.defaultDp,
    );
    expect(
      container.read(noonBoundaryProvider),
      NoonBoundaryController.defaultMinutes,
    );
    expect(tester.takeException(), isNull);
  });
}
