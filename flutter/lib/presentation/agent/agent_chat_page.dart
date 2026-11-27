import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/agent_controller.dart';
import '../adaptive/adaptive.dart';
import 'agent_chat_sheet.dart';

/// Full-screen built-in agent tab (`/home/agent`).
///
/// The third bottom-bar tab: the same conversation as [AgentChatSheet], but
/// always one tap away. [HomeShell] draws the floating nav bar over the page
/// (`extendBody: true`), so the input row reserves [navBarClearance] on top of
/// the system safe area — the send button never hides under the capsule.
class AgentChatPage extends ConsumerStatefulWidget {
  const AgentChatPage({super.key});

  /// Extra breathing space above the floating bottom bar.
  ///
  /// The bar's own height is already folded into `MediaQuery.padding.bottom`
  /// by the shell's `Scaffold(extendBody: true)`, so this is only the gap
  /// between the input row and the capsule's top edge.
  static const double navBarClearance = 8;

  @override
  ConsumerState<AgentChatPage> createState() => _AgentChatPageState();
}

class _AgentChatPageState extends ConsumerState<AgentChatPage> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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
    final state = ref.watch(agentControllerProvider);
    final bottomInset =
        MediaQuery.paddingOf(context).bottom + AgentChatPage.navBarClearance;

    return Scaffold(
      appBar: AppTopBar(
        title: 'AI 助手',
        actions: [
          IconButton(
            tooltip: '清空对话',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: state.messages.isEmpty && state.pendingChangeSet == null
                ? null
                : _confirmReset,
          ),
          IconButton(
            tooltip: 'AI 设置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => context.push('/settings/agent'),
          ),
        ],
      ),
      body: AgentChatBody(
        input: _input,
        scroll: _scroll,
        bottomPadding: bottomInset,
      ),
    );
  }
}
