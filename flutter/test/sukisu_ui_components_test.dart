import 'package:course_planner/app/theme.dart';
import 'package:course_planner/presentation/adaptive/adaptive.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// SukiSU-style components: segmented column, icon tile, capsule slider, and
/// the tonal HyperOS theme they sit on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ThemeData themeFor(Brightness brightness) => brightness == Brightness.light
      ? AppTheme.light(UiVariant.hyperOS)
      : AppTheme.dark(UiVariant.hyperOS);

  Widget host(Widget child, {Brightness brightness = Brightness.light}) {
    return MaterialApp(
      theme: themeFor(brightness),
      home: Scaffold(body: child),
    );
  }

  Future<void> pumpSegmented(
    WidgetTester tester,
    int count, {
    Brightness brightness = Brightness.light,
    String? title,
  }) async {
    await tester.pumpWidget(
      host(
        AppSegmentedColumn(
          title: title,
          margin: const EdgeInsets.all(12),
          children: [
            for (var i = 0; i < count; i++) ListTile(title: Text('设置项 $i')),
          ],
        ),
        brightness: brightness,
      ),
    );
  }

  group('AppSegmentedColumn', () {
    testWidgets('a lone row gets 24dp on every corner', (tester) async {
      await pumpSegmented(tester, 1);

      final clips = tester.widgetList<ClipRSuperellipse>(
        find.byType(ClipRSuperellipse),
      );
      expect(clips, hasLength(1));

      final radius = clips.first.borderRadius as BorderRadius;
      for (final corner in [
        radius.topLeft,
        radius.topRight,
        radius.bottomLeft,
        radius.bottomRight,
      ]) {
        expect(corner, const Radius.circular(24));
      }
    });

    testWidgets('two rows split 24dp outer / 6dp inner corners', (
      tester,
    ) async {
      await pumpSegmented(tester, 2);

      final clips = tester
          .widgetList<ClipRSuperellipse>(find.byType(ClipRSuperellipse))
          .toList();
      expect(clips, hasLength(2));

      final first = clips[0].borderRadius as BorderRadius;
      expect(first.topLeft, const Radius.circular(24));
      expect(first.topRight, const Radius.circular(24));
      expect(first.bottomLeft, const Radius.circular(6));
      expect(first.bottomRight, const Radius.circular(6));

      final last = clips[1].borderRadius as BorderRadius;
      expect(last.topLeft, const Radius.circular(6));
      expect(last.topRight, const Radius.circular(6));
      expect(last.bottomLeft, const Radius.circular(24));
      expect(last.bottomRight, const Radius.circular(24));
    });

    testWidgets('three rows keep 6dp corners in the middle and 2dp gaps', (
      tester,
    ) async {
      await pumpSegmented(tester, 3);

      final clips = tester
          .widgetList<ClipRSuperellipse>(find.byType(ClipRSuperellipse))
          .toList();
      expect(clips, hasLength(3));

      final middle = clips[1].borderRadius as BorderRadius;
      for (final corner in [
        middle.topLeft,
        middle.topRight,
        middle.bottomLeft,
        middle.bottomRight,
      ]) {
        expect(corner, const Radius.circular(6));
      }

      for (var i = 1; i < clips.length; i++) {
        final above = tester.getRect(find.byType(ClipRSuperellipse).at(i - 1));
        final below = tester.getRect(find.byType(ClipRSuperellipse).at(i));
        expect(below.top - above.bottom, moreOrLessEquals(2, epsilon: 0.01));
      }
    });

    testWidgets('rows sit on the bright tonal surface on light mode', (
      tester,
    ) async {
      await pumpSegmented(tester, 2);
      final expected = themeFor(Brightness.light).colorScheme.surfaceBright;

      final materials = tester.widgetList<Material>(
        find.descendant(
          of: find.byType(ClipRSuperellipse),
          matching: find.byType(Material),
        ),
      );
      expect(materials, isNotEmpty);
      for (final material in materials) {
        expect(material.color, expected);
      }
    });

    testWidgets('rows sit on the container-high surface in dark mode', (
      tester,
    ) async {
      await pumpSegmented(tester, 2, brightness: Brightness.dark);
      final scheme = themeFor(Brightness.dark).colorScheme;
      final expected = scheme.surfaceContainerHigh;

      final materials = tester.widgetList<Material>(
        find.descendant(
          of: find.byType(ClipRSuperellipse),
          matching: find.byType(Material),
        ),
      );
      expect(materials, isNotEmpty);
      for (final material in materials) {
        expect(material.color, expected);
      }
    });

    testWidgets('the group title is a primary-coloured caption', (
      tester,
    ) async {
      await pumpSegmented(tester, 1, title: '外观');

      final label = tester.widget<Text>(find.text('外观'));
      final scheme = themeFor(Brightness.light).colorScheme;
      expect(label.style!.fontSize, 13);
      expect(label.style!.fontWeight, FontWeight.w600);
      expect(label.style!.color, scheme.primary);
    });
  });

  group('AppIconTile', () {
    testWidgets('defaults to a 36dp tile with a 12dp tonal block', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(const Center(child: AppIconTile(icon: Icons.settings))),
      );

      final rect = tester.getRect(find.byType(AppIconTile));
      expect(rect.size, const Size(36, 36));

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppIconTile),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      final scheme = themeFor(Brightness.light).colorScheme;
      expect(decoration.color, scheme.secondaryContainer);
      expect(decoration.borderRadius, BorderRadius.circular(12));

      final icon = tester.widget<Icon>(find.byType(Icon));
      expect(icon.color, scheme.onSecondaryContainer);
      expect(icon.size, moreOrLessEquals(20));
    });

    testWidgets('respects a custom size and colours', (tester) async {
      await tester.pumpWidget(
        host(
          const Center(
            child: AppIconTile(
              icon: Icons.palette_outlined,
              size: 48,
              backgroundColor: Color(0xFF112233),
              iconColor: Color(0xFFFFFFFF),
            ),
          ),
        ),
      );

      final rect = tester.getRect(find.byType(AppIconTile));
      expect(rect.size, const Size(48, 48));

      final box = tester.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(AppIconTile),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      final decoration = box.decoration as BoxDecoration;
      expect(decoration.color, const Color(0xFF112233));
    });
  });

  group('AppCapsuleSlider', () {
    testWidgets('renders labels and forwards changes', (tester) async {
      double? changed;
      await tester.pumpWidget(
        host(
          Padding(
            padding: const EdgeInsets.all(16),
            child: AppCapsuleSlider(
              value: 0.4,
              label: '不透明度',
              valueLabel: '40%',
              onChanged: (value) => changed = value,
            ),
          ),
        ),
      );

      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('不透明度'), findsOneWidget);

      final scheme = themeFor(Brightness.light).colorScheme;
      final valueText = tester.widget<Text>(find.text('40%'));
      expect(valueText.style!.fontSize, 13);
      expect(valueText.style!.fontWeight, FontWeight.w600);
      expect(valueText.style!.color, scheme.primary);

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 0.4);
      slider.onChanged!(0.7);
      expect(changed, 0.7);

      await tester.drag(find.byType(Slider), const Offset(80, 0));
      await tester.pump();
      expect(changed, isNotNull);
    });

    testWidgets('clamps out-of-range values and honours divisions', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          AppCapsuleSlider(
            value: 4,
            min: 0,
            max: 3,
            divisions: 3,
            onChanged: (_) {},
          ),
        ),
      );

      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.value, 3);
      expect(slider.min, 0);
      expect(slider.max, 3);
      expect(slider.divisions, 3);
    });
  });

  group('AppSegmentedSwitchItem', () {
    testWidgets('toggles through the adaptive switch', (tester) async {
      var value = false;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) => AppSegmentedColumn(
              children: [
                AppSegmentedSwitchItem(
                  icon: Icons.dark_mode_outlined,
                  title: '深色模式',
                  subtitle: '跟随系统',
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                ),
              ],
            ),
          ),
        ),
      );

      expect(find.text('深色模式'), findsOneWidget);
      expect(find.text('跟随系统'), findsOneWidget);
      expect(find.byType(AppSwitch), findsOneWidget);

      await tester.tap(find.text('深色模式'));
      await tester.pumpAndSettle();
      expect(value, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('HyperOS tonal theme', () {
    test('light canvas comes from the scheme instead of white', () {
      final theme = AppTheme.light(UiVariant.hyperOS);
      final scheme = theme.colorScheme;

      expect(theme.scaffoldBackgroundColor, scheme.surfaceContainer);
      expect(theme.scaffoldBackgroundColor, isNot(Colors.white));
      expect(scheme.surface, scheme.surfaceBright);
    });

    test('dark canvas comes from the scheme instead of black', () {
      final theme = AppTheme.dark(UiVariant.hyperOS);
      final scheme = theme.colorScheme;

      expect(theme.scaffoldBackgroundColor, scheme.surfaceContainerLowest);
      expect(theme.scaffoldBackgroundColor, isNot(Colors.black));
      expect(scheme.surface, scheme.surfaceContainerHigh);
    });

    test('cards and dialogs use the tonal card surface', () {
      final light = AppTheme.light(UiVariant.hyperOS);
      expect(light.cardTheme.color, light.colorScheme.surfaceBright);
      expect(
        light.dialogTheme.backgroundColor,
        light.colorScheme.surfaceBright,
      );
      expect(
        light.bottomSheetTheme.backgroundColor,
        light.colorScheme.surfaceBright,
      );

      final dark = AppTheme.dark(UiVariant.hyperOS);
      expect(dark.cardTheme.color, dark.colorScheme.surfaceContainerHigh);
      expect(
        dark.dialogTheme.backgroundColor,
        dark.colorScheme.surfaceContainerHigh,
      );
    });

    test('the hairline border is a soft outline tint', () {
      for (final brightness in Brightness.values) {
        final theme = brightness == Brightness.light
            ? AppTheme.light(UiVariant.hyperOS)
            : AppTheme.dark(UiVariant.hyperOS);
        final tokens = theme.extension<AppStyleTokens>()!;
        expect(
          tokens.borderColor,
          theme.colorScheme.outlineVariant.withValues(alpha: 0.28),
        );
        expect(tokens.borderWidth, 0.5);
      }
    });

    test('inputs are filled and borderless, both variants', () {
      for (final theme in [
        AppTheme.light(),
        AppTheme.dark(),
        AppTheme.light(UiVariant.hyperOS),
        AppTheme.dark(UiVariant.hyperOS),
      ]) {
        final input = theme.inputDecorationTheme;
        expect(input.filled, isTrue);
        expect(input.fillColor, isNotNull);
        expect(input.border, isA<OutlineInputBorder>());
        expect(input.border!.borderSide, BorderSide.none);
        expect(input.enabledBorder, isA<OutlineInputBorder>());
        expect(input.enabledBorder!.borderSide, BorderSide.none);
        expect(input.focusedBorder, isA<OutlineInputBorder>());
        expect(input.focusedBorder!.borderSide.width, 1.5);
        expect(
          input.focusedBorder!.borderSide.color,
          theme.colorScheme.primary,
        );
      }
    });

    test('chips drop the outline and use tonal fills', () {
      final theme = AppTheme.light(UiVariant.hyperOS);
      final chip = theme.chipTheme;
      expect(chip.side, BorderSide.none);
      expect(chip.shape, isA<RoundedRectangleBorder>());
      expect(chip.selectedColor, theme.colorScheme.secondaryContainer);
    });

    test('sliders use the capsule track and hollow ring thumb', () {
      final theme = AppTheme.light(UiVariant.hyperOS);
      final slider = theme.sliderTheme;
      expect(slider.trackHeight, 8);
      expect(slider.activeTrackColor, theme.colorScheme.primary);
      expect(
        slider.inactiveTrackColor,
        theme.colorScheme.primary.withValues(alpha: 0.18),
      );
      expect(slider.thumbColor, theme.colorScheme.surfaceContainerLowest);
      expect(slider.thumbShape, isNotNull);
      expect(slider.thumbShape, isNot(isA<RoundSliderThumbShape>()));
      expect(slider.overlayShape, isA<RoundSliderOverlayShape>());
    });
  });

  group('AppCard tonal fill', () {
    Color? surfaceOf(WidgetTester tester, UiVariant variant) {
      if (variant == UiVariant.material3) {
        return tester.widget<Card>(find.byType(Card)).color;
      }
      final materialFinder = find
          .descendant(
            of: find.byType(AppCard),
            matching: find.byType(Material),
          )
          .first;
      return tester.widget<Material>(materialFinder).color;
    }

    testWidgets('light uses surfaceBright under both variants', (tester) async {
      for (final variant in UiVariant.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.light(variant),
            home: const Scaffold(body: AppCard(child: Text('卡片'))),
          ),
        );

        expect(
          surfaceOf(tester, variant),
          AppTheme.light(variant).colorScheme.surfaceBright,
        );
      }
    });

    testWidgets('dark uses surfaceContainerHigh under both variants', (
      tester,
    ) async {
      for (final variant in UiVariant.values) {
        await tester.pumpWidget(
          MaterialApp(
            theme: AppTheme.dark(variant),
            home: const Scaffold(body: AppCard(child: Text('卡片'))),
          ),
        );

        expect(
          surfaceOf(tester, variant),
          AppTheme.dark(variant).colorScheme.surfaceContainerHigh,
        );
      }
    });
  });
}
