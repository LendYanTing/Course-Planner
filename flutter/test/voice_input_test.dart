import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:course_planner/agent/agent_config.dart';
import 'package:course_planner/core/voice/voice_config.dart';
import 'package:course_planner/core/voice/voice_recognizer.dart';
import 'package:course_planner/presentation/widgets/voice_input_button.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

/// 双模语音识别（phase 6 Step 3）:
/// * settings persistence and agent-credential adoption;
/// * the reusable [VoiceInputButton] against a fake recognizer (success,
///   failure, unavailable);
/// * the cloud multipart client, driven by a fake Dio adapter (no network).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer containerWith(MemoryPrefs prefs) => ProviderContainer(
    overrides: [prefStoreProvider.overrideWithValue(prefs)],
  );

  group('VoiceConfigController', () {
    test('默认系统原生，云端未配置', () async {
      final container = containerWith(MemoryPrefs());
      addTearDown(container.dispose);

      final config = container.read(voiceConfigProvider);
      await pumpEventQueue();

      expect(config.engine, VoiceEngine.native);
      expect(config.model, 'FunAudioLLM/SenseVoiceSmall');
      expect(config.cloudConfigured, isFalse);
      expect(container.read(voiceConfigProvider).engine, VoiceEngine.native);
    });

    test('setApiKey 单独持久化，配置 JSON 不含 key', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      container.read(voiceConfigProvider);
      await pumpEventQueue();
      final notifier = container.read(voiceConfigProvider.notifier);

      await notifier.setApiKey('sk-voice-secret');
      await notifier.setCloud(
        'https://api.siliconflow.cn/v1',
        'FunAudioLLM/SenseVoiceSmall',
      );

      expect(
        await prefs.read(VoiceConfigController.apiKeyKey),
        'sk-voice-secret',
      );
      final raw = await prefs.read(VoiceConfigController.configKey);
      expect(raw, isNotNull);
      expect(raw!, isNot(contains('sk-voice-secret')));
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['engine'], 'native');
      expect(json['baseUrl'], 'https://api.siliconflow.cn/v1');
      expect(json['model'], 'FunAudioLLM/SenseVoiceSmall');
      expect(json.containsKey('apiKey'), isFalse);
      expect(container.read(voiceConfigProvider).cloudConfigured, isTrue);
    });

    test('重启后恢复引擎、云端地址与 key', () async {
      final prefs = MemoryPrefs();
      final first = containerWith(prefs);
      addTearDown(first.dispose);

      first.read(voiceConfigProvider);
      await pumpEventQueue();
      final notifier = first.read(voiceConfigProvider.notifier);
      await notifier.setEngine(VoiceEngine.cloudWhisper);
      await notifier.setApiKey('sk-restored');
      await notifier.setCloud('https://asr.example.com/v1', 'whisper-1');

      final second = containerWith(prefs);
      addTearDown(second.dispose);
      second.read(voiceConfigProvider);
      await pumpEventQueue();

      final restored = second.read(voiceConfigProvider);
      expect(restored.engine, VoiceEngine.cloudWhisper);
      expect(restored.baseUrl, 'https://asr.example.com/v1');
      expect(restored.model, 'whisper-1');
      expect(restored.apiKey, 'sk-restored');
      expect(restored.cloudConfigured, isTrue);
    });

    test('adoptAgentCredentials 从内置 Agent 复制 BaseURL / Key / Model', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      container.read(agentConfigProvider);
      await pumpEventQueue();
      final agent = container.read(agentConfigProvider.notifier);
      await agent.setKey('sk-agent-key');
      await agent.setPreset('siliconflow');

      final voice = container.read(voiceConfigProvider.notifier);
      await voice.adoptAgentCredentials();

      final config = container.read(voiceConfigProvider);
      expect(config.apiKey, 'sk-agent-key');
      expect(config.baseUrl, 'https://api.siliconflow.cn/v1');
      expect(config.model, 'deepseek-ai/DeepSeek-V3');
      expect(config.cloudConfigured, isTrue);
      expect(await prefs.read(VoiceConfigController.apiKeyKey), 'sk-agent-key');
    });

    test('adoptAgentCredentials 不覆盖已填写的 key', () async {
      final prefs = MemoryPrefs();
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      container.read(agentConfigProvider);
      await pumpEventQueue();
      await container.read(agentConfigProvider.notifier).setKey('sk-agent');

      final voice = container.read(voiceConfigProvider.notifier);
      await voice.setApiKey('sk-voice');
      await voice.adoptAgentCredentials();

      expect(container.read(voiceConfigProvider).apiKey, 'sk-voice');
    });

    test('adoptAgentCredentials 在 Agent 尚未恢复时读取已持久化的凭据', () async {
      final prefs = MemoryPrefs({
        AgentConfigController.configKey: jsonEncode(
          const LlmConfig(
            presetId: 'siliconflow',
            baseUrl: 'https://api.siliconflow.cn/v1',
            model: 'deepseek-ai/DeepSeek-V3',
          ).toJson(),
        ),
        AgentConfigController.apiKeyKey: 'sk-persisted-agent',
      });
      final container = containerWith(prefs);
      addTearDown(container.dispose);

      // Deliberately no pumpEventQueue(): the agent controller's async restore
      // has not finished, so the fallback path must read the store itself.
      await container
          .read(voiceConfigProvider.notifier)
          .adoptAgentCredentials();

      final config = container.read(voiceConfigProvider);
      expect(config.apiKey, 'sk-persisted-agent');
      expect(config.baseUrl, 'https://api.siliconflow.cn/v1');
      expect(config.model, 'deepseek-ai/DeepSeek-V3');
    });
  });

  group('VoiceInputButton', () {
    Future<void> pumpButton(
      WidgetTester tester,
      VoiceRecognizer recognizer,
      ValueChanged<String> onText,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [voiceRecognizerProvider.overrideWithValue(recognizer)],
          child: MaterialApp(
            home: Scaffold(
              body: Center(child: VoiceInputButton(onText: onText)),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
    }

    testWidgets('点击后把识别文本交给 onText', (tester) async {
      final fake = _FakeRecognizer(result: const VoiceResult(text: '下周三交毛概论文'));
      String? received;
      await pumpButton(tester, fake, (text) => received = text);

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump();

      expect(received, '下周三交毛概论文');
      expect(fake.recognizeCalls, 1);
      // Back to idle: a second tap is possible again.
      expect(find.byIcon(Icons.mic), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('识别中禁用重复点击', (tester) async {
      final fake = _FakeRecognizer(
        result: const VoiceResult(text: '等一下'),
        delay: const Duration(milliseconds: 80),
      );
      String? received;
      await pumpButton(tester, fake, (text) => received = text);

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump(const Duration(milliseconds: 10));

      expect(find.byIcon(Icons.graphic_eq), findsOneWidget);
      expect(
        tester.widget<IconButton>(find.byType(IconButton)).onPressed,
        isNull,
      );

      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump();
      expect(received, '等一下');
      expect(fake.recognizeCalls, 1);
    });

    testWidgets('识别失败时显示 SnackBar 且不回调 onText', (tester) async {
      final fake = _FakeRecognizer(
        result: const VoiceResult(error: '无法获取录音，请检查麦克风权限'),
      );
      String? received;
      await pumpButton(tester, fake, (text) => received = text);

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(received, isNull);
      expect(find.text('无法获取录音，请检查麦克风权限'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('识别器抛异常时兜底为 SnackBar', (tester) async {
      final fake = _FakeRecognizer(throwError: true);
      await pumpButton(tester, fake, (_) {});

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('语音识别失败，请重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('不可用时给出提示、不调用识别且不崩溃', (tester) async {
      final fake = _FakeRecognizer(
        isAvailable: false,
        result: const VoiceResult(text: '不会被用到'),
      );
      String? received;
      await pumpButton(tester, fake, (text) => received = text);

      final tooltip = tester.widget<Tooltip>(find.byType(Tooltip));
      expect(tooltip.message, VoiceInputButton.unavailableTooltip);

      await tester.tap(find.byIcon(Icons.mic));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(received, isNull);
      expect(fake.recognizeCalls, 0);
      expect(find.text(VoiceInputButton.unavailableMessage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CloudWhisperRecognizer', () {
    test('未配置时不可用，recognize 返回错误而不是抛异常', () async {
      final recognizer = CloudWhisperRecognizer(
        config: const VoiceConfig(engine: VoiceEngine.cloudWhisper),
        recordAudio: () async => null,
        dio: Dio(),
      );

      expect(await recognizer.available, isFalse);
      final result = await recognizer.recognize();
      expect(result.text, isNull);
      expect(result.error, contains('尚未配置'));
    });

    test('上传 multipart 并解析 text 字段', () async {
      final adapter = _RecordingAdapter(body: jsonEncode({'text': '你好'}));
      final dio = Dio()..httpClientAdapter = adapter;
      final recognizer = CloudWhisperRecognizer(
        config: const VoiceConfig(
          engine: VoiceEngine.cloudWhisper,
          baseUrl: 'https://asr.example.com/v1',
          apiKey: 'sk-test-key',
          model: 'FunAudioLLM/SenseVoiceSmall',
        ),
        recordAudio: () async => <int>[1, 2, 3, 4],
        dio: dio,
      );

      final result = await recognizer.recognize();

      expect(result.error, isNull);
      expect(result.text, '你好');

      final request = adapter.lastRequest!;
      expect(
        request.uri.toString(),
        'https://asr.example.com/v1/audio/transcriptions',
      );
      final authorization = request.headers.entries
          .firstWhere((e) => e.key.toLowerCase() == 'authorization')
          .value;
      expect(authorization, 'Bearer sk-test-key');

      final body = adapter.lastBody!;
      expect(body, contains('name="file"'));
      expect(body, contains('filename="speech.m4a"'));
      expect(body, contains('FunAudioLLM/SenseVoiceSmall'));
    });

    test('HTTP 错误转成中文提示，且不泄露 key', () async {
      final adapter = _RecordingAdapter(
        body: jsonEncode({
          'error': {'message': 'invalid api key'},
        }),
        statusCode: 401,
      );
      final dio = Dio()..httpClientAdapter = adapter;
      final recognizer = CloudWhisperRecognizer(
        config: const VoiceConfig(
          engine: VoiceEngine.cloudWhisper,
          baseUrl: 'https://asr.example.com/v1/',
          apiKey: 'sk-must-not-leak',
          model: 'whisper-1',
        ),
        recordAudio: () async => <int>[9],
        dio: dio,
      );

      final result = await recognizer.recognize();

      expect(result.text, isNull);
      expect(result.error, contains('HTTP 401'));
      expect(result.error, contains('invalid api key'));
      expect(result.error, isNot(contains('sk-must-not-leak')));
    });

    test('拿不到录音时返回错误，不发请求', () async {
      final adapter = _RecordingAdapter(body: jsonEncode({'text': '不该出现'}));
      final dio = Dio()..httpClientAdapter = adapter;
      final recognizer = CloudWhisperRecognizer(
        config: const VoiceConfig(
          engine: VoiceEngine.cloudWhisper,
          apiKey: 'sk-test',
        ),
        recordAudio: () async => null,
        dio: dio,
      );

      final result = await recognizer.recognize();

      expect(result.error, contains('麦克风权限'));
      expect(adapter.lastRequest, isNull);
    });
  });

  group('SystemVoiceRecognizer', () {
    test('非 Android 平台不可用，recognize 返回错误', () async {
      final recognizer = SystemVoiceRecognizer(platformSupported: false);

      expect(await recognizer.available, isFalse);
      final result = await recognizer.recognize();
      expect(result.text, isNull);
      expect(result.error, isNotNull);
      // Cancel is always safe, even when nothing is running.
      await recognizer.cancel();
    });
  });
}

class _FakeRecognizer implements VoiceRecognizer {
  _FakeRecognizer({
    this.isAvailable = true,
    this.result = const VoiceResult(text: '测试文本'),
    this.delay = Duration.zero,
    this.throwError = false,
  });

  final bool isAvailable;
  final VoiceResult result;
  final Duration delay;
  final bool throwError;

  int recognizeCalls = 0;
  int cancelCalls = 0;

  @override
  Future<bool> get available async => isAvailable;

  @override
  Future<VoiceResult> recognize({
    Duration maxDuration = const Duration(seconds: 30),
  }) async {
    recognizeCalls++;
    if (delay > Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (throwError) throw StateError('boom');
    return result;
  }

  @override
  Future<void> cancel() async {
    cancelCalls++;
  }
}

/// Fake Dio adapter: records the request and answers with [body] without any
/// network I/O.
class _RecordingAdapter implements HttpClientAdapter {
  _RecordingAdapter({required this.body, this.statusCode = 200});

  final String body;
  final int statusCode;

  RequestOptions? lastRequest;
  String? lastBody;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    lastRequest = options;
    final stream = requestStream;
    if (stream != null) {
      final bytes = <int>[];
      await for (final chunk in stream) {
        bytes.addAll(chunk);
      }
      lastBody = utf8.decode(bytes, allowMalformed: true);
    }
    return ResponseBody.fromString(
      body,
      statusCode,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
