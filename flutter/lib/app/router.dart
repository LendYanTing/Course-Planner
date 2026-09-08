import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../presentation/auth/auth_pages.dart';
import '../presentation/calendar/month_page.dart';
import '../presentation/calendar/week_page.dart';
import '../presentation/home_shell.dart';
import '../presentation/settings/courses_page.dart';
import '../presentation/settings/import_page.dart';
import '../presentation/settings/schedules_page.dart';
import '../presentation/settings/settings_page.dart';
import '../presentation/settings/tags_page.dart';
import '../presentation/todo/todo_page.dart';
import '../state/session.dart';
import 'theme.dart';

/// Builds the GoRouter instance. Redirects are re-evaluated whenever
/// [sessionRevisionProvider] ticks (auth transitions).
final routerProvider = Provider<GoRouter>((ref) {
  final revision = ref.watch(sessionRevisionProvider);
  return GoRouter(
    refreshListenable: revision,
    initialLocation: '/',
    redirect: (context, state) {
      final phase = ref.read(sessionControllerProvider).phase;
      final location = state.matchedLocation;
      final onAuthPage = location == '/login' || location == '/register';
      if (phase == AuthPhase.unknown) {
        return location == '/' ? null : '/';
      }
      if (phase != AuthPhase.signedIn) {
        return onAuthPage ? null : '/login';
      }
      if (onAuthPage) return '/home/week';
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
    ],
  );
});

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

class _CoursePlannerAppState extends ConsumerState<CoursePlannerApp> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(sessionControllerProvider.notifier).bootstrap();
    });
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Course Planner',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      routerConfig: router,
    );
  }
}
