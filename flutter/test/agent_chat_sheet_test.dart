import 'package:course_planner/agent/agent_config.dart';
import 'package:course_planner/agent/agent_prompts.dart';
import 'package:course_planner/agent/local_agent_tools.dart';
import 'package:course_planner/app/theme.dart';
import 'package:course_planner/presentation/agent/agent_chat_sheet.dart';
import 'package:course_planner/presentation/settings/agent_settings_page.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Built-in agent UI (phase 5 Step 4): the chat sheet's unconfigured guide,
/// the Change Set confirmation card, and the settings form.
///
/// No network is touched: the configured chat test only asserts that the input
/// becomes usable and that the quick prompts exist — tapping a chip would run
/// the real [AgentController] loop past its configuration check.
void main() {
  ProviderContainer containerWithPrefs() {
    final container = ProviderContainer(
      overrides: [prefStoreProvider.overrideWithValue(MemoryPrefs())],
    );
    addTearDown(container.dispose);
    return container;
  }

  Widget app(ProviderContainer container, Widget home) {
    return UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: AppTheme.light(), home: home),
    );
  }

  void useTallSurface(WidgetTester tester) {
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1000, 2400);
    addTearDown(tester.view.reset);
  }

  group('AgentChatSheet', () {
    testWidgets('shows the setup guide and disables sending without a key', (
      tester,
    ) async {
      final container = containerWithPrefs();
      await tester.pumpWidget(
        app(container, const Scaffold(body: AgentChatSheet())),
      );
      await tester.pump();

      expect(find.text('尚未配置大模型'), findsOneWidget);
      expect(find.text('去配置'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      // Quick prompts stay visible (why the sheet is useful) but cannot run.
      expect(find.byType(ActionChip), findsNWidgets(kAgentQuickPrompts.length));
      final chip = tester.widget<ActionChip>(find.byType(ActionChip).first);
      expect(chip.onPressed, isNull);
    });

    testWidgets('enables the input once a key and model are configured', (
      tester,
    ) async {
      final container = containerWithPrefs();
      final notifier = container.read(agentConfigProvider.notifier);
      await notifier.setPreset('deepseek');
      await notifier.setKey('k');

      await tester.pumpWidget(
        app(container, const Scaffold(body: AgentChatSheet())),
      );
      await tester.pump();

      expect(container.read(agentConfigProvider).isConfigured, isTrue);
      expect(find.text('尚未配置大模型'), findsNothing);
      expect(find.text('去配置'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
      for (final prompt in kAgentQuickPrompts) {
        expect(find.text(prompt), findsOneWidget);
      }
      final chip = tester.widget<ActionChip>(find.byType(ActionChip).first);
      expect(chip.onPressed, isNotNull);
    });
  });

  group('ChangeSetConfirmationCard', () {
    LocalChangeSet changeSet() => LocalChangeSet(
      createdAt: DateTime(2026, 1, 1),
      items: const [
        LocalChangeItem(kind: 'create_todo_block', summary: '新增时间块：生化大作业 1'),
        LocalChangeItem(kind: 'update_todo', summary: '修改待办：高等数学作业'),
        LocalChangeItem(
          kind: 'move_course_occurrence',
          summary: '移动课程：高等数学 → 周四第 3 节',
          conflictWarning: '⚠️ 与课程「大学物理」时间冲突',
        ),
        LocalChangeItem(kind: 'delete_todo', summary: '删除待办：旧任务'),
      ],
    );

    testWidgets('lists each change with a badge and conflict warning', (
      tester,
    ) async {
      useTallSurface(tester);
      var cancelled = 0;
      var confirmed = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChangeSetConfirmationCard(
                changeSet: changeSet(),
                onCancel: () => cancelled++,
                onConfirm: () => confirmed++,
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('共 4 项'), findsOneWidget);
      // create → +, update/move → ~ (two), delete → -.
      expect(find.text('+'), findsOneWidget);
      expect(find.text('~'), findsNWidgets(2));
      expect(find.text('-'), findsOneWidget);
      expect(find.textContaining('时间冲突'), findsOneWidget);

      await tester.tap(find.text('全部确认'));
      expect(confirmed, 1);
      await tester.tap(find.text('取消'));
      expect(cancelled, 1);
    });

    testWidgets('disables both actions while the set is being applied', (
      tester,
    ) async {
      useTallSurface(tester);
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: ChangeSetConfirmationCard(
              changeSet: changeSet(),
              busy: true,
              onCancel: () {},
              onConfirm: () {},
            ),
          ),
        ),
      );

      expect(tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed, isNull);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    });
  });

  group('AgentSettingsPage', () {
    testWidgets('renders every preset, field and the temperature slider', (
      tester,
    ) async {
      useTallSurface(tester);
      final container = containerWithPrefs();
      await tester.pumpWidget(app(container, const AgentSettingsPage()));
      await tester.pump();
      await tester.pump();

      expect(find.byType(ChoiceChip), findsNWidgets(kLlmPresets.length));
      for (final label in [
        'DeepSeek',
        '硅基流动 SiliconFlow',
        '通义千问 DashScope',
        'OpenAI',
        '本地 Ollama',
        '自定义接口',
      ]) {
        expect(find.text(label), findsOneWidget, reason: 'missing preset $label');
      }
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.text('模型名称'), findsOneWidget);
      expect(find.text('API Key'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('语音识别（ASR）'), findsOneWidget);
      expect(find.textContaining('本机安全存储'), findsOneWidget);
    });

    testWidgets('switching a preset rewrites the base URL and model', (
      tester,
    ) async {
      useTallSurface(tester);
      final container = containerWithPrefs();
      await tester.pumpWidget(app(container, const AgentSettingsPage()));
      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('OpenAI'));
      await tester.pumpAndSettle();

      final config = container.read(agentConfigProvider);
      expect(config.presetId, 'openai');
      expect(config.baseUrl, 'https://api.openai.com/v1');
      expect(config.model, 'gpt-4o-mini');
      // The fields follow the provider (they are not focused).
      expect(find.text('https://api.openai.com/v1'), findsOneWidget);
      expect(find.text('gpt-4o-mini'), findsOneWidget);
    });
  });
}
