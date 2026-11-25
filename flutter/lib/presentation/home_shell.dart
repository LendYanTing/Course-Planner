import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../state/sync_controller.dart';
import 'widgets/liquid_floating_nav_bar.dart';

/// Home shell with bottom navigation: Week / Month / Todo / Settings
/// (agents/flutter-agent.md §页面). Driven by a go_router
/// [StatefulShellRoute.indexedStack] so each tab keeps its own state.
///
/// The bottom is a floating glass bar, hence `extendBody`: pages show through
/// behind it and reserve the bottom room themselves via `MediaQuery`.
class HomeShell extends StatelessWidget {
  const HomeShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBody: true,
      body: navigationShell,
      bottomNavigationBar: LiquidFloatingNavBar(
        currentIndex: navigationShell.currentIndex,
        items: const [
          LiquidNavItem(
            icon: Icons.view_week_outlined,
            selectedIcon: Icons.view_week,
            label: '周视图',
          ),
          LiquidNavItem(
            icon: Icons.calendar_month_outlined,
            selectedIcon: Icons.calendar_month,
            label: '月视图',
          ),
          LiquidNavItem(
            icon: Icons.checklist_outlined,
            selectedIcon: Icons.checklist,
            label: '待办',
          ),
          LiquidNavItem(
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: '设置',
          ),
        ],
        onSelected: (index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        ),
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
