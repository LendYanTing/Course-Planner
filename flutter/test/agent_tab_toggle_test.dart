import 'package:course_planner/presentation/home_shell.dart';
import 'package:course_planner/presentation/settings/agent_settings_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// 设置 → 内置 AI 助手 → 在底栏显示 AI 助手, and the bottom-bar mapping it drives.
///
/// The shell's `StatefulNavigationShell` cannot be built outside go_router, so
/// the bar's items and its slot↔branch mapping are exercised through the pure
/// helpers [HomeShell] itself uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Lets the preference controllers' fire-and-forget restore settle.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('the assistant tab is visible by default', () async {
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(MemoryPrefs())],
    );
    addTearDown(container.dispose);

    final sub = container.listen(agentTabEnabledProvider, (_, _) {});
    expect(sub.read(), isTrue);
    await settle();
    expect(sub.read(), isTrue);
  });

  test('a stored "false" hides the assistant tab', () async {
    final container = ProviderContainer(
      overrides: [
        prefStoreProvider.overrideWithValue(
          MemoryPrefs(const {'agent_tab_enabled': 'false'}),
        ),
      ],
    );
    addTearDown(container.dispose);

    final sub = container.listen(agentTabEnabledProvider, (_, _) {});
    expect(sub.read(), isTrue); // default until the restore lands
    await settle();
    expect(sub.read(), isFalse);
  });

  test('toggling the switch persists the choice', () async {
    final prefs = MemoryPrefs();
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);

    await container.read(agentTabEnabledProvider.notifier).set(false);
    expect(container.read(agentTabEnabledProvider), isFalse);
    expect(await prefs.read('agent_tab_enabled'), 'false');

    await container.read(agentTabEnabledProvider.notifier).set(true);
    expect(container.read(agentTabEnabledProvider), isTrue);
    expect(await prefs.read('agent_tab_enabled'), 'true');
  });

  test('the bar keeps four tabs when the assistant is enabled', () {
    final items = homeNavItems(agentEnabled: true);
    expect(
      items.map((item) => item.label).toList(),
      ['日程', '待办', 'AI 助手', '设置'],
    );
    expect(homeNavIndexForBranch(homeBranchWeek, agentEnabled: true), 0);
    expect(homeNavIndexForBranch(homeBranchTodo, agentEnabled: true), 1);
    expect(homeNavIndexForBranch(homeBranchAgent, agentEnabled: true), 2);
    expect(homeNavIndexForBranch(homeBranchSettings, agentEnabled: true), 3);
    expect(homeBranchForNavIndex(2, agentEnabled: true), homeBranchAgent);
  });

  test('hiding the assistant drops one tab and remaps 设置 to slot 2', () {
    final items = homeNavItems(agentEnabled: false);
    expect(items.map((item) => item.label).toList(), ['日程', '待办', '设置']);

    // 设置 (branch 3) is now the third slot, so the bar never reports index 3.
    expect(homeNavIndexForBranch(homeBranchSettings, agentEnabled: false), 2);
    // The hidden branch has no slot: the shell uses this to fall back to 待办.
    expect(homeNavIndexForBranch(homeBranchAgent, agentEnabled: false), -1);
    expect(homeBranchForNavIndex(0, agentEnabled: false), homeBranchWeek);
    expect(homeBranchForNavIndex(1, agentEnabled: false), homeBranchTodo);
    expect(homeBranchForNavIndex(2, agentEnabled: false), homeBranchSettings);

    // A stale slot (e.g. the hidden 4th tab) clamps instead of throwing.
    expect(homeBranchForNavIndex(3, agentEnabled: false), homeBranchSettings);
  });

  testWidgets('the agent page switch hides the tab', (tester) async {
    final prefs = MemoryPrefs();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [prefStoreProvider.overrideWithValue(prefs)],
        child: const MaterialApp(home: AgentSettingsPage()),
      ),
    );
    await tester.pump();

    expect(find.text('在底栏显示 AI 助手'), findsOneWidget);
    expect(find.text('关闭后底栏只保留日程、待办、设置'), findsOneWidget);

    final container = ProviderScope.containerOf(
      tester.element(find.byType(AgentSettingsPage)),
    );
    expect(container.read(agentTabEnabledProvider), isTrue);

    await tester.tap(find.text('在底栏显示 AI 助手'));
    await tester.pump();

    final tile = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(tile.value, isFalse);
    expect(container.read(agentTabEnabledProvider), isFalse);
    expect(await prefs.read('agent_tab_enabled'), 'false');
  });
}
