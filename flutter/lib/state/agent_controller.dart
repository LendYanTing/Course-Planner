import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error/api_exception.dart';
import '../core/time/user_time.dart';
import 'app_services.dart';
import 'prefs.dart';
import 'providers.dart';
import 'sync_controller.dart';
import '../agent/agent_config.dart';
import '../agent/agent_prompts.dart';
import '../agent/llm_client.dart';
import '../agent/local_agent_tools.dart';

/// Who authored one chat bubble.
enum AgentRole { user, assistant, tool }

/// One row of the agent chat. [toolLabel] marks a tool-progress row the UI can
/// collapse; [changeSet] is attached to the message that opens the one-shot
/// confirmation card (docs/agent-behavior.md §Confirmation).
class AgentMessage {
  const AgentMessage({
    required this.role,
    required this.text,
    this.isError = false,
    this.toolLabel,
    this.changeSet,
  });

  final AgentRole role;
  final String text;
  final bool isError;
  final String? toolLabel;
  final LocalChangeSet? changeSet;
}

/// Chat transcript plus the request waiting for the user's one-click confirm.
class AgentState {
  const AgentState({
    this.messages = const [],
    this.busy = false,
    this.pendingChangeSet,
    this.error,
  });

  final List<AgentMessage> messages;
  final bool busy;
  final LocalChangeSet? pendingChangeSet;
  final String? error;

  AgentState copyWith({
    List<AgentMessage>? messages,
    bool? busy,
    LocalChangeSet? pendingChangeSet,
    bool clearPendingChangeSet = false,
    String? error,
  }) => AgentState(
    messages: messages ?? this.messages,
    busy: busy ?? this.busy,
    pendingChangeSet: clearPendingChangeSet
        ? null
        : (pendingChangeSet ?? this.pendingChangeSet),
    error: error,
  );
}

/// Drives the built-in agent: builds the OpenAI-style message list, runs the
/// tool-calling loop against [LlmClient], and holds the [LocalChangeSet] until
/// the user confirms it.
///
/// The model-facing history is kept separately from [AgentState.messages]
/// because OpenAI requires the raw `tool_calls` payload and matching
/// `tool_call_id` replies to be replayed verbatim — display messages do not
/// carry enough structure for that.
class AgentController extends Notifier<AgentState> {
  static const _maxToolRounds = 6;

  final LlmClient _client = LlmClient();
  final List<Map<String, dynamic>> _transcript = [];

  LocalAgentTools? _tools;
  String? _toolsTimezone;

  @override
  AgentState build() {
    _transcript.clear();
    _tools = null;
    _toolsTimezone = null;
    return const AgentState();
  }

  /// Sends one user turn and drives the tool loop. Ignored while a request is
  /// running, when another change set still awaits confirmation, or when the
  /// text is blank.
  Future<void> send(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || state.busy) return;

    final userMessage = AgentMessage(role: AgentRole.user, text: trimmed);
    if (state.pendingChangeSet != null) {
      _append(
        AgentMessage(
          role: AgentRole.assistant,
          text: '请先确认或取消上一条修改，再发送新的请求。',
          isError: true,
        ),
      );
      return;
    }

    final config = ref.read(agentConfigProvider);
    if (!config.isConfigured) {
      state = state.copyWith(
        messages: [
          ...state.messages,
          userMessage,
          const AgentMessage(
            role: AgentRole.assistant,
            text:
                'AI 助手还没有配置完成。请前往「设置 → 内置 AI 助手配置」'
                '选择服务商并填写 API Key、模型名称后再试。',
            isError: true,
          ),
        ],
        error: 'AI 助手尚未配置',
      );
      return;
    }

    final userTime = ref.read(userTimeProvider);
    final snapshot = ref.read(snapshotProvider).value;
    if (userTime == null || snapshot == null) {
      state = state.copyWith(
        messages: [
          ...state.messages,
          userMessage,
          const AgentMessage(
            role: AgentRole.assistant,
            text: '本地数据尚未就绪，请稍后再试。',
            isError: true,
          ),
        ],
      );
      return;
    }

    // docs/datetime.md §8: the request timeline uses the estimated server now;
    // the device clock is only a fallback before the first tick arrives.
    final nowUtc = ref.read(serverNowProvider).value ?? DateTime.now().toUtc();
    final systemPrompt = buildAgentSystemPrompt(
      userTime: userTime,
      snapshot: snapshot,
      nowUtc: nowUtc,
      extra: config.extraSystemPrompt,
      preferredCalendarId: ref.read(activeSemesterProvider),
    );
    final tools = _toolsFor(userTime);

    final userEntry = <String, dynamic>{'role': 'user', 'content': trimmed};
    final request = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      ..._transcript,
      userEntry,
    ];
    // Only committed once the turn ends in a state the model can continue
    // from (never a dangling assistant tool_calls without its tool replies).
    final turn = <Map<String, dynamic>>[userEntry];

    state = state.copyWith(
      messages: [...state.messages, userMessage],
      busy: true,
      error: null,
    );

    try {
      for (var round = 0; round < _maxToolRounds; round++) {
        final reply = await _client.complete(
          config: config,
          messages: request,
          tools: tools.toolSchemas,
        );

        if (reply.toolCalls.isEmpty) {
          final content = reply.content?.trim();
          if (content == null || content.isEmpty) {
            _append(
              AgentMessage(
                role: AgentRole.assistant,
                text: '模型没有返回可用内容，请再试一次。',
                isError: true,
              ),
            );
          } else {
            _append(AgentMessage(role: AgentRole.assistant, text: content));
            turn.add({'role': 'assistant', 'content': content});
          }
          break;
        }

        final assistantEntry = <String, dynamic>{
          'role': 'assistant',
          'content': reply.content ?? '',
          'tool_calls': [
            for (final call in reply.toolCalls)
              {
                'id': call.id,
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': call.argumentsJson,
                },
              },
          ],
        };
        request.add(assistantEntry);
        turn.add(assistantEntry);

        var awaitingConfirmation = false;
        for (var i = 0; i < reply.toolCalls.length; i++) {
          final call = reply.toolCalls[i];
          final args = _parseArguments(call.argumentsJson);
          Map<String, dynamic> result;
          try {
            result = await tools.call(call.name, args);
          } on Object catch (e) {
            // Tool failures go back to the model as data, not as a crash.
            result = {'error': _errorText(e)};
          }
          final toolEntry = <String, dynamic>{
            'role': 'tool',
            'tool_call_id': call.id,
            'content': jsonEncode(result),
          };
          request.add(toolEntry);
          turn.add(toolEntry);

          if (_isProposeChanges(call.name)) {
            final changeSet = tools.pendingChangeSet;
            if (changeSet != null && changeSet.length > 0) {
              // One request → one Change Set → one confirmation card.
              _append(
                AgentMessage(
                  role: AgentRole.assistant,
                  text: '已为你准备好 ${changeSet.length} 项修改，请确认。',
                  changeSet: changeSet,
                ),
                pendingChangeSet: changeSet,
              );
              // Every tool_call of this assistant message needs a reply or the
              // next request is rejected by OpenAI-compatible servers.
              for (final rest in reply.toolCalls.skip(i + 1)) {
                final skipped = <String, dynamic>{
                  'role': 'tool',
                  'tool_call_id': rest.id,
                  'content': jsonEncode({
                    'skipped': true,
                    'reason': '等待用户确认变更，未执行该调用',
                  }),
                };
                request.add(skipped);
                turn.add(skipped);
              }
              awaitingConfirmation = true;
              break;
            }
          }
          _append(
            AgentMessage(
              role: AgentRole.tool,
              text: jsonEncode(result),
              toolLabel: '🔍 ${call.name} 完成',
            ),
          );
        }
        if (awaitingConfirmation) break;
        if (round == _maxToolRounds - 1) {
          _append(
            AgentMessage(
              role: AgentRole.assistant,
              text: '工具调用轮数过多，已停止本次请求。请换个说法再试。',
              isError: true,
            ),
          );
        }
      }
      _transcript.addAll(turn);
      state = state.copyWith(busy: false);
    } on Object catch (e) {
      state = state.copyWith(
        messages: [
          ...state.messages,
          AgentMessage(
            role: AgentRole.assistant,
            text: _errorText(e),
            isError: true,
          ),
        ],
        busy: false,
        error: _errorText(e),
      );
    }
  }

  /// Applies the pending change set in one atomic local transaction.
  Future<void> confirmPending() async {
    final changeSet = state.pendingChangeSet;
    if (changeSet == null || state.busy) return;
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) {
      _append(
        AgentMessage(
          role: AgentRole.assistant,
          text: '本地数据尚未就绪，无法应用修改。',
          isError: true,
        ),
      );
      return;
    }
    final tools = _toolsFor(userTime);
    state = state.copyWith(busy: true, error: null);
    try {
      await tools.applyPendingChangeSet();
      _transcript.add(const {'role': 'assistant', 'content': '用户已确认，修改已全部应用。'});
      state = state.copyWith(
        messages: [
          ...state.messages,
          const AgentMessage(role: AgentRole.assistant, text: '✅ 已应用全部修改'),
        ],
        busy: false,
        clearPendingChangeSet: true,
        error: null,
      );
    } on Object catch (e) {
      // Keep the change set: the user may retry or cancel it.
      state = state.copyWith(
        messages: [
          ...state.messages,
          AgentMessage(
            role: AgentRole.assistant,
            text: '应用修改失败：${_errorText(e)}',
            isError: true,
          ),
        ],
        busy: false,
        error: _errorText(e),
      );
    }
  }

  /// Drops the pending change set without touching local data.
  void cancelPending() {
    if (state.pendingChangeSet == null) return;
    _tools?.discardPendingChangeSet();
    _transcript.add(const {'role': 'assistant', 'content': '用户取消了本次修改。'});
    state = state.copyWith(
      messages: [
        ...state.messages,
        const AgentMessage(role: AgentRole.assistant, text: '已取消本次修改'),
      ],
      clearPendingChangeSet: true,
      error: null,
    );
  }

  /// Clears the conversation (the pending change set is discarded too).
  void reset() {
    _tools?.discardPendingChangeSet();
    _tools = null;
    _toolsTimezone = null;
    _transcript.clear();
    state = const AgentState();
  }

  /// One [LocalAgentTools] per timezone, created on demand: it is neither
  /// serializable nor worth exposing as provider state.
  LocalAgentTools _toolsFor(UserTime userTime) {
    final cached = _tools;
    if (cached != null && _toolsTimezone == userTime.ianaName) return cached;
    final services = ref.read(servicesProvider);
    final tools = LocalAgentTools(
      repo: services.repo,
      store: services.store,
      userTime: userTime,
    );
    _tools = tools;
    _toolsTimezone = userTime.ianaName;
    return tools;
  }

  void _append(AgentMessage message, {LocalChangeSet? pendingChangeSet}) {
    state = state.copyWith(
      messages: [...state.messages, message],
      pendingChangeSet: pendingChangeSet,
    );
  }

  static Map<String, dynamic> _parseArguments(String json) {
    if (json.trim().isEmpty) return const {};
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } on FormatException {
      // Fall through: the tool reports the bad arguments itself.
    }
    return const {};
  }

  static bool _isProposeChanges(String name) =>
      name == 'propose_changes' || name == 'preview_changes';

  /// Readable Chinese text; never stringifies an exception that may embed
  /// request headers (and therefore the API key).
  static String _errorText(Object error) {
    if (error is LlmException) return error.message;
    if (error is ApiException) return error.message;
    return '操作失败，请稍后重试。';
  }
}

final agentControllerProvider = NotifierProvider<AgentController, AgentState>(
  AgentController.new,
);
