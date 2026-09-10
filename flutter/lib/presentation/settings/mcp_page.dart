import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/error/api_exception.dart';
import '../../domain/mcp_token.dart';
import '../../state/app_services.dart';
import 'mcp_config.dart';

/// The MCP secret minted during this session. The server returns the plaintext
/// exactly once, so it is held in memory only (never persisted).
class McpSecretController extends Notifier<McpTokenSecret?> {
  @override
  McpTokenSecret? build() => null;

  void set(McpTokenSecret? secret) => state = secret;
}

final mcpSecretProvider =
    NotifierProvider<McpSecretController, McpTokenSecret?>(McpSecretController.new);

/// Existing long-lived credentials (prefixes only — never secrets).
final mcpTokensProvider = FutureProvider<List<McpToken>>(
  (ref) => ref.watch(servicesProvider).mcpApi.list(),
);

/// "Connect an Agent to MCP" guide (docs/mcp.md §10-§13).
///
/// Mints a long-lived MCP token on the spot and shows every value an MCP client
/// needs, each with its **own** copy button — the URL, the two parts of the
/// Authorization header, and the per-client command / JSON snippets.
class McpPage extends ConsumerStatefulWidget {
  const McpPage({super.key});

  @override
  ConsumerState<McpPage> createState() => _McpPageState();
}

class _McpPageState extends ConsumerState<McpPage> {
  final _name = TextEditingController(text: 'MCP client');
  bool _allowWrite = true;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  String get _mcpUrl => '${ref.read(servicesProvider).http.baseUrl}/mcp';

  Future<void> _mint() async {
    setState(() => _busy = true);
    try {
      final secret = await ref.read(servicesProvider).mcpApi.create(
            name: _name.text.trim().isEmpty ? 'MCP client' : _name.text.trim(),
            scopes: _allowWrite ? const ['read', 'write'] : const ['read'],
          );
      ref.read(mcpSecretProvider.notifier).set(secret);
      ref.invalidate(mcpTokensProvider);
      if (!mounted) return;
      _toast('已获取 MCP Token（${secret.tokenPrefix}…）');
    } on Object catch (e) {
      if (mounted) {
        _toast(e is ApiException ? '获取失败：${e.message}' : '获取失败：$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke(McpToken t) async {
    try {
      await ref.read(servicesProvider).mcpApi.revoke(t.id);
      ref.invalidate(mcpTokensProvider);
      if (!mounted) return;
      _toast('已吊销 ${t.tokenPrefix}…');
    } on Object catch (e) {
      if (mounted) _toast('吊销失败：$e');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) _toast('已复制「$label」');
  }

  @override
  Widget build(BuildContext context) {
    final secret = ref.watch(mcpSecretProvider);
    final tokens = ref.watch(mcpTokensProvider);
    final token = secret?.token;

    return Scaffold(
      appBar: AppBar(title: const Text('连接到 MCP')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '把课表 / 待办交给 AI Agent 操作。MCP 端点是 streamable HTTP 单一端点：\n'
              'POST <服务器>/api/v1/mcp，响应只返回 JSON。\n'
              '客户端 transport 必须选 http —— 本服务端没有 SSE 流，选 sse 会在 initialize 阶段直接失败。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),

          // ---- credential -------------------------------------------------
          const _SectionHeader('1. 获取凭证'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _name,
              decoration: const InputDecoration(labelText: '令牌名称'),
            ),
          ),
          SwitchListTile(
            value: _allowWrite,
            onChanged: (v) => setState(() => _allowWrite = v),
            title: const Text('允许写入'),
            subtitle: Text(_allowWrite
                ? '可调用写工具（仍需 preview → apply 确认）'
                : '只读：任何写工具与 apply_changes 都会被拒绝'),
            dense: true,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(
                      width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.key),
              label: const Text('一键获取 MCP Token'),
              onPressed: _busy ? null : _mint,
            ),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              '需要联网，且只能用登录会话（access token）铸造；token 只在创建响应里出现一次。',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),

          if (secret != null) ...[
            Card(
              margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      const Icon(Icons.check_circle, size: 18, color: Colors.green),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text('${secret.name}（${secret.tokenPrefix}…）',
                            style: const TextStyle(fontWeight: FontWeight.bold)),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    Text(
                      secret.expiresAt == null ? '长期有效 · 可随时吊销' : '到期 ${secret.expiresAt}',
                      style: const TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: SelectableText(
                          token!,
                          maxLines: 2,
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                        ),
                      ),
                      IconButton(
                        tooltip: '复制 Token',
                        icon: const Icon(Icons.copy, size: 18),
                        onPressed: () => _copy('Token', token),
                      ),
                    ]),
                    const Text('请立刻保存：离开后无法再次查看明文。',
                        style: TextStyle(fontSize: 11, color: Colors.orange)),
                  ],
                ),
              ),
            ),
          ],

          // ---- the four values -------------------------------------------
          const _SectionHeader('2. 连接信息'),
          if (token == null)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('先获取 Token，这里会生成可直接复制的连接配置。',
                  style: TextStyle(fontSize: 12, color: Colors.grey)),
            )
          else ...[
            _CopyRow(label: 'URL（streamable HTTP）', value: _mcpUrl, onCopy: _copy),
            _CopyRow(label: '请求头名称', value: 'Authorization', onCopy: _copy),
            _CopyRow(
              label: '请求头值',
              value: McpConfigSnippets.headerValue(token),
              onCopy: _copy,
            ),
          ],

          // ---- client snippets -------------------------------------------
          if (token != null) ...[
            const _SectionHeader('3. 客户端配置'),
            _CopyBlock(
              title: 'mcpServers 形式（Claude Desktop / .mcp.json / Cursor）',
              body: McpConfigSnippets.mcpServersJson(_mcpUrl, token),
              onCopy: _copy,
            ),
            _CopyBlock(
              title: 'VS Code / Copilot（.vscode/mcp.json，顶层键是 servers）',
              body: McpConfigSnippets.vscodeServersJson(_mcpUrl, token),
              onCopy: _copy,
            ),
            _CopyBlock(
              title: 'Claude Code 命令行',
              body: McpConfigSnippets.claudeCodeCommand(_mcpUrl, token),
              onCopy: _copy,
            ),
            _CopyBlock(
              title: '仅支持 stdio 的客户端（桥接）',
              body: McpConfigSnippets.mcpRemoteCommand(_mcpUrl, token),
              onCopy: _copy,
            ),
            _CopyBlock(
              title: '连接自检（期望返回 result.tools）',
              body: McpConfigSnippets.curlSelfCheck(_mcpUrl, token),
              onCopy: _copy,
            ),
          ],

          // ---- existing tokens -------------------------------------------
          const _SectionHeader('4. 已签发的令牌'),
          tokens.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: LinearProgressIndicator(),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                e is ApiException ? '读取失败：${e.message}' : '读取失败：$e',
                style: const TextStyle(fontSize: 12, color: Colors.red),
              ),
            ),
            data: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text('还没有令牌', style: TextStyle(fontSize: 12, color: Colors.grey)),
                  )
                : Column(
                    children: [
                      for (final t in list)
                        ListTile(
                          dense: true,
                          leading: Icon(
                            t.revoked ? Icons.block : Icons.vpn_key_outlined,
                            color: t.revoked ? Colors.grey : null,
                          ),
                          title: Text(t.name),
                          subtitle: Text(
                            '${t.tokenPrefix}… · ${t.canWrite ? "可写" : "只读"}'
                            '${t.expiresAt == null ? " · 长期" : " · 至 ${t.expiresAt}"}'
                            '${t.lastUsedAt == null ? "" : " · 最后使用 ${t.lastUsedAt}"}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: t.revoked
                              ? null
                              : IconButton(
                                  tooltip: '吊销',
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _revoke(t),
                                ),
                        ),
                    ],
                  ),
          ),

          // ---- troubleshooting -------------------------------------------
          const _SectionHeader('5. 常见失败'),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Tip('连接即 401', 'token 写错 / 已吊销；注意 Bearer 与 token 之间有一个空格。'),
                _Tip('initialize 就失败', '客户端被配成了 sse，或固定了不受支持的 MCP-Protocol-Version（支持 2025-06-18 / 2025-03-26 / 2024-11-05）。'),
                _Tip('406', '客户端的 Accept 不接受 application/json（本服务端只返回 JSON）。'),
                _Tip('写工具返回 isError', '只读 token 不能写；换成含 write 的 token。'),
                _Tip('写了"没生效"', '写工具只返回 confirmationId，必须再调 apply_changes。'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
        child: Text(text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Theme.of(context).colorScheme.primary,
            )),
      );
}

class _CopyRow extends StatelessWidget {
  const _CopyRow({required this.label, required this.value, required this.onCopy});

  final String label;
  final String value;
  final void Function(String label, String value) onCopy;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
      subtitle: SelectableText(
        value,
        maxLines: 2,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
      ),
      trailing: IconButton(
        tooltip: '复制$label',
        icon: const Icon(Icons.copy, size: 18),
        onPressed: () => onCopy(label, value),
      ),
    );
  }
}

class _CopyBlock extends StatelessWidget {
  const _CopyBlock({required this.title, required this.body, required this.onCopy});

  final String title;
  final String body;
  final void Function(String label, String value) onCopy;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                ),
                IconButton(
                  tooltip: '复制这一项',
                  icon: const Icon(Icons.copy, size: 18),
                  onPressed: () => onCopy(title, body),
                ),
              ],
            ),
            SelectableText(
              body,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.problem, this.cause);

  final String problem;
  final String cause;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: RichText(
          text: TextSpan(
            style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
            children: [
              TextSpan(
                text: '$problem　',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              TextSpan(text: cause, style: const TextStyle(color: Colors.grey)),
            ],
          ),
        ),
      );
}
