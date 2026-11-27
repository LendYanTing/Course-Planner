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
    LiquidNavItem(icon: Icons.calendar_today_outlined, selectedIcon: Icons.calendar_today, label: '日程'),
    LiquidNavItem(icon: Icons.checklist_outlined, selectedIcon: Icons.checklist, label: '待办'),
    LiquidNavItem(icon: Icons.auto_awesome_outlined, selectedIcon: Icons.auto_awesome, label: 'AI 助手'),
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

  /// Geometry of the capsule itself (the widget box is the full-width padding,
  /// while the capsule is capped at [LiquidFloatingNavBar.maxCapsuleWidth] and
  /// centred inside it).
  ({double left, double width}) capsuleGeometry(Rect barRect) {
    final available = barRect.width - LiquidFloatingNavBar.sideInset * 2;
    final width = available > LiquidFloatingNavBar.maxCapsuleWidth
        ? LiquidFloatingNavBar.maxCapsuleWidth
        : available;
    return (
      left: barRect.left +
          LiquidFloatingNavBar.sideInset +
          (available - width) / 2,
      width: width,
    );
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

  testWidgets('the capsule keeps its compact height', (tester) async {
    await pumpBar(tester);

    final rect = tester.getRect(find.byType(LiquidFloatingNavBar));
    expect(
      rect.height,
      LiquidFloatingNavBar.capsuleHeight + LiquidFloatingNavBar.bottomGap,
    );
    expect(capsuleGeometry(rect).width, LiquidFloatingNavBar.maxCapsuleWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping each tab reports its index', (tester) async {
    // The bar ignores taps on the already-selected tab, so every case starts
    // from a different index.
    for (var i = 1; i < items.length; i++) {
      int? selected;
      await pumpBar(tester, onSelected: (index) => selected = index);

      await tester.tap(find.text(items[i].label));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));

      expect(selected, i, reason: 'tapping ${items[i].label}');
      expect(tester.takeException(), isNull);
    }

    int? backToFirst;
    await pumpBar(tester, index: 2, onSelected: (index) => backToFirst = index);
    await tester.tap(find.text('日程'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(backToFirst, 0);
  });

  testWidgets('shows the filled icon only for the selected tab', (tester) async {
    await pumpBar(tester, index: 2);

    expect(find.byIcon(Icons.auto_awesome), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsNothing);
    expect(find.byIcon(Icons.calendar_today_outlined), findsOneWidget);
    expect(find.byIcon(Icons.calendar_today), findsNothing);

    await pumpBar(tester, index: 3);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(find.byIcon(Icons.auto_awesome_outlined), findsOneWidget);
    expect(find.byIcon(Icons.auto_awesome), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a horizontal drag lands on the nearest tab', (tester) async {
    int? selected;
    await pumpBar(tester, onSelected: (i) => selected = i);

    final rect = tester.getRect(find.byType(LiquidFloatingNavBar));
    final capsule = capsuleGeometry(rect);
    final itemWidth = capsule.width / items.length;
    final y = rect.center.dy;
    final start = Offset(capsule.left + itemWidth * 0.5, y);
    // Far right: rounds to the last tab.
    final end = Offset(capsule.left + capsule.width - 2, y);

    await tester.dragFrom(start, end - start);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(selected, items.length - 1);
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
