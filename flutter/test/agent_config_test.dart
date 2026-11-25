import 'dart:convert';

import 'package:course_planner/agent/agent_config.dart';
import 'package:course_planner/agent/agent_prompts.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// Built-in agent configuration + prompt construction (phase 5 Step 3).
/// No network is involved: [LlmClient] is deliberately left untested here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  /// Lets the controller's async `_restore()` finish before assertions.
  Future<void> settle() async {
    await pumpEventQueue();
  }

  ProviderContainer containerWith(MemoryPrefs prefs) => ProviderContainer(
    overrides: [prefStoreProvider.overrideWithValue(prefs)],
  );

  group('LlmConfig', () {
    const config = LlmConfig(
      presetId: 'openai',
      baseUrl: 'https://api.openai.com/v1',
      apiKey: 'sk-secret-value',
      model: 'gpt-4o-mini',
      temperature: 0.7,
      extraSystemPrompt: '回答尽量简短',
    );

    test('toJson omits the API key by default', () {
      final json = config.toJson();
      expect(json.containsKey('apiKey'), isFalse);
      expect(jsonEncode(json), isNot(contains('sk-secret-value')));
      expect(json['presetId'], 'openai');
      expect(json['baseUrl'], 'https://api.openai.com/v1');
      expect(json['model'], 'gpt-4o-mini');
      expect(json['temperature'], 0.7);
      expect(json['extraSystemPrompt'], '回答尽量简短');
    });

    test('fromJson round-trips with the key supplied separately', () {
      final restored = LlmConfig.fromJson(
        config.toJson(),
        apiKey: 'sk-secret-value',
      );
      expect(restored.presetId, config.presetId);
      expect(restored.baseUrl, config.baseUrl);
      expect(restored.model, config.model);
      expect(restored.temperature, config.temperature);
      expect(restored.extraSystemPrompt, config.extraSystemPrompt);
      expect(restored.apiKey, 'sk-secret-value');
    });

    test('includeKey exports the key only on request', () {
      expect(config.toJson(includeKey: true)['apiKey'], 'sk-secret-value');
    });

    test('isConfigured requires a key, a base URL and a model', () {
      expect(config.isConfigured, isTrue);
      expect(const LlmConfig().isConfigured, isFalse);
      expect(
        const LlmConfig(apiKey: '  ', model: 'm', baseUrl: 'u').isConfigured,
        isFalse,
      );
      expect(
        const LlmConfig(apiKey: 'k', model: '', baseUrl: 'u').isConfigured,
        isFalse,
      );
      expect(
        const LlmConfig(apiKey: 'k', model: 'm', baseUrl: ' ').isConfigured,
        isFalse,
      );
    });
  });

  group('AgentConfigController', () {
    test('defaults to DeepSeek without a key', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      container.read(agentConfigProvider);
      await settle();

      final config = container.read(agentConfigProvider);
      expect(config.presetId, 'deepseek');
      expect(config.baseUrl, 'https://api.deepseek.com');
      expect(config.model, 'deepseek-chat');
      expect(config.apiKey, '');
      expect(config.isConfigured, isFalse);
    });

    test('setPreset swaps endpoint/model and keeps the entered key', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      container.read(agentConfigProvider);
      await settle();
      final notifier = container.read(agentConfigProvider.notifier);

      await notifier.setKey('sk-keep-me');
      await notifier.setPreset('openai');

      final config = container.read(agentConfigProvider);
      expect(config.presetId, 'openai');
      expect(config.baseUrl, 'https://api.openai.com/v1');
      expect(config.model, 'gpt-4o-mini');
      expect(config.apiKey, 'sk-keep-me');
    });

    test(
      'setKey persists under its own key, not inside the config JSON',
      () async {
        final prefs = MemoryPrefs();
        final container = containerWith(prefs);
        addTearDown(container.dispose);

        container.read(agentConfigProvider);
        await settle();
        final notifier = container.read(agentConfigProvider.notifier);
        await notifier.setKey('sk-persisted');
        await notifier.setModel('deepseek-reasoner');
        await notifier.setTemperature(0.9);

        expect(
          await prefs.read(AgentConfigController.apiKeyKey),
          'sk-persisted',
        );
        final raw = await prefs.read(AgentConfigController.configKey);
        expect(raw, isNotNull);
        expect(raw!, isNot(contains('sk-persisted')));
        final json = jsonDecode(raw) as Map<String, dynamic>;
        expect(json['model'], 'deepseek-reasoner');
        expect(json['temperature'], 0.9);
        expect(json.containsKey('apiKey'), isFalse);
      },
    );

    test('a fresh container restores the persisted config and key', () async {
      final prefs = MemoryPrefs();
      final first = containerWith(prefs);
      addTearDown(first.dispose);

      first.read(agentConfigProvider);
      await settle();
      final notifier = first.read(agentConfigProvider.notifier);
      await notifier.setKey('sk-restored');
      await notifier.setPreset('siliconflow');

      final second = containerWith(prefs);
      addTearDown(second.dispose);
      second.read(agentConfigProvider);
      await settle();

      final restored = second.read(agentConfigProvider);
      expect(restored.presetId, 'siliconflow');
      expect(restored.baseUrl, 'https://api.siliconflow.cn/v1');
      expect(restored.model, 'deepseek-ai/DeepSeek-V3');
      expect(restored.apiKey, 'sk-restored');
      expect(restored.isConfigured, isTrue);
    });
  });

  group('buildAgentSystemPrompt', () {
    EntitiesSnapshot snapshotWith({required int totalWeeks}) =>
        EntitiesSnapshot(
          rows: [
            EntityRow(
              entityType: EntityTypes.calendar,
              entityId: 'cal1',
              revision: 1,
              payload: {
                'id': 'cal1',
                'name': '2026秋',
                'firstDay': '2026-09-07',
                'totalWeeks': totalWeeks,
                'revision': 1,
              },
            ),
            EntityRow(
              entityType: EntityTypes.period,
              entityId: 'p1',
              revision: 1,
              payload: {
                'id': 'p1',
                'calendarId': 'cal1',
                'periodNo': 1,
                'startLocal': '08:00',
                'endLocal': '08:45',
                'revision': 1,
              },
            ),
          ],
          pendingOps: const [],
          conflicts: const [],
        );

    // 2026-09-07 is the semester's Monday; 23:30Z is 07:30 Monday in Shanghai.
    final nowUtc = DateTime.utc(2026, 9, 6, 23, 30);

    test('injects timezone, local time, semester week and periods', () {
      final prompt = buildAgentSystemPrompt(
        userTime: ut,
        snapshot: snapshotWith(totalWeeks: 16),
        nowUtc: nowUtc,
      );

      expect(prompt, contains('Asia/Shanghai'));
      expect(prompt, contains('2026-09-07 07:30'));
      expect(prompt, contains('星期一'));
      expect(prompt, contains('2026秋'));
      expect(prompt, contains('2026-09-07'));
      expect(prompt, contains('第 1 周'));
      expect(prompt, contains('1: 08:00-08:45'));
      // The four behaviour rules must survive in the prompt.
      expect(prompt, contains('get_free_slots'));
      expect(prompt, contains('propose_changes'));
      expect(prompt, contains('严禁跨午夜'));
    });

    test('appends the user extra prompt', () {
      final prompt = buildAgentSystemPrompt(
        userTime: ut,
        snapshot: snapshotWith(totalWeeks: 16),
        nowUtc: nowUtc,
        extra: '回答使用简体中文，尽量简短。',
      );
      expect(prompt, contains('【用户自定义偏好】'));
      expect(prompt, contains('回答使用简体中文，尽量简短。'));
    });

    test('says so when the date is outside the semester', () {
      final prompt = buildAgentSystemPrompt(
        userTime: ut,
        snapshot: snapshotWith(totalWeeks: 16),
        nowUtc: DateTime.utc(2027, 2, 1, 2, 0),
      );
      expect(prompt, contains('学期外'));
      expect(prompt, isNot(contains('当前为 第 1 周')));
    });

    test('honours the preferred calendar id', () {
      final snapshot = EntitiesSnapshot(
        rows: [
          ...snapshotWith(totalWeeks: 16).rows,
          const EntityRow(
            entityType: EntityTypes.calendar,
            entityId: 'cal2',
            revision: 1,
            payload: {
              'id': 'cal2',
              'name': '2027春',
              'firstDay': '2027-02-22',
              'totalWeeks': 16,
              'revision': 1,
            },
          ),
        ],
        pendingOps: const [],
        conflicts: const [],
      );
      final prompt = buildAgentSystemPrompt(
        userTime: ut,
        snapshot: snapshot,
        nowUtc: nowUtc,
        preferredCalendarId: 'cal2',
      );
      expect(prompt, contains('2027春'));
      expect(prompt, contains('尚未开学'));
    });
  });
}
