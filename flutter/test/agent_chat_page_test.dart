import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/presentation/agent/agent_chat_page.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/presentation/widgets/app_markdown.dart';
import 'package:course_planner/presentation/widgets/liquid_floating_nav_bar.dart';
import 'package:course_planner/state/agent_controller.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/providers.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';
import 'helpers/week_page_harness.dart' show FakeSession;

/// The agent's own bottom-bar tab (phase 9 Step 2): top bar actions, Markdown
/// rendering in assistant bubbles, input clearance above the floating bar, and
/// the removal of the old to-do-page shortcut.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// A controller pre-loaded with a transcript, so the bubbles render without
  /// touching the network or the local data graph.
  ProviderContainer containerWithPrefs({AgentState? seed}) {
    final container = ProviderContainer(
      overrides: [
        prefStoreProvider.overrideWithValue(MemoryPrefs()),
        if (seed != null)
          agentControllerProvider.overrideWith(
            () => _SeededAgentController(seed),
          ),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget app(
    ProviderContainer container,
    Widget home, {
    EdgeInsets padding = EdgeInsets.zero,
  }) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.light(),
        home: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context).copyWith(padding: padding),
            child: home,
          ),
        ),
      ),
    );
  }

  void useSurface(WidgetTester tester, Size size) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
  }

  group('AgentChatPage', () {
    testWidgets('shows the title, both top-bar actions and the input', (
      tester,
    ) async {
      final container = containerWithPrefs();
      await tester.pumpWidget(app(container, const AgentChatPage()));
      await tester.pump();

      expect(find.text('AI 助手'), findsOneWidget);
      expect(find.byTooltip('清空对话'), findsOneWidget);
      expect(find.byTooltip('AI 设置'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(find.byTooltip('发送'), findsOneWidget);
      // Unconfigured: the guide explains why the input is disabled.
      expect(find.text('尚未配置大模型'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders assistant replies through the Markdown widget', (
      tester,
    ) async {
      useSurface(tester, const Size(360, 640));
      final container = containerWithPrefs(
        seed: const AgentState(
          messages: [
            AgentMessage(
              role: AgentRole.assistant,
              text: '**本周重点**\n- 周一：高数\n- 周三：物理',
            ),
          ],
        ),
      );
      await tester.pumpWidget(app(container, const AgentChatPage()));
      await tester.pump();

      expect(find.byType(AppMarkdownContent), findsOneWidget);
      // No raw markers survive the parser.
      expect(find.textContaining('**', findRichText: true), findsNothing);
      expect(find.textContaining('本周重点', findRichText: true), findsWidgets);
      expect(find.textContaining('周一：高数', findRichText: true), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('clearing the conversation confirms first, then resets', (
      tester,
    ) async {
      useSurface(tester, const Size(360, 640));
      final container = containerWithPrefs(
        seed: const AgentState(
          messages: [AgentMessage(role: AgentRole.assistant, text: '旧回复')],
        ),
      );
      await tester.pumpWidget(app(container, const AgentChatPage()));
      await tester.pump();

      await tester.tap(find.byTooltip('清空对话'));
      await tester.pumpAndSettle();
      expect(
        find.text('清空后将无法恢复本次对话；尚未确认的修改也会一并丢弃。'),
        findsOneWidget,
      );

      await tester.tap(find.widgetWithText(FilledButton, '清空'));
      await tester.pumpAndSettle();

      expect(container.read(agentControllerProvider).messages, isEmpty);
      expect(find.textContaining('你好，我是 Course Planner'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('keeps the input above the floating nav bar at 360x640', (
      tester,
    ) async {
      useSurface(tester, const Size(360, 640));
      const safeBottom = 24.0;
      // The shell's Scaffold(extendBody: true) folds the whole bar into
      // MediaQuery.padding.bottom; simulate that here.
      const barHeight = safeBottom +
          LiquidFloatingNavBar.bottomGap +
          LiquidFloatingNavBar.capsuleHeight;
      final container = containerWithPrefs();

      await tester.pumpWidget(
        app(
          container,
          const AgentChatPage(),
          padding: const EdgeInsets.only(bottom: barHeight),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);

      final input = tester.getRect(find.byType(TextField));
      // The capsule's top edge, measured from the screen bottom.
      final barTop = 640 -
          safeBottom -
          LiquidFloatingNavBar.bottomGap -
          LiquidFloatingNavBar.capsuleHeight;
      expect(input.bottom, lessThan(barTop));
      expect(
        640 - input.bottom,
        greaterThanOrEqualTo(barHeight + AgentChatPage.navBarClearance),
      );
    });
  });

  group('TodoPage', () {
    testWidgets('no longer carries an AI shortcut in its top bar', (
      tester,
    ) async {
      useSurface(tester, const Size(360, 640));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            prefStoreProvider.overrideWithValue(MemoryPrefs()),
            sessionControllerProvider.overrideWith(FakeSession.new),
            userTimeProvider.overrideWithValue(
              UserTime.tryCreate('Asia/Shanghai')!,
            ),
            snapshotProvider.overrideWith(
              (ref) => Stream.value(
                const EntitiesSnapshot(
                  rows: [],
                  pendingOps: [],
                  conflicts: [],
                ),
              ),
            ),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const TodoPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byType(TodoPage),
          matching: find.byIcon(Icons.auto_awesome),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(TodoPage),
          matching: find.byTooltip('AI 助手'),
        ),
        findsNothing,
      );
    });
  });
}

/// [AgentController] with a fixed transcript: no request is ever started.
class _SeededAgentController extends AgentController {
  _SeededAgentController(this.seed);

  final AgentState seed;

  @override
  AgentState build() => seed;
}
