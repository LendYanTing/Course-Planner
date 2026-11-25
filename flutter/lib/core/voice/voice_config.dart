import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/agent_config.dart';
import '../../state/prefs.dart';

/// Which ASR backend the voice button uses.
///
/// * [native] — the system recognizer through the `course_planner/speech`
///   method channel (Android `RecognizerIntent`). Zero configuration.
/// * [cloudWhisper] — an OpenAI-compatible `/audio/transcriptions` endpoint
///   (SiliconFlow SenseVoice, Groq/OpenAI Whisper, …).
enum VoiceEngine { native, cloudWhisper }

/// Speech-recognition settings. The API key is never part of [toJson]: it has
/// its own secure-storage entry, exactly like the built-in agent's LLM key.
class VoiceConfig {
  const VoiceConfig({
    this.engine = VoiceEngine.native,
    this.baseUrl = 'https://api.siliconflow.cn/v1',
    this.apiKey = '',
    this.model = 'FunAudioLLM/SenseVoiceSmall',
  });

  final VoiceEngine engine;
  final String baseUrl;
  final String apiKey;
  final String model;

  /// Whether a cloud transcription request has every field it needs.
  bool get cloudConfigured =>
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  VoiceConfig copyWith({
    VoiceEngine? engine,
    String? baseUrl,
    String? apiKey,
    String? model,
  }) {
    return VoiceConfig(
      engine: engine ?? this.engine,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
    );
  }

  /// Persisted form. The key is deliberately absent; see
  /// [VoiceConfigController.apiKeyKey].
  Map<String, dynamic> toJson() => <String, dynamic>{
    'engine': engine.name,
    'baseUrl': baseUrl,
    'model': model,
  };

  static VoiceConfig fromJson(Map<String, dynamic> m, {String apiKey = ''}) {
    const fallback = VoiceConfig();
    final engine = m['engine'];
    final baseUrl = m['baseUrl'];
    final model = m['model'];
    return VoiceConfig(
      engine: engine is String
          ? VoiceEngine.values.firstWhere(
              (e) => e.name == engine,
              orElse: () => fallback.engine,
            )
          : fallback.engine,
      baseUrl: baseUrl is String ? baseUrl : fallback.baseUrl,
      apiKey: apiKey,
      model: model is String ? model : fallback.model,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VoiceConfig &&
          other.engine == engine &&
          other.baseUrl == baseUrl &&
          other.apiKey == apiKey &&
          other.model == model;

  @override
  int get hashCode => Object.hash(engine, baseUrl, apiKey, model);
}

/// Persists [VoiceConfig] locally. Non-sensitive fields share one JSON blob;
/// the key is stored under [apiKeyKey] so it never appears in the blob.
class VoiceConfigController extends Notifier<VoiceConfig> {
  static const configKey = 'voice_config';
  static const apiKeyKey = 'voice_api_key';

  @override
  VoiceConfig build() {
    _restore();
    return const VoiceConfig();
  }

  Future<void> _restore() async {
    try {
      final prefs = ref.read(prefStoreProvider);
      final raw = await prefs.read(configKey);
      final key = await prefs.read(apiKeyKey) ?? '';
      if (raw == null && key.isEmpty) return;
      final config = raw == null ? const VoiceConfig() : _decode(raw);
      state = config.copyWith(apiKey: key);
    } on Object {
      // Best effort: keep the defaults (native engine, empty key).
    }
  }

  VoiceConfig _decode(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return VoiceConfig.fromJson(decoded);
      }
      if (decoded is Map) {
        return VoiceConfig.fromJson(Map<String, dynamic>.from(decoded));
      }
    } on Object {
      // Malformed JSON falls back to the defaults.
    }
    return const VoiceConfig();
  }

  /// Writes the non-sensitive half. Best effort, like the other local-only
  /// preference controllers.
  Future<void> _persist() async {
    try {
      await ref
          .read(prefStoreProvider)
          .write(configKey, jsonEncode(state.toJson()));
    } on Object {
      // Best effort.
    }
  }

  Future<void> _persistKey() async {
    try {
      await ref.read(prefStoreProvider).write(apiKeyKey, state.apiKey);
    } on Object {
      // Best effort: the in-memory value still works for this session.
    }
  }

  Future<void> setEngine(VoiceEngine engine) async {
    state = state.copyWith(engine: engine);
    await _persist();
  }

  /// Updates the cloud endpoint and model together (one persist for both).
  Future<void> setCloud(String baseUrl, String model) async {
    state = state.copyWith(baseUrl: baseUrl.trim(), model: model.trim());
    await _persist();
  }

  /// Stores the key on its own; it is the only secret field and is never
  /// logged.
  Future<void> setApiKey(String apiKey) async {
    state = state.copyWith(apiKey: apiKey.trim());
    await _persistKey();
  }

  /// Copies the built-in agent's Base URL, key and model when this config has
  /// no key yet, so the user does not type the same credentials twice.
  ///
  /// Reads the persisted agent config as a fallback: [AgentConfigController]
  /// restores asynchronously, and this may be called before that finishes.
  Future<void> adoptAgentCredentials() async {
    if (state.apiKey.trim().isNotEmpty) return;

    var baseUrl = '';
    var model = '';
    var apiKey = '';

    final agent = ref.read(agentConfigProvider);
    if (agent.apiKey.trim().isNotEmpty) {
      baseUrl = agent.baseUrl;
      model = agent.model;
      apiKey = agent.apiKey;
    } else {
      try {
        final prefs = ref.read(prefStoreProvider);
        apiKey = (await prefs.read(AgentConfigController.apiKeyKey) ?? '')
            .trim();
        final raw = await prefs.read(AgentConfigController.configKey);
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is Map) {
            final restored = LlmConfig.fromJson(
              Map<String, dynamic>.from(decoded),
              apiKey: apiKey,
            );
            baseUrl = restored.baseUrl;
            model = restored.model;
          }
        }
      } on Object {
        // Fall through to the in-memory agent config.
      }
      if (baseUrl.trim().isEmpty) baseUrl = agent.baseUrl;
      if (model.trim().isEmpty) model = agent.model;
    }

    apiKey = apiKey.trim();
    if (apiKey.isEmpty) return;

    state = state.copyWith(
      baseUrl: baseUrl.trim().isEmpty ? state.baseUrl : baseUrl.trim(),
      model: model.trim().isEmpty ? state.model : model.trim(),
      apiKey: apiKey,
    );
    await _persist();
    await _persistKey();
  }
}

final voiceConfigProvider =
    NotifierProvider<VoiceConfigController, VoiceConfig>(
      VoiceConfigController.new,
    );
