import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../presentation/auth/auth_pages.dart';
import '../presentation/calendar/month_page.dart';
import '../presentation/calendar/week_page.dart';
import '../presentation/home_shell.dart';
import '../presentation/settings/courses_page.dart';
import '../presentation/settings/import_page.dart';
import '../presentation/settings/about_page.dart';
import '../presentation/settings/mcp_page.dart';
import '../presentation/settings/restore_page.dart';
import '../presentation/settings/schedules_page.dart';
import '../presentation/settings/server_page.dart';
import '../presentation/settings/settings_page.dart';
import '../presentation/settings/tags_page.dart';
import '../presentation/todo/todo_page.dart';
import '../state/session.dart';
import '../state/sync_controller.dart';
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
      return resolveAuthRedirect(
        phase: session.phase,
        authExpired: session.authExpired,
        location: state.matchedLocation,
      );
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
              path: '/home/month',
              pageBuilder: (context, state) => const MaterialPage(child: MonthPage()),
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
        pageBuilder: (context, state) => const MaterialPage(child: ConflictsPage()),
      ),
      GoRoute(
        path: '/settings/semesters',
        pageBuilder: (context, state) => const MaterialPage(child: SemestersPage()),
      ),
      GoRoute(
        path: '/settings/courses',
        pageBuilder: (context, state) => const MaterialPage(child: CoursesPage()),
      ),
      GoRoute(
        path: '/settings/schedules',
        pageBuilder: (context, state) => const MaterialPage(child: SchedulesPage()),
      ),
      GoRoute(
        path: '/settings/tags',
        pageBuilder: (context, state) => const MaterialPage(child: TagsPage()),
      ),
      GoRoute(
        path: '/settings/import',
        pageBuilder: (context, state) => const MaterialPage(child: ImportPage()),
      ),
      GoRoute(
        path: '/settings/server',
        pageBuilder: (context, state) => const MaterialPage(child: ServerPage()),
      ),
      GoRoute(
        path: '/settings/about',
        pageBuilder: (context, state) => const MaterialPage(child: AboutPage()),
      ),
      GoRoute(
        path: '/settings/mcp',
        pageBuilder: (context, state) => const MaterialPage(child: McpPage()),
      ),
      GoRoute(
        path: '/settings/restore',
        pageBuilder: (context, state) => const MaterialPage(child: RestorePage()),
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
@visibleForTesting
String? resolveAuthRedirect({
  required AuthPhase phase,
  required String location,
  bool authExpired = false,
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
  if (onAuthPage) return authExpired ? null : '/home/week';
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
    if (ref.read(sessionControllerProvider).phase != AuthPhase.signedIn) return;
    final coordinator = ref.read(syncCoordinatorProvider.notifier);
    // ignore: unawaited_futures
    coordinator.syncClock();
    // ignore: unawaited_futures
    coordinator.syncNow();
  }

  @override
  Widget build(BuildContext context) {
    // Push queued operations shortly after any local mutation lands.
    ref.listen(snapshotProvider, (previous, next) {
      final snapshot = next.value;
      if (snapshot == null || snapshot.pendingOps.isEmpty) return;
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
    return MaterialApp.router(
      title: 'Course Planner',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: scaffoldMessengerKey,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
