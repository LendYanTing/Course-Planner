import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/prefs.dart';

/// One OpenAI-compatible provider template. Selecting it fills the endpoint and
/// a sensible default model; the user still supplies the API key (except for a
/// local Ollama, which usually needs none).
class LlmPreset {
  const LlmPreset({
    required this.id,
    required this.label,
    required this.baseUrl,
    required this.defaultModel,
    this.keyHint,
  });

  final String id;
  final String label;
  final String baseUrl;
  final String defaultModel;

  /// Short hint shown under the key field (where to obtain a key).
  final String? keyHint;
}

/// One-click providers for the built-in agent (phase 5 Step 3). `custom` is
/// intentionally blank so the user can point at any OpenAI-compatible gateway.
const kLlmPresets = <LlmPreset>[
  LlmPreset(
    id: 'deepseek',
    label: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
    keyHint: 'platform.deepseek.com',
  ),
  LlmPreset(
    id: 'siliconflow',
    label: '硅基流动 SiliconFlow',
    baseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V3',
    keyHint: 'cloud.siliconflow.cn',
  ),
  LlmPreset(
    id: 'dashscope',
    label: '通义千问 DashScope',
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    keyHint: 'bailian.console.aliyun.com',
  ),
  LlmPreset(
    id: 'openai',
    label: 'OpenAI',
    baseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o-mini',
    keyHint: 'platform.openai.com',
  ),
  LlmPreset(
    id: 'ollama',
    label: '本地 Ollama',
    baseUrl: 'http://127.0.0.1:11434/v1',
    defaultModel: 'llama3.1',
    keyHint: '本地服务通常无需 API Key',
  ),
  LlmPreset(
    id: 'custom',
    label: '自定义接口',
    baseUrl: '',
    defaultModel: '',
    keyHint: '任意兼容 OpenAI Chat Completions 的地址（含 /v1）',
  ),
];

/// Looks up a preset by id; null for unknown ids (a config may outlive a
/// removed preset).
LlmPreset? llmPresetById(String id) {
  for (final p in kLlmPresets) {
    if (p.id == id) return p;
  }
  return null;
}

/// Built-in agent LLM settings. The API key is never written to the plain
/// config JSON — [AgentConfigController] stores it under its own secure key.
class LlmConfig {
  const LlmConfig({
    this.presetId = 'deepseek',
    this.baseUrl = 'https://api.deepseek.com',
    this.apiKey = '',
    this.model = 'deepseek-chat',
    this.temperature = 0.3,
    this.extraSystemPrompt = '',
  });

  final String presetId;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double temperature;

  /// User-authored additions appended to the generated system prompt.
  final String extraSystemPrompt;

  bool get isConfigured =>
      apiKey.trim().isNotEmpty &&
      baseUrl.trim().isNotEmpty &&
      model.trim().isNotEmpty;

  LlmConfig copyWith({
    String? presetId,
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    String? extraSystemPrompt,
  }) => LlmConfig(
    presetId: presetId ?? this.presetId,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    model: model ?? this.model,
    temperature: temperature ?? this.temperature,
    extraSystemPrompt: extraSystemPrompt ?? this.extraSystemPrompt,
  );

  /// Persisted form. The key is opt-in so the default call cannot leak it into
  /// the preferences JSON.
  Map<String, dynamic> toJson({bool includeKey = false}) => {
    'presetId': presetId,
    'baseUrl': baseUrl,
    'model': model,
    'temperature': temperature,
    'extraSystemPrompt': extraSystemPrompt,
    if (includeKey) 'apiKey': apiKey,
  };

  static LlmConfig fromJson(Map<String, dynamic> m, {String apiKey = ''}) {
    final fallback = const LlmConfig();
    final presetId = m['presetId'];
    final baseUrl = m['baseUrl'];
    final model = m['model'];
    final temperature = m['temperature'];
    final extra = m['extraSystemPrompt'];
    return LlmConfig(
      presetId: presetId is String && presetId.isNotEmpty
          ? presetId
          : fallback.presetId,
      baseUrl: baseUrl is String ? baseUrl : fallback.baseUrl,
      apiKey: apiKey,
      model: model is String ? model : fallback.model,
      temperature: temperature is num
          ? temperature.toDouble().clamp(0.0, 2.0).toDouble()
          : fallback.temperature,
      extraSystemPrompt: extra is String ? extra : '',
    );
  }
}

/// Persists the agent LLM settings. Non-sensitive fields live in one JSON
/// preference; the API key has its own secure-storage entry (see
/// [PrefStore]) so it is not duplicated into the JSON blob.
class AgentConfigController extends Notifier<LlmConfig> {
  static const configKey = 'agent_llm_config';
  static const apiKeyKey = 'agent_api_key';

  @override
  LlmConfig build() {
    _restore();
    return const LlmConfig();
  }

  Future<void> _restore() async {
    try {
      final prefs = ref.read(prefStoreProvider);
      final raw = await prefs.read(configKey);
      final key = await prefs.read(apiKeyKey) ?? '';
      if (raw == null && key.isEmpty) return;
      final config = raw == null ? const LlmConfig() : _decode(raw);
      state = config.copyWith(apiKey: key);
    } on Object {
      // Best effort: keep the default provider and an empty key.
    }
  }

  /// Decodes the persisted JSON blob; malformed data falls back to defaults.
  LlmConfig _decode(String raw) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return LlmConfig.fromJson(decoded);
    }
    if (decoded is Map) {
      return LlmConfig.fromJson(Map<String, dynamic>.from(decoded));
    }
    return const LlmConfig();
  }

  /// Writes the non-sensitive half. Best effort, like the other, local-only
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

  Future<void> setPreset(String id) async {
    final preset = llmPresetById(id);
    if (preset == null) return;
    // The key stays: switching providers must not silently wipe it.
    state = state.copyWith(
      presetId: preset.id,
      baseUrl: preset.baseUrl,
      model: preset.defaultModel,
    );
    await _persist();
  }

  Future<void> setBaseUrl(String baseUrl) async {
    state = state.copyWith(baseUrl: baseUrl.trim());
    await _persist();
  }

  Future<void> setModel(String model) async {
    state = state.copyWith(model: model.trim());
    await _persist();
  }

  Future<void> setTemperature(double temperature) async {
    state = state.copyWith(temperature: temperature.clamp(0.0, 2.0).toDouble());
    await _persist();
  }

  Future<void> setExtraSystemPrompt(String extra) async {
    state = state.copyWith(extraSystemPrompt: extra);
    await _persist();
  }

  /// Stores the key on its own; it is the only field that is secret.
  Future<void> setKey(String apiKey) async {
    state = state.copyWith(apiKey: apiKey.trim());
    try {
      await ref.read(prefStoreProvider).write(apiKeyKey, state.apiKey);
    } on Object {
      // Best effort: the in-memory value still works for this session.
    }
  }
}

final agentConfigProvider = NotifierProvider<AgentConfigController, LlmConfig>(
  AgentConfigController.new,
);
