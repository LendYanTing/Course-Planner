import 'package:course_planner/app/theme.dart';
import 'package:course_planner/presentation/adaptive/adaptive.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Variant-aware widgets must build under both UiVariant values, and the
/// dialog / sheet helpers must actually show their content.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget app({required UiVariant variant, required Widget home}) {
    return ProviderScope(
      overrides: [prefStoreProvider.overrideWithValue(MemoryPrefs())],
      child: MaterialApp(
        theme: AppTheme.light(variant),
        home: home,
      ),
    );
  }

  for (final variant in UiVariant.values) {
    testWidgets('${variant.name}: card, switch and top bar build', (tester) async {
      var toggles = 0;

      await tester.pumpWidget(
        app(
          variant: variant,
          home: Scaffold(
            appBar: AppTopBar(title: '课程表'),
            body: Column(
              children: [
                const AppCard(child: Text('卡片内容')),
                AppSwitch(value: false, onChanged: (_) => toggles++),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('卡片内容'), findsOneWidget);
      expect(find.text('课程表'), findsOneWidget);

      await tester.tap(find.byType(AppSwitch));
      await tester.pumpAndSettle();
      expect(toggles, 1);

      expect(tester.takeException(), isNull);
    });

    testWidgets('${variant.name}: bottom sheet shows its content', (tester) async {
      await tester.pumpWidget(
        app(
          variant: variant,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppBottomSheet<void>(
                  context: context,
                  builder: (_) => const SizedBox(
                    height: 120,
                    child: Center(child: Text('底部面板内容')),
                  ),
                ),
                child: const Text('打开面板'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开面板'));
      await tester.pumpAndSettle();

      expect(find.text('底部面板内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${variant.name}: dialog shows title, content and actions',
        (tester) async {
      // Phone-sized surface: HyperOS docks its dialog to the bottom edge.
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        app(
          variant: variant,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAppDialog<void>(
                  context: context,
                  title: '删除课程',
                  content: const Text('删除后无法恢复。'),
                  actions: const [
                    TextButton(onPressed: null, child: Text('取消')),
                    FilledButton(onPressed: null, child: Text('删除')),
                  ],
                ),
                child: const Text('打开对话框'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('打开对话框'));
      await tester.pumpAndSettle();

      expect(find.text('删除课程'), findsOneWidget);
      expect(find.text('删除后无法恢复。'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
      if (variant == UiVariant.hyperOS) {
        final panel = tester.getRect(find.byType(ClipRSuperellipse));
        expect(panel.bottom, moreOrLessEquals(844 - 12, epsilon: 1));
      }
      expect(tester.takeException(), isNull);
    });
  }
}
