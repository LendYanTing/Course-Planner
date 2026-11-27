import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/prefs.dart';
import '../state/sync_controller.dart';
import 'widgets/liquid_floating_nav_bar.dart';

/// Branch indices of the shell route: 0 日程, 1 待办, 2 AI 助手, 3 设置.
///
/// The assistant branch stays registered even when its tab is hidden, so the
/// numbers never shift; only the bottom-bar slots do.
const homeBranchWeek = 0;
const homeBranchTodo = 1;
const homeBranchAgent = 2;
const homeBranchSettings = 3;

/// Router branches shown in the bottom bar, in order.
///
/// With the assistant hidden the bar keeps 日程 / 待办 / 设置, so every slot
/// after 待办 maps to a different branch than its slot number.
List<int> homeNavBranches({required bool agentEnabled}) =>
    agentEnabled ? const [0, 1, 2, 3] : const [0, 1, 3];

const _navItemsByBranch = <int, LiquidNavItem>{
  homeBranchWeek: LiquidNavItem(
    icon: Icons.calendar_today_outlined,
    selectedIcon: Icons.calendar_today,
    label: '日程',
  ),
  homeBranchTodo: LiquidNavItem(
    icon: Icons.checklist_outlined,
    selectedIcon: Icons.checklist,
    label: '待办',
  ),
  homeBranchAgent: LiquidNavItem(
    icon: Icons.auto_awesome_outlined,
    selectedIcon: Icons.auto_awesome,
    label: 'AI 助手',
  ),
  homeBranchSettings: LiquidNavItem(
    icon: Icons.settings_outlined,
    selectedIcon: Icons.settings,
    label: '设置',
  ),
};

/// Bottom-bar items for the current visibility setting.
List<LiquidNavItem> homeNavItems({required bool agentEnabled}) => [
      for (final branch in homeNavBranches(agentEnabled: agentEnabled))
        _navItemsByBranch[branch]!,
    ];

/// Bottom-bar slot that shows [branch], or -1 when that branch has no slot
/// (the hidden assistant branch).
int homeNavIndexForBranch(int branch, {required bool agentEnabled}) =>
    homeNavBranches(agentEnabled: agentEnabled).indexOf(branch);

/// Router branch a bottom-bar slot points at; out-of-range slots clamp.
int homeBranchForNavIndex(int index, {required bool agentEnabled}) {
  final branches = homeNavBranches(agentEnabled: agentEnabled);
  return branches[index.clamp(0, branches.length - 1)];
}

/// Home shell with bottom navigation: 日程 / 待办 / AI 助手 / 设置
/// (agents/flutter-agent.md §页面). Driven by a go_router
/// [StatefulShellRoute.indexedStack] so each tab keeps its own state.
///
/// The bottom is a floating glass bar, hence `extendBody`: pages show through
/// behind it and reserve the bottom room themselves via `MediaQuery`.
///
/// 设置 → 内置 AI 助手 can hide the assistant tab ([agentTabEnabledProvider]);
/// the branch is then unreachable from the bar but keeps its route.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final agentEnabled = ref.watch(agentTabEnabledProvider);
    final branchIndex = navigationShell.currentIndex;
    var navIndex = homeNavIndexForBranch(
      branchIndex,
      agentEnabled: agentEnabled,
    );
    if (navIndex < 0) {
      // The assistant tab was hidden while it was on screen: show 待办 as the
      // selection for this frame and switch branches right after the frame, so
      // the bar never reports an index it does not have.
      navIndex = homeNavIndexForBranch(
        homeBranchTodo,
        agentEnabled: agentEnabled,
      );
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        navigationShell.goBranch(homeBranchTodo);
      });
    }

    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: LiquidFloatingNavBar(
        currentIndex: navIndex,
        items: homeNavItems(agentEnabled: agentEnabled),
        onSelected: (index) {
          final branch = homeBranchForNavIndex(
            index,
            agentEnabled: agentEnabled,
          );
          navigationShell.goBranch(
            branch,
            initialLocation: branch == branchIndex,
          );
        },
      ),
    );
  }
}

/// Shared AppBar sync action (used by tab pages).
class SyncBadge extends ConsumerWidget {
  const SyncBadge({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only a cloud account with sync enabled has anything to sync; a local
    // session keeps the action out of the UI entirely.
    if (!ref.watch(cloudSyncEnabledProvider)) return const SizedBox.shrink();
    final sync = ref.watch(syncCoordinatorProvider);
    return IconButton(
      tooltip: '同步',
      onPressed: sync.syncing
          ? null
          : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
      icon: sync.syncing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.sync),
    );
  }
}
