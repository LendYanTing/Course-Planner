import 'package:course_planner/data/api/http_client.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/presentation/settings/appearance_settings_page.dart';
import 'package:course_planner/presentation/settings/course_settings_page.dart';
import 'package:course_planner/presentation/settings/settings_page.dart';
import 'package:course_planner/presentation/settings/sync_settings_page.dart';
import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'helpers/memory_prefs.dart';

/// No-account session: the settings hub then shows the local status card and a
/// "登录云端账号" row. Signing out lives on the sync page and only appears for a
/// cloud account.
class _LocalSession extends SessionController {
  @override
  SessionState build() => const SessionState(
        phase: AuthPhase.signedIn,
        profile: SessionProfile(
          userId: SessionState.localUserId,
          username: '本地用户',
          timezone: 'Asia/Shanghai',
        ),
      );
}

/// Cloud session with automatic sync switched on.
class _CloudSession extends SessionController {
  @override
  SessionState build() => const SessionState(
        phase: AuthPhase.signedIn,
        profile: SessionProfile(
          userId: 'u1',
          username: 'webdev',
          timezone: 'Asia/Shanghai',
        ),
      );
}

/// Set by [_RecordingCloudSession]: the real `logout()` would need the whole
/// service graph (token box, auth API), which these tests deliberately lack.
bool _logoutCalled = false;

class _RecordingCloudSession extends SessionController {
  @override
  SessionState build() => const SessionState(
        phase: AuthPhase.signedIn,
        profile: SessionProfile(
          userId: 'u1',
          username: 'webdev',
          timezone: 'Asia/Shanghai',
        ),
      );

  @override
  Future<void> logout() async => _logoutCalled = true;
}

/// Minimal [AppServices] stand-in: the sync page only needs `http.baseUrl` to
/// render. Every other member throws if touched, so an accidental dependency
/// fails loudly.
class _FakeServices implements AppServices {
  _FakeServices()
      : http = ApiHttp.create(
          onRefresh: () async => false,
          baseUrl: 'http://localhost:8080/api/v1',
        );

  @override
  final ApiHttp http;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _emptySnapshot = EntitiesSnapshot(
  rows: [],
  pendingOps: [],
  conflicts: [],
);

/// Wraps [home] (or [router]) in a scope with the minimum providers the
/// settings pages need. Riverpod 3 keeps `Override` private, so the list is
/// built inline here instead of in a typed helper.
Widget _app({
  required SessionController Function() session,
  Widget? home,
  GoRouter? router,
  Map<String, String>? prefs,
  AppServices? services,
}) {
  return ProviderScope(
    overrides: [
      prefStoreProvider.overrideWithValue(MemoryPrefs(prefs)),
      snapshotProvider.overrideWith((ref) => Stream.value(_emptySnapshot)),
      sessionControllerProvider.overrideWith(session),
      if (services != null) servicesProvider.overrideWithValue(services),
    ],
    child: router == null
        ? MaterialApp(home: home)
        : MaterialApp.router(routerConfig: router),
  );
}

/// A tall surface keeps every settings row built, so plain `find.text`
/// assertions do not depend on the scroll offset.
void _useTallSurface(WidgetTester tester) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1200, 2600);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('settings hub groups its entries into five cards (local mode)',
      (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _app(session: _LocalSession.new, home: const SettingsPage()),
    );
    await tester.pump();
    await tester.pump();

    // Status card: a local profile with an editable timezone.
    expect(find.text('本地用户'), findsOneWidget);
    expect(find.textContaining('数据保存在本机'), findsWidgets);

    // The five category headers. 课程与学期 is both the group label and the
    // single row that opens the second-level page, so it appears twice.
    for (final title in [
      '外观与个性化',
      'AI 助手与连接',
      '数据与云同步',
      '关于',
    ]) {
      expect(find.text(title), findsOneWidget, reason: 'missing group $title');
    }
    expect(find.text('课程与学期'), findsNWidgets(2));

    // Every destination still reachable from the hub (the course sub-pages now
    // live one level down).
    for (final entry in [
      '标签与分类',
      '外观与课表定制',
      '连接到 MCP',
      '云同步与服务器',
      '导出完整备份',
      '导入/恢复备份',
      '关于 Course Planner',
    ]) {
      expect(find.text(entry), findsOneWidget, reason: 'missing row $entry');
    }
    expect(find.text('学期、课程、周期安排与导入'), findsOneWidget);

    // The course sub-pages are no longer rows of the hub itself.
    for (final moved in [
      '学期管理',
      '课程管理',
      '周期安排',
      '导入课程',
      '从教务系统导入',
    ]) {
      expect(find.text(moved), findsNothing, reason: '$moved still on the hub');
    }

    // Local mode: no cloud-sync switch, and the sign-in row without logout.
    expect(find.text('自动云同步'), findsNothing);
    expect(find.text('登录云端账号'), findsOneWidget);
    expect(find.text('退出登录'), findsNothing);
    expect(find.text('Course Planner · Flutter'), findsOneWidget);

    // Migrated rows must not be duplicated on the hub.
    expect(find.text('中午分界点'), findsNothing);
    expect(find.text('重置网络连接'), findsNothing);
    expect(find.text('硬刷新本地缓存'), findsNothing);
  });

  testWidgets('cloud account hub shows the sync state without logout',
      (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _app(
        session: _CloudSession.new,
        home: const SettingsPage(),
        // Cloud sync on, so the state line reads "云同步：开".
        prefs: const {'sync_enabled': 'true'},
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('云同步：开'), findsOneWidget);
    // Signing out moved to the sync page, whichever the account type.
    expect(find.text('退出登录'), findsNothing);
    expect(find.text('登录云端账号'), findsNothing);
  });

  testWidgets('cloud sync page offers logout behind a confirmation',
      (tester) async {
    _useTallSurface(tester);
    _logoutCalled = false;
    await tester.pumpWidget(
      _app(
        session: _RecordingCloudSession.new,
        home: const SyncSettingsPage(),
        services: _FakeServices(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('退出登录'), findsOneWidget);

    // The dialog names the consequence before anything is dropped.
    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录？'), findsOneWidget);
    expect(find.textContaining('本地数据会保留'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录？'), findsNothing);
    expect(_logoutCalled, isFalse);

    await tester.tap(find.text('退出登录'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('退出'));
    await tester.pumpAndSettle();
    expect(_logoutCalled, isTrue);
  });

  testWidgets('appearance page hosts every look-and-feel row', (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _app(session: _LocalSession.new, home: const AppearanceSettingsPage()),
    );
    await tester.pump();

    expect(find.text('外观与课表定制'), findsOneWidget);
    for (final row in [
      '界面风格引擎',
      '底栏外观',
      '课表文字行数',
      '月视图格子高度',
      '中午分界点',
    ]) {
      expect(find.text(row), findsOneWidget, reason: 'missing appearance row $row');
    }
  });

  testWidgets('sync page shows a local session without sync controls',
      (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(
      _app(
        session: _LocalSession.new,
        home: const SyncSettingsPage(),
        services: _FakeServices(),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('云同步与服务器'), findsOneWidget);
    expect(find.text('本地模式'), findsOneWidget);
    expect(find.text('数据保存在本机'), findsWidgets);
    expect(find.text('登录云端账号'), findsOneWidget);
    expect(find.text('服务器'), findsOneWidget);
    expect(find.text('http://localhost:8080/api/v1'), findsOneWidget);

    // No cloud-only controls for a server-less session.
    expect(find.text('自动云同步'), findsNothing);
    expect(find.text('立即同步'), findsNothing);
    expect(find.text('冲突处理'), findsNothing);
    expect(find.text('重置网络连接'), findsNothing);
    // Nothing to sign out of without an account.
    expect(find.text('退出登录'), findsNothing);
  });

  testWidgets('hub pushes to the appearance page', (tester) async {
    _useTallSurface(tester);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/settings/appearance',
          builder: (context, state) => const AppearanceSettingsPage(),
        ),
      ],
    );
    await tester.pumpWidget(
      _app(session: _LocalSession.new, router: router),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('外观与课表定制'));
    await tester.pumpAndSettle();

    // Only the pushed page carries these rows; the hub is offstage behind it.
    expect(find.text('界面风格引擎'), findsOneWidget);
    expect(find.text('中午分界点'), findsOneWidget);
    expect(find.text('外观与课表定制'), findsWidgets);
  });

  testWidgets('the course entry opens the course & semester page',
      (tester) async {
    _useTallSurface(tester);
    final router = GoRouter(
      initialLocation: '/settings',
      routes: [
        GoRoute(
          path: '/settings',
          builder: (context, state) => const SettingsPage(),
        ),
        GoRoute(
          path: '/settings/course-hub',
          builder: (context, state) => const CourseSettingsPage(),
        ),
      ],
    );
    await tester.pumpWidget(
      _app(session: _LocalSession.new, router: router),
    );
    await tester.pump();
    await tester.pump();

    // The hub row, not the group label above it.
    await tester.tap(find.widgetWithText(ListTile, '课程与学期'));
    await tester.pumpAndSettle();

    expect(find.text('课程与学期'), findsOneWidget); // the page title
    for (final entry in [
      '学期管理',
      '课程管理',
      '周期安排',
      '导入课程',
      '从教务系统导入',
    ]) {
      expect(find.text(entry), findsOneWidget, reason: 'missing $entry');
    }
  });
}
