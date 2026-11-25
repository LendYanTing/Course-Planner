import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../presentation/auth/auth_pages.dart';
import '../presentation/calendar/week_page.dart';
import '../presentation/home_shell.dart';
import '../presentation/settings/agent_settings_page.dart';
import '../presentation/settings/appearance_settings_page.dart';
import '../presentation/settings/courses_page.dart';
import '../presentation/settings/edu_import_page.dart';
import '../presentation/settings/import_page.dart';
import '../presentation/settings/about_page.dart';
import '../presentation/settings/mcp_page.dart';
import '../presentation/settings/restore_page.dart';
import '../presentation/settings/schedules_page.dart';
import '../presentation/settings/server_page.dart';
import '../presentation/settings/settings_page.dart';
import '../presentation/settings/sync_settings_page.dart';
import '../presentation/settings/tags_page.dart';
import '../presentation/todo/todo_page.dart';
import '../state/prefs.dart';
import '../state/session.dart';
import '../state/sync_controller.dart';
import 'adaptive_page.dart';
import 'theme.dart';

/// Root [ScaffoldMessenger] key: the session-expired toast is raised from the
/// app root (there is no page context at the moment the server rejects the
/// token).
final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Builds the GoRouter instance. Redirects are re-evaluated whenever
/// [sessionRevisionProvider] ticks (auth transitions).
final routerProvider = Provider<GoRouter>((ref) {
  final revision = ref.watch(sessionRevisionProvider);
  return GoRouter(
    refreshListenable: revision,
    initialLocation: '/',
    redirect: (context, state) {
      final session = ref.read(sessionControllerProvider);
      final authRedirect = resolveAuthRedirect(
        phase: session.phase,
        authExpired: session.authExpired,
        isLocalMode: session.isLocalMode,
        location: state.matchedLocation,
      );
      if (authRedirect != null) return authRedirect;
      // 月视图 no longer has its own tab. Old links (and shelf state restored
      // from a previous version) still ask for it: switch the 日程 page to its
      // month mode and land there instead of hitting an unmatched route.
      if (state.matchedLocation == '/home/month') {
        // ignore: unawaited_futures
        ref.read(weekViewModeProvider.notifier).set(WeekViewModeController.month);
        return '/home/week';
      }
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const _SplashPage(),
      ),
      GoRoute(
        path: '/login',
        pageBuilder: (context, state) => const MaterialPage(child: LoginPage()),
      ),
      GoRoute(
        path: '/register',
        pageBuilder: (context, state) => const MaterialPage(child: RegisterPage()),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            HomeShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/week',
              pageBuilder: (context, state) => const MaterialPage(child: WeekPage()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/todo',
              pageBuilder: (context, state) => const MaterialPage(child: TodoPage()),
            ),
          ]),
          StatefulShellBranch(routes: [
            GoRoute(
              path: '/home/settings',
              pageBuilder: (context, state) => const MaterialPage(child: SettingsPage()),
            ),
          ]),
        ],
      ),
      GoRoute(
        path: '/settings/conflicts',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const ConflictsPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/appearance',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const AppearanceSettingsPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/sync',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const SyncSettingsPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/semesters',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const SemestersPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/courses',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const CoursesPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/schedules',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const SchedulesPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/tags',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const TagsPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/import',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const ImportPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/edu-import',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const EduImportPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/server',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const ServerPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/about',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const AboutPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/agent',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const AgentSettingsPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/mcp',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const McpPage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
      GoRoute(
        path: '/settings/restore',
        pageBuilder: (context, state) => buildAdaptivePage(
          key: state.pageKey,
          child: const RestorePage(),
          variant: ref.read(uiVariantProvider),
        ),
      ),
    ],
  );
});

/// Pure auth-aware redirect decision (kept out of the provider so it is
/// unit-testable). Returns the location to navigate to, or `null` to stay.
///
/// [authExpired] means the stored credentials were rejected but the session is
/// intentionally kept alive for local viewing: the login page then stays
/// reachable (so the user can re-authenticate from the toast / settings) while
/// every other location remains available.
///
/// [isLocalMode] marks the no-account local session: it may freely open
/// `/login` and `/register` to add a cloud account later, and every other page
/// is available just like for a signed-in user.
@visibleForTesting
String? resolveAuthRedirect({
  required AuthPhase phase,
  required String location,
  bool authExpired = false,
  bool isLocalMode = false,
}) {
  final onAuthPage = location == '/login' || location == '/register';
  if (phase == AuthPhase.unknown) {
    return location == '/' ? null : '/';
  }
  if (phase != AuthPhase.signedIn) {
    return onAuthPage ? null : '/login';
  }
  // A signed-in user never belongs on the splash or auth pages. A cached
  // profile restart boots at '/' while already signed in — without this the
  // splash spinner would never leave (/home/week on auth pages was already
  // handled, but '/' was not).
  if (onAuthPage) return (authExpired || isLocalMode) ? null : '/home/week';
  if (location == '/') return '/home/week';
  return null;
}

class _SplashPage extends StatelessWidget {
  const _SplashPage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Course Planner'),
          ],
        ),
      ),
    );
  }
}

/// Root widget: triggers session bootstrap once, then hosts the router.
class CoursePlannerApp extends ConsumerStatefulWidget {
  const CoursePlannerApp({super.key});

  @override
  ConsumerState<CoursePlannerApp> createState() => _CoursePlannerAppState();
}

class _CoursePlannerAppState extends ConsumerState<CoursePlannerApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionControllerProvider.notifier).bootstrap();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Android suspends timers in the background, so the once-a-minute ticker
  /// behind the current-time line can be hours stale on return. Re-read the
  /// server clock (the device clock may also have moved) and catch up.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    final session = ref.read(sessionControllerProvider);
    if (session.phase != AuthPhase.signedIn) return;
    // No server for a local session, and an opted-out account stays offline.
    if (session.isLocalMode || !ref.read(syncEnabledProvider)) return;
    final coordinator = ref.read(syncCoordinatorProvider.notifier);
    // ignore: unawaited_futures
    coordinator.syncClock();
    // ignore: unawaited_futures
    coordinator.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    // Push queued operations shortly after any local mutation lands — only for
    // a cloud account that left automatic sync on.
    ref.listen(snapshotProvider, (previous, next) {
      final snapshot = next.value;
      if (snapshot == null || snapshot.pendingOps.isEmpty) return;
      final session = ref.read(sessionControllerProvider);
      if (!ref.read(syncEnabledProvider) || session.isLocalMode) return;
      ref.read(syncCoordinatorProvider.notifier).schedulePush();
    });
    // Expired credentials must not kick the user out: warn once, keep the
    // content on screen, and offer the way back in.
    ref.listen<SessionState>(sessionControllerProvider, (previous, next) {
      if (!next.authExpired) return;
      if (previous?.authExpired ?? false) return;
      scaffoldMessengerKey.currentState?.showSnackBar(
        SnackBar(
          content: const Text(
            '登录已过期：本地内容仍可查看，重新登录后未同步的修改会自动上传。',
          ),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: '重新登录',
            onPressed: () => ref.read(routerProvider).go('/login'),
          ),
        ),
      );
    });
    final router = ref.watch(routerProvider);
    final variant = ref.watch(uiVariantProvider);
    final themeConfig = ref.watch(themeConfigProvider);
    final background = ref.watch(backgroundConfigProvider);
    // Monet only reads local image files; a built-in gradient preset has no
    // decodable file, so it keeps the seed scheme.
    final monetPath = themeConfig.useWallpaperMonet
        ? (background.imagePath ?? '')
        : '';
    // A null value means "extraction still running or failed": fall back to
    // the seeded scheme, then swap once the wallpaper colours arrive.
    final lightWallpaper = monetPath.isEmpty
        ? null
        : ref
            .watch(wallpaperColorSchemeProvider(
              (path: monetPath, brightness: Brightness.light),
            ))
            .value;
    final darkWallpaper = monetPath.isEmpty
        ? null
        : ref
            .watch(wallpaperColorSchemeProvider(
              (path: monetPath, brightness: Brightness.dark),
            ))
            .value;
    final lightScheme = lightWallpaper ??
        ref.watch(seedColorSchemeProvider(
          (hex: themeConfig.seedColorHex, brightness: Brightness.light),
        ));
    final darkScheme = darkWallpaper ??
        ref.watch(seedColorSchemeProvider(
          (hex: themeConfig.seedColorHex, brightness: Brightness.dark),
        ));
    return MaterialApp.router(
      title: 'Course Planner',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: AppTheme.light(variant, lightScheme),
      darkTheme: AppTheme.dark(variant, darkScheme),
      themeMode: themeConfig.mode,
      themeAnimationDuration: const Duration(milliseconds: 280),
      themeAnimationCurve: Curves.easeInOutCubicEmphasized,
      routerConfig: router,
    );
  }
}
