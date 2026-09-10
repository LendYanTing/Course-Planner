import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../data/auth/server_store.dart';
import '../../state/app_services.dart';
import '../../state/session.dart';

/// Server selection + migration direction (multi-server support).
///
/// The user may point the app at any Course Planner backend. Because the local
/// database holds one server's working copy, switching asks which side wins
/// before moving data.
class ServerPage extends ConsumerStatefulWidget {
  const ServerPage({super.key});

  @override
  ConsumerState<ServerPage> createState() => _ServerPageState();
}

class _ServerPageState extends ConsumerState<ServerPage> {
  final _url = TextEditingController();
  List<KnownServer> _known = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _url.text = ref.read(servicesProvider).http.baseUrl;
    _load();
  }

  Future<void> _load() async {
    final known = await ref.read(servicesProvider).serverStore.known();
    if (!mounted) return;
    setState(() => _known = known);
  }

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _switchTo(String rawUrl) async {
    final normalized = AppConfig.normalizeBaseUrl(rawUrl);
    final current = ref.read(servicesProvider).http.baseUrl;
    final direction = await _askDirection(normalized, isSameAsCurrent: normalized == current);
    if (direction == null || !mounted) return;

    setState(() => _busy = true);
    final err = await ref
        .read(sessionControllerProvider.notifier)
        .switchServer(rawUrl: normalized, cloudToLocal: direction);
    if (!mounted) return;
    setState(() => _busy = false);

    if (err == 'needsLogin') {
      // The router redirects to /login because the session went signed-out;
      // the chosen direction is parked and replays after sign-in.
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该服务器需要登录，已记住你的选择，登录后自动执行')),
      );
      return;
    }
    if (err != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('切换失败: $err')));
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换到 $normalized')),
    );
    if (mounted) Navigator.of(context).pop();
  }

  /// Asks which side wins. Returns true for cloud→local, false for local→cloud.
  Future<bool?> _askDirection(String url, {required bool isSameAsCurrent}) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('切换服务器'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('目标服务器：$url', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            if (isSameAsCurrent)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('与当前服务器相同，将重新执行一次同步方向选择。',
                    style: TextStyle(fontSize: 12, color: Colors.orange)),
              ),
            const Text('本地数据与云端数据该如何合并？'),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('本地覆盖云端'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('云端覆盖本地'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final services = ref.watch(servicesProvider);
    final active = services.http.baseUrl;
    return Scaffold(
      appBar: AppBar(title: const Text('服务器')),
      body: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.dns),
            title: const Text('当前服务器'),
            subtitle: Text(active),
          ),
          const Divider(),
          if (_known.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('曾经连接过', style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
            for (final s in _known)
              ListTile(
                leading: Icon(s.baseUrl == active ? Icons.check_circle : Icons.dns_outlined,
                    color: s.baseUrl == active ? Theme.of(context).colorScheme.primary : null),
                title: Text(s.baseUrl),
                subtitle: s.username == null ? null : Text('上次登录：${s.username}'),
                onTap: _busy ? null : () => _switchTo(s.baseUrl),
              ),
            const Divider(),
          ],
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('切换到其它服务器', style: TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: 'http://192.168.1.10:8080',
                helperText: '不带路径时会自动补 /api/v1',
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: FilledButton.icon(
              icon: _busy
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.swap_horiz),
              label: const Text('切换并选择同步方向'),
              onPressed: _busy ? null : () => _switchTo(_url.text),
            ),
          ),
          const SizedBox(height: 24),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              '说明：\n'
              '· 云端覆盖本地 —— 清空本地缓存，从目标服务器重新拉取全部数据；\n'
              '· 本地覆盖云端 —— 保留本地数据，并将其上传到目标服务器；\n'
              '· 登录凭据按服务器分别保存，切换不会串用。',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }
}
