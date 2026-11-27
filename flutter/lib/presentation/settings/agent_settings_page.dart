import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../agent/agent_config.dart';
import '../../agent/llm_client.dart';
import '../../core/voice/voice_config.dart';
import '../../state/prefs.dart';
import '../adaptive/adaptive.dart';

/// Built-in agent settings (docs/plans/v1/phase-5-builtin-agent.md Step 3/4).
///
/// Every field writes straight to [AgentConfigController]; there is no save
/// button. The API key lives in the platform's secure storage, never in the
/// plain preferences blob.
class AgentSettingsPage extends ConsumerStatefulWidget {
  const AgentSettingsPage({super.key});

  @override
  ConsumerState<AgentSettingsPage> createState() => _AgentSettingsPageState();
}

class _AgentSettingsPageState extends ConsumerState<AgentSettingsPage> {
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  late final TextEditingController _apiKey;
  late final TextEditingController _extra;

  late final TextEditingController _voiceBaseUrl;
  late final TextEditingController _voiceModel;
  late final TextEditingController _voiceApiKey;

  final FocusNode _baseUrlFocus = FocusNode();
  final FocusNode _modelFocus = FocusNode();
  final FocusNode _apiKeyFocus = FocusNode();
  final FocusNode _extraFocus = FocusNode();
  final FocusNode _voiceBaseUrlFocus = FocusNode();
  final FocusNode _voiceModelFocus = FocusNode();
  final FocusNode _voiceApiKeyFocus = FocusNode();

  bool _obscureKey = true;
  bool _obscureVoiceKey = true;
  bool _testing = false;
  bool _testOk = false;
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    final config = ref.read(agentConfigProvider);
    _baseUrl = TextEditingController(text: config.baseUrl);
    _model = TextEditingController(text: config.model);
    _apiKey = TextEditingController(text: config.apiKey);
    _extra = TextEditingController(text: config.extraSystemPrompt);
    final voice = ref.read(voiceConfigProvider);
    _voiceBaseUrl = TextEditingController(text: voice.baseUrl);
    _voiceModel = TextEditingController(text: voice.model);
    _voiceApiKey = TextEditingController(text: voice.apiKey);
    // A restored config (or a provider switch) can land after this frame; keep
    // the fields in step without fighting the field the user is typing in.
    _baseUrlFocus.addListener(_syncFromConfig);
    _modelFocus.addListener(_syncFromConfig);
    _apiKeyFocus.addListener(_syncFromConfig);
    _extraFocus.addListener(_syncFromConfig);
    _voiceBaseUrlFocus.addListener(_syncVoiceFromConfig);
    _voiceModelFocus.addListener(_syncVoiceFromConfig);
    _voiceApiKeyFocus.addListener(_syncVoiceFromConfig);
  }

  @override
  void dispose() {
    _baseUrlFocus.dispose();
    _modelFocus.dispose();
    _apiKeyFocus.dispose();
    _extraFocus.dispose();
    _baseUrl.dispose();
    _model.dispose();
    _apiKey.dispose();
    _extra.dispose();
    _voiceBaseUrlFocus.dispose();
    _voiceModelFocus.dispose();
    _voiceApiKeyFocus.dispose();
    _voiceBaseUrl.dispose();
    _voiceModel.dispose();
    _voiceApiKey.dispose();
    super.dispose();
  }

  void _syncFromConfig() {
    if (!mounted) return;
    _sync(ref.read(agentConfigProvider));
  }

  void _syncVoiceFromConfig() {
    if (!mounted) return;
    _syncVoice(ref.read(voiceConfigProvider));
  }

  void _syncVoice(VoiceConfig config) {
    if (!_voiceBaseUrlFocus.hasFocus) _setText(_voiceBaseUrl, config.baseUrl);
    if (!_voiceModelFocus.hasFocus) _setText(_voiceModel, config.model);
    if (!_voiceApiKeyFocus.hasFocus) _setText(_voiceApiKey, config.apiKey);
  }

  void _sync(LlmConfig config) {
    if (!_baseUrlFocus.hasFocus) _setText(_baseUrl, config.baseUrl);
    if (!_modelFocus.hasFocus) _setText(_model, config.model);
    if (!_apiKeyFocus.hasFocus) _setText(_apiKey, config.apiKey);
    if (!_extraFocus.hasFocus) {
      _setText(_extra, config.extraSystemPrompt);
    }
  }

  static void _setText(TextEditingController controller, String value) {
    if (controller.text == value) return;
    controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
  }

  /// One round-trip with a trivial prompt; only reports what came back, never
  /// echoes the key or raw request headers.
  Future<void> _testConnection() async {
    final config = ref.read(agentConfigProvider);
    if (!config.isConfigured || _testing) return;
    setState(() {
      _testing = true;
      _testMessage = null;
    });
    try {
      final reply = await LlmClient().complete(
        config: config,
        messages: const [
          {'role': 'user', 'content': '只回复 ok'},
        ],
        tools: const [],
      );
      final content = reply.content?.trim() ?? '';
      if (!mounted) return;
      setState(() {
        _testOk = true;
        _testMessage = content.isEmpty
            ? '✅ 连接成功（模型未返回内容）'
            : '✅ 连接成功：${_truncate(content, 40)}';
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _testOk = false;
        _testMessage = e is LlmException ? e.message : '连接失败，请检查配置与网络。';
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  static String _truncate(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max)}…';

  Future<void> _adoptVoiceCredentials() async {
    final before = ref.read(voiceConfigProvider).apiKey.trim();
    await ref.read(voiceConfigProvider.notifier).adoptAgentCredentials();
    if (!mounted) return;
    final config = ref.read(voiceConfigProvider);
    _syncVoice(config);
    final message = config.apiKey.trim().isEmpty
        ? '内置 AI 助手还没有配置 API Key，请先在上面填写'
        : (before.isEmpty ? '已复用 AI 助手的接口配置' : '语音 API Key 已填写，未覆盖');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = ref.watch(agentConfigProvider);
    final voice = ref.watch(voiceConfigProvider);
    // Re-sync on external changes (async restore, preset switch). The focused
    // field is skipped, so typing never jumps the cursor.
    ref.listen<LlmConfig>(agentConfigProvider, (_, next) => _sync(next));
    ref.listen<VoiceConfig>(voiceConfigProvider, (_, next) => _syncVoice(next));
    final preset = llmPresetById(config.presetId);

    return Scaffold(
      appBar: AppTopBar(title: '内置 AI 助手'),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 28),
        children: [
          // ---- bottom-bar visibility ---------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            padding: EdgeInsets.zero,
            child: SwitchListTile(
              value: ref.watch(agentTabEnabledProvider),
              onChanged: ref.read(agentTabEnabledProvider.notifier).set,
              secondary: const Icon(Icons.space_dashboard_outlined),
              title: const Text('在底栏显示 AI 助手'),
              subtitle: const Text('关闭后底栏只保留日程、待办、设置'),
            ),
          ),

          // ---- provider ----------------------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('服务商'),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      for (final item in kLlmPresets)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ChoiceChip(
                            label: Text(item.label),
                            selected: config.presetId == item.id,
                            onSelected: (_) {
                              if (config.presetId != item.id) {
                                ref
                                    .read(agentConfigProvider.notifier)
                                    .setPreset(item.id);
                              }
                            },
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '选择一个兼容 OpenAI Chat Completions 的服务；「自定义接口」'
                  '可填写任意代理地址。',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          // ---- connection --------------------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('连接配置'),
                const SizedBox(height: 10),
                TextField(
                  controller: _baseUrl,
                  focusNode: _baseUrlFocus,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.deepseek.com',
                  ),
                  onChanged: (value) =>
                      ref.read(agentConfigProvider.notifier).setBaseUrl(value),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _model,
                  focusNode: _modelFocus,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: '模型名称',
                    hintText: 'deepseek-chat',
                  ),
                  onChanged: (value) =>
                      ref.read(agentConfigProvider.notifier).setModel(value),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _apiKey,
                  focusNode: _apiKeyFocus,
                  obscureText: _obscureKey,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: preset?.keyHint ?? 'sk-...',
                    suffixIcon: IconButton(
                      tooltip: _obscureKey ? '显示 API Key' : '隐藏 API Key',
                      icon: Icon(
                        _obscureKey
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscureKey = !_obscureKey),
                    ),
                  ),
                  onChanged: (value) =>
                      ref.read(agentConfigProvider.notifier).setKey(value),
                ),
                if (preset?.keyHint != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '获取方式：${preset!.keyHint}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('温度（Temperature）', style: TextStyle(fontSize: 13)),
                    const Spacer(),
                    Text(
                      config.temperature.toStringAsFixed(2),
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
                Slider(
                  value: config.temperature.clamp(0.0, 1.0).toDouble(),
                  max: 1,
                  divisions: 20,
                  label: config.temperature.toStringAsFixed(2),
                  onChanged: (value) => ref
                      .read(agentConfigProvider.notifier)
                      .setTemperature(value),
                ),
                Text(
                  '越低越稳定，越高越发散；排期建议 0.2 – 0.5。',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          // ---- extra prompt ------------------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('附加提示词'),
                const SizedBox(height: 8),
                TextField(
                  controller: _extra,
                  focusNode: _extraFocus,
                  maxLines: 3,
                  minLines: 2,
                  decoration: const InputDecoration(
                    hintText: '例如：回答尽量简短；每周日晚上不要安排任务。',
                  ),
                  onChanged: (value) => ref
                      .read(agentConfigProvider.notifier)
                      .setExtraSystemPrompt(value),
                ),
                const SizedBox(height: 4),
                Text(
                  '会追加在内置提示词之后，只影响对话内容。',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              ],
            ),
          ),

          // ---- test connection --------------------------------------------
          AppCard(
            margin: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('测试连接'),
                const SizedBox(height: 8),
                FilledButton.tonal(
                  onPressed: config.isConfigured && !_testing
                      ? _testConnection
                      : null,
                  child: _testing
                      ? const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            SizedBox(width: 8),
                            Text('测试中…'),
                          ],
                        )
                      : const Text('测试连接'),
                ),
                if (!config.isConfigured)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      '请先填写 Base URL、模型名称与 API Key。',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                if (_testMessage != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _testOk
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 16,
                          color: _testOk ? Colors.green : scheme.error,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            _testMessage!,
                            style: TextStyle(
                              fontSize: 12,
                              color: _testOk ? Colors.green : scheme.error,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 18),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              'API Key 保存在本机安全存储，不会上传到服务器。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
          ),

          const SizedBox(height: 18),
          AppCard(
            margin: const EdgeInsets.only(bottom: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const _SectionTitle('语音识别（ASR）'),
                const SizedBox(height: 10),
                SegmentedButton<VoiceEngine>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: VoiceEngine.native,
                      icon: Icon(Icons.phone_android),
                      label: Text('系统原生'),
                    ),
                    ButtonSegment(
                      value: VoiceEngine.cloudWhisper,
                      icon: Icon(Icons.cloud_outlined),
                      label: Text('云端 Whisper'),
                    ),
                  ],
                  selected: {voice.engine},
                  onSelectionChanged: (selection) {
                    final engine = selection.first;
                    if (engine != voice.engine) {
                      ref
                          .read(voiceConfigProvider.notifier)
                          .setEngine(engine);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Text(
                  '系统原生使用手机自带语音识别；云端需配置 OpenAI 兼容 '
                  '/audio/transcriptions 接口。',
                  style: TextStyle(
                    fontSize: 11,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (voice.engine == VoiceEngine.cloudWhisper) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _voiceBaseUrl,
                    focusNode: _voiceBaseUrlFocus,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: 'Base URL',
                      hintText: 'https://api.siliconflow.cn/v1',
                    ),
                    onChanged: (value) => ref
                        .read(voiceConfigProvider.notifier)
                        .setCloud(value, _voiceModel.text),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _voiceModel,
                    focusNode: _voiceModelFocus,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      labelText: '模型名称',
                      hintText: 'FunAudioLLM/SenseVoiceSmall',
                    ),
                    onChanged: (value) => ref
                        .read(voiceConfigProvider.notifier)
                        .setCloud(_voiceBaseUrl.text, value),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _voiceApiKey,
                    focusNode: _voiceApiKeyFocus,
                    obscureText: _obscureVoiceKey,
                    enableSuggestions: false,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: 'API Key',
                      hintText: 'sk-...',
                      suffixIcon: IconButton(
                        tooltip: _obscureVoiceKey ? '显示 API Key' : '隐藏 API Key',
                        icon: Icon(
                          _obscureVoiceKey
                              ? Icons.visibility_outlined
                              : Icons.visibility_off_outlined,
                        ),
                        onPressed: () => setState(
                          () => _obscureVoiceKey = !_obscureVoiceKey,
                        ),
                      ),
                    ),
                    onChanged: (value) => ref
                        .read(voiceConfigProvider.notifier)
                        .setApiKey(value),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          voice.cloudConfigured ? '云端语音已配置' : '还未填写 API Key',
                          style: TextStyle(
                            fontSize: 11,
                            color: voice.cloudConfigured
                                ? Colors.green
                                : scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _adoptVoiceCredentials,
                        icon: const Icon(Icons.auto_fix_high, size: 18),
                        label: const Text('复用 AI 助手配置'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
  }
}
