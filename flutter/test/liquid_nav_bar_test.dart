import 'package:course_planner/presentation/widgets/liquid_floating_nav_bar.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// The floating bar: three materials (all must render, the shader path falls
/// back on non-Impeller / in tests), tap selection and press-and-drag selection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const items = <LiquidNavItem>[
    LiquidNavItem(icon: Icons.view_week_outlined, selectedIcon: Icons.view_week, label: '周视图'),
    LiquidNavItem(icon: Icons.calendar_month_outlined, selectedIcon: Icons.calendar_month, label: '月视图'),
    LiquidNavItem(icon: Icons.checklist_outlined, selectedIcon: Icons.checklist, label: '待办'),
    LiquidNavItem(icon: Icons.settings_outlined, selectedIcon: Icons.settings, label: '设置'),
  ];

  Future<MemoryPrefs> pumpBar(
    WidgetTester tester, {
    BottomBarStyle style = BottomBarStyle.liquidGlass,
    int index = 0,
    ValueChanged<int>? onSelected,
  }) async {
    final prefs = MemoryPrefs();
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    await container.read(bottomBarStyleProvider.notifier).set(style);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: Scaffold(
            // Mirrors home_shell: content scrolls underneath the bar.
            extendBody: true,
            body: ListView(
              children: [
                for (var i = 0; i < 40; i++)
                  SizedBox(height: 32, child: Text('row $i')),
              ],
            ),
            bottomNavigationBar: LiquidFloatingNavBar(
              currentIndex: index,
              items: items,
              onSelected: onSelected ?? (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return prefs;
  }

  for (final style in BottomBarStyle.values) {
    testWidgets('renders ${style.name} with all labels', (tester) async {
      await pumpBar(tester, style: style);
      await tester.pump(const Duration(milliseconds: 50));
      for (final item in items) {
        expect(find.text(item.label), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('tapping a tab reports its index', (tester) async {
    int? selected;
    await pumpBar(tester, onSelected: (i) => selected = i);

    await tester.tap(find.text('待办'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a horizontal drag lands on the nearest tab', (tester) async {
    int? selected;
    await pumpBar(tester, onSelected: (i) => selected = i);

    final rect = tester.getRect(find.byType(LiquidFloatingNavBar));
    final itemWidth =
        (rect.width - LiquidFloatingNavBar.sideInset * 2) / items.length;
    final y = rect.center.dy;
    final start = Offset(
      rect.left + LiquidFloatingNavBar.sideInset + itemWidth * 0.5,
      y,
    );
    // 2.1 items to the right: rounds to tab index 2.
    final end = Offset(
      rect.left + LiquidFloatingNavBar.sideInset + itemWidth * 2.1,
      y,
    );

    await tester.dragFrom(start, end - start);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the chosen material is persisted', (tester) async {
    final prefs = await pumpBar(tester, style: BottomBarStyle.frostedBlur);
    expect(await prefs.read('bottom_bar_style'), BottomBarStyle.frostedBlur.name);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(LiquidFloatingNavBar)),
    );
    await container.read(bottomBarStyleProvider.notifier).set(BottomBarStyle.solidCapsule);
    await tester.pump();

    expect(await prefs.read('bottom_bar_style'), BottomBarStyle.solidCapsule.name);
    expect(container.read(bottomBarStyleProvider), BottomBarStyle.solidCapsule);
  });
}
