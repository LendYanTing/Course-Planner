import 'package:course_planner/app/adaptive_page.dart';
import 'package:course_planner/app/theme.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/memory_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UiVariantController', () {
    ProviderContainer containerWith(MemoryPrefs prefs) {
      final container = ProviderContainer(
        overrides: [prefStoreProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('defaults to material3', () {
      final container = containerWith(MemoryPrefs());
      expect(container.read(uiVariantProvider), UiVariant.material3);
    });

    test('set(hyperOS) updates state and persists the enum name', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);

      await container.read(uiVariantProvider.notifier).set(UiVariant.hyperOS);

      expect(container.read(uiVariantProvider), UiVariant.hyperOS);
      expect(await prefs.read('ui_variant'), 'hyperOS');
    });

    test('restores a persisted variant', () async {
      final container =
          containerWith(MemoryPrefs(const {'ui_variant': 'hyperOS'}));
      expect(container.read(uiVariantProvider), UiVariant.material3);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(uiVariantProvider), UiVariant.hyperOS);
    });

    test('ignores an unknown persisted value', () async {
      final container =
          containerWith(MemoryPrefs(const {'ui_variant': 'metro'}));
      expect(container.read(uiVariantProvider), UiVariant.material3);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(uiVariantProvider), UiVariant.material3);
    });
  });

  group('AppTheme variants', () {
    test('hyperOS light carries its tokens and tonal canvas', () {
      final theme = AppTheme.light(UiVariant.hyperOS);
      final tokens = theme.extension<AppStyleTokens>();
      final seeded = ColorScheme.fromSeed(seedColor: AppTheme.seed);

      expect(tokens, isNotNull);
      expect(tokens!.variant, UiVariant.hyperOS);
      expect(tokens.cardRadius, 20);
      expect(tokens.buttonRadius, 999);
      expect(tokens.useElevation, isFalse);
      expect(tokens.topBarBlur, isTrue);
      // The canvas is the scheme's tonal container, not a hard-coded grey.
      expect(theme.scaffoldBackgroundColor, seeded.surfaceContainer);
      expect(theme.scaffoldBackgroundColor, isNot(Colors.white));
      expect(theme.colorScheme.surface, seeded.surfaceBright);
      expect(
        theme.scaffoldBackgroundColor,
        isNot(AppTheme.light().scaffoldBackgroundColor),
      );
      expect(theme.appBarTheme.backgroundColor, Colors.transparent);
      expect(theme.appBarTheme.scrolledUnderElevation, 0);
    });

    test('hyperOS dark paints a tonal canvas with container-high cards', () {
      final theme = AppTheme.dark(UiVariant.hyperOS);
      final tokens = theme.extension<AppStyleTokens>();
      final seeded = ColorScheme.fromSeed(
        seedColor: AppTheme.seed,
        brightness: Brightness.dark,
      );

      expect(tokens, isNotNull);
      expect(tokens!.variant, UiVariant.hyperOS);
      expect(theme.scaffoldBackgroundColor, seeded.surfaceContainerLowest);
      expect(theme.scaffoldBackgroundColor, isNot(Colors.black));
      expect(theme.colorScheme.surface, seeded.surfaceContainerHigh);
      expect(theme.colorScheme.surfaceContainerLow, seeded.surfaceContainerLow);
      expect(
        theme.scaffoldBackgroundColor,
        isNot(AppTheme.dark().scaffoldBackgroundColor),
      );
    });

    test('no-argument builders stay on Material 3', () {
      for (final theme in [AppTheme.light(), AppTheme.dark()]) {
        final tokens = theme.extension<AppStyleTokens>();
        expect(tokens, isNotNull);
        expect(tokens!.variant, UiVariant.material3);
        expect(tokens.cardRadius, 12);
        expect(tokens.useElevation, isTrue);
      }
    });

    testWidgets('AppStyleTokens.of reads the extension', (tester) async {
      late AppStyleTokens seen;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(UiVariant.hyperOS),
          home: Builder(
            builder: (context) {
              seen = AppStyleTokens.of(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(seen.variant, UiVariant.hyperOS);
      expect(seen.cardRadius, 20);
    });

    test('spring curve starts at 0, ends at 1 and overshoots', () {
      final curve = AppStyleTokens.springCurve(
        const SpringDescription(mass: 1, stiffness: 360, damping: 26),
      );
      expect(curve.transform(0), 0);
      expect(curve.transform(1), 1);
      final peak = [for (var i = 1; i < 100; i++) curve.transform(i / 100)]
          .reduce((a, b) => a > b ? a : b);
      expect(peak, greaterThan(1));
    });
  });

  group('buildAdaptivePage', () {
    test('Material 3 uses MaterialPage', () {
      final page = buildAdaptivePage<Object?>(
        key: const ValueKey('a'),
        child: const SizedBox.shrink(),
        variant: UiVariant.material3,
      );
      expect(page, isA<MaterialPage<Object?>>());
    });

    test('HyperOS uses a custom transition page', () {
      final page = buildAdaptivePage<Object?>(
        key: const ValueKey('a'),
        child: const SizedBox.shrink(),
        variant: UiVariant.hyperOS,
      );
      expect(page, isA<CustomTransitionPage<Object?>>());
      expect(
        (page as CustomTransitionPage<Object?>).transitionDuration,
        HyperOsPageTransitionsBuilder.duration,
      );
    });
  });
}
