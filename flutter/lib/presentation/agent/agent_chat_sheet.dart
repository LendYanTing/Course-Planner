import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../agent/agent_config.dart';
import '../../agent/agent_prompts.dart';
import '../../agent/local_agent_tools.dart';
import '../../state/agent_controller.dart';
import '../adaptive/adaptive.dart';
import '../widgets/voice_input_button.dart';

/// Built-in agent chat panel (docs/plans/v1/phase-5-builtin-agent.md Step 4).
///
/// One sheet hosts the whole conversation: bubbles, collapsible tool rows, the
/// quick-prompt chips, and the single Change Set confirmation card that
/// [AgentController] keeps until the user confirms or cancels it. Nothing is
/// written locally before that confirmation (docs/agent-behavior.md).
class AgentChatSheet extends ConsumerStatefulWidget {
  const AgentChatSheet({super.key});

  /// Opens the panel above the current page, keyboard-aware and full width.
  static Future<void> show(BuildContext context) {
    return showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const AgentChatSheet(),
    );
  }

  @override
  ConsumerState<AgentChatSheet> createState() => _AgentChatSheetState();
}

class _AgentChatSheetState extends ConsumerState<AgentChatSheet> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  /// Sends the current input. Ignored while a request runs or a change set
  /// still waits for confirmation — the controller also guards this, but the
  /// input is cleared only for a request that really starts.
  Future<void> _submit() async {
    final text = _input.text.trim();
    if (text.isEmpty) return;
    final config = ref.read(agentConfigProvider);
    final state = ref.read(agentControllerProvider);
    if (!config.isConfigured || state.busy || state.pendingChangeSet != null) {
      return;
    }
    _input.clear();
    await ref.read(agentControllerProvider.notifier).send(text);
  }

  Future<void> _confirmReset() async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: '清空对话',
      content: const Text('清空后将无法恢复本次对话；尚未确认的修改也会一并丢弃。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
          child: const Text('清空'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    _input.clear();
    ref.read(agentControllerProvider.notifier).reset();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    final state = ref.watch(agentControllerProvider);
    final config = ref.watch(agentConfigProvider);
    final pending = state.pendingChangeSet;
    final canSend =
        config.isConfigured && !state.busy && pending == null;

    // Follow the conversation: a new bubble or the start of a request scrolls
    // to the bottom once the frame has laid the new row out.
    ref.listen<AgentState>(agentControllerProvider, (previous, next) {
      final grew = next.messages.length != (previous?.messages.length ?? 0);
      if (grew || (next.busy && previous?.busy != true)) _scrollToBottom();
    });

    return Padding(
      // The sheet itself is bottom-aligned, so lifting it by the keyboard inset
      // keeps the input row visible without covering the message list.
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: FractionallySizedBox(
        alignment: Alignment.bottomCenter,
        heightFactor: 0.88,
        child: ClipRRect(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(tokens.sheetRadius),
          ),
          child: Material(
            color: scheme.surfaceContainerLow,
            child: Column(
              children: [
                _buildHeader(context, state),
                Divider(height: 1, color: scheme.outlineVariant),
                Expanded(child: _buildMessages(context, state)),
                if (!config.isConfigured) _buildSetupGuide(context),
                _buildInput(context, state, canSend: canSend),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AgentState state) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.auto_awesome, size: 20, color: scheme.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'AI 助手',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: state.messages.isEmpty && state.pendingChangeSet == null
                ? null
                : _confirmReset,
            child: const Text('清空'),
          ),
          IconButton(
            tooltip: '关闭',
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildMessages(BuildContext context, AgentState state) {
    final pending = state.pendingChangeSet;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
      children: [
        if (state.messages.isEmpty && !state.busy) _buildWelcome(context),
        for (final message in state.messages) _buildMessage(context, message),
        if (pending != null)
          ChangeSetConfirmationCard(
            changeSet: pending,
            busy: state.busy,
            onCancel: ref.read(agentControllerProvider.notifier).cancelPending,
            onConfirm: ref.read(agentControllerProvider.notifier).confirmPending,
          ),
        if (state.busy) _buildThinking(context),
      ],
    );
  }

  Widget _buildWelcome(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final config = ref.watch(agentConfigProvider);
    final state = ref.watch(agentControllerProvider);
    final chipsEnabled =
        config.isConfigured && !state.busy && state.pendingChangeSet == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '你好，我是 Course Planner 的内置 AI 助手。',
          style: Theme.of(
            context,
          ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          '可以帮你总结日程、拆分任务并安排时间。所有写入都会先汇总成一张确认卡片，'
          '只有你点「全部确认」后才会真正保存。',
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          '试试下面的快捷指令：',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final prompt in kAgentQuickPrompts)
              ActionChip(
                label: Text(prompt),
                onPressed: chipsEnabled ? () => _sendPrompt(prompt) : null,
              ),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Future<void> _sendPrompt(String prompt) async {
    final state = ref.read(agentControllerProvider);
    if (!ref.read(agentConfigProvider).isConfigured ||
        state.busy ||
        state.pendingChangeSet != null) {
      return;
    }
    await ref.read(agentControllerProvider.notifier).send(prompt);
  }

  Widget _buildMessage(BuildContext context, AgentMessage message) {
    if (message.toolLabel != null || message.role == AgentRole.tool) {
      return _ToolRow(message: message);
    }
    final scheme = Theme.of(context).colorScheme;
    final isUser = message.role == AgentRole.user;
    final background = isUser
        ? scheme.primary
        : (message.isError ? scheme.errorContainer : scheme.surfaceContainerHighest);
    final foreground = isUser
        ? scheme.onPrimary
        : (message.isError ? scheme.onErrorContainer : scheme.onSurface);
    final radius = Radius.circular(14);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.sizeOf(context).width * 0.82,
        ),
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: background,
          borderRadius: BorderRadius.only(
            topLeft: radius,
            topRight: radius,
            bottomLeft: isUser ? radius : const Radius.circular(4),
            bottomRight: isUser ? const Radius.circular(4) : radius,
          ),
        ),
        child: Text(
          message.text,
          style: TextStyle(color: foreground, fontSize: 14, height: 1.4),
        ),
      ),
    );
  }

  Widget _buildThinking(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '思考中…',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  /// Shown above the input while no key is configured. The chat stays readable
  /// so the user sees why nothing can be sent, and one tap opens the settings.
  Widget _buildSetupGuide(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: AppCard(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            Icon(Icons.key_off_outlined, size: 22, color: scheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '尚未配置大模型',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '选择服务商并填写 API Key 后即可开始对话。',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => context.push('/settings/agent'),
              child: const Text('去配置'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInput(
    BuildContext context,
    AgentState state, {
    required bool canSend,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final config = ref.watch(agentConfigProvider);
    final pending = state.pendingChangeSet != null;
    final hint = !config.isConfigured
        ? '请先在上方完成配置'
        : state.busy
        ? '请稍候…'
        : pending
        ? '请先确认或取消上面的修改'
        : '告诉我你想怎么安排…';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: TextField(
              controller: _input,
              enabled: config.isConfigured,
              minLines: 1,
              maxLines: 4,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) async => _submit(),
              decoration: InputDecoration(
                isDense: true,
                hintText: hint,
                filled: true,
                fillColor: scheme.surfaceContainerHighest,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          // Voice input: the transcription is appended to the draft and never
          // sent on its own, so it can still be edited before submitting.
          VoiceInputButton(
            tooltip: '语音输入消息',
            onText: (text) {
              final current = _input.text;
              final next = current.isEmpty ? text : '$current$text';
              _input.value = TextEditingValue(
                text: next,
                selection: TextSelection.collapsed(offset: next.length),
              );
            },
          ),
          const SizedBox(width: 4),
          IconButton.filled(
            tooltip: '发送',
            onPressed: canSend ? _submit : null,
            icon: const Icon(Icons.send),
          ),
        ],
      ),
    );
  }
}

/// One collapsed tool-progress row. The payload is JSON and only expands on
/// demand so a normal chat stays readable.
class _ToolRow extends StatelessWidget {
  const _ToolRow({required this.message});

  final AgentMessage message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        visualDensity: VisualDensity.compact,
        leading: Icon(
          Icons.build_outlined,
          size: 16,
          color: scheme.onSurfaceVariant,
        ),
        title: Text(
          message.toolLabel ?? '工具结果',
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              message.text,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                fontFamily: 'monospace',
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The single confirmation card for one user request
/// (docs/agent-behavior.md §Confirmation).
///
/// Every entry carries a `+` / `~` / `-` badge (create / update / delete) and
/// an optional conflict warning. Both buttons are disabled while the change
/// set is being applied, so it can never be confirmed twice.
class ChangeSetConfirmationCard extends StatelessWidget {
  const ChangeSetConfirmationCard({
    super.key,
    required this.changeSet,
    required this.onCancel,
    required this.onConfirm,
    this.busy = false,
  });

  final LocalChangeSet changeSet;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: EdgeInsets.zero,
      margin: const EdgeInsets.only(top: 2, bottom: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(Icons.edit_note, size: 20, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '即将修改你的日程与待办（共 ${changeSet.length} 项）',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              '确认后会一次性应用；应用前不会改动任何数据。',
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            ),
            for (final item in changeSet.items) _buildItem(context, item),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: busy ? null : onCancel,
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: busy ? null : onConfirm,
                    child: busy
                        ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: scheme.onPrimary,
                            ),
                          )
                        : const Text('全部确认'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, LocalChangeItem item) {
    final scheme = Theme.of(context).colorScheme;
    final badge = _badgeFor(context, item.kind);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: badge.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              badge.symbol,
              style: TextStyle(
                fontSize: 13,
                height: 1,
                fontWeight: FontWeight.w700,
                color: badge.color,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.summary,
                  style: const TextStyle(fontSize: 13, height: 1.35),
                ),
                if (item.conflictWarning != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item.conflictWarning!,
                      style: TextStyle(fontSize: 11, color: scheme.error),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// `+` for creations, `-` for deletions/cancellations, `~` for everything
  /// else (updates and moves).
  static ({String symbol, Color color}) _badgeFor(
    BuildContext context,
    String kind,
  ) {
    final scheme = Theme.of(context).colorScheme;
    if (kind.startsWith('create_') || kind.startsWith('add_')) {
      return (symbol: '+', color: Colors.green);
    }
    if (kind.startsWith('delete_') ||
        kind.startsWith('cancel_') ||
        kind.startsWith('remove_')) {
      return (symbol: '-', color: scheme.error);
    }
    return (symbol: '~', color: Colors.blue);
  }
}
