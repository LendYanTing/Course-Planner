import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/config/app_info.dart';
import '../../core/error/api_exception.dart';
import '../../data/api/github_api.dart';
import '../../state/app_services.dart';

/// App version, update check and links to the project.
///
/// The update check reads `releases/latest` from GitHub; it needs to reach
/// api.github.com, which is not possible everywhere, so failures are reported
/// plainly and the project/release pages stay reachable as links.
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  bool _busy = false;
  String? _error;
  ReleaseInfo? _release;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _error = null;
      _release = null;
    });
    try {
      final release =
          await ref.read(servicesProvider).githubApi.latestRelease(AppInfo.latestReleaseApi);
      if (!mounted) return;
      setState(() => _release = release);
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is ApiException
            ? '${e.message}（无法访问 GitHub，可能需要代理）'
            : '检查更新失败：$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok && mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('无法打开链接：$url')));
    }
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已复制$label')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final release = _release;
    final hasUpdate =
        release != null && compareVersions(release.tag, AppInfo.version) > 0;

    return Scaffold(
      appBar: AppBar(title: const Text('关于')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 16),
          Center(
            child: Column(
              children: [
                Icon(Icons.event_note, size: 56, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                const Text('Course Planner',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text('版本 ${AppInfo.versionLabel}',
                    style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Divider(height: 1),

          ListTile(
            leading: const Icon(Icons.system_update_alt),
            title: const Text('检查更新'),
            subtitle: Text(
              _busy
                  ? '正在检查…'
                  : release == null
                      ? '从 GitHub 读取最新版本'
                      : hasUpdate
                          ? '发现新版本 ${release.tag}（当前 ${AppInfo.version}）'
                          : '已是最新版本（${AppInfo.version}）',
            ),
            trailing: _busy
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.chevron_right),
            onTap: _busy ? null : _check,
          ),

          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(_error!, style: const TextStyle(fontSize: 12, color: Colors.red)),
            ),

          if (release != null && hasUpdate) ...[
            Card(
              margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('${release.name}（${release.tag}）',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (release.publishedAt != null)
                      Text('发布于 ${release.publishedAt!.split('T').first}',
                          style: const TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 8),
                    if (release.notes.trim().isNotEmpty)
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 220),
                        child: SingleChildScrollView(
                          child: SelectableText(release.notes,
                              style: const TextStyle(fontSize: 12)),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(children: [
                      if (release.apkUrl != null)
                        Expanded(
                          child: FilledButton.icon(
                            icon: const Icon(Icons.download),
                            label: const Text('下载更新'),
                            onPressed: () => _open(release.apkUrl!),
                          ),
                        ),
                      if (release.apkUrl != null) const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => _open(release.htmlUrl),
                          child: const Text('打开发布页'),
                        ),
                      ),
                    ]),
                    if (release.apkUrl != null) ...[
                      const SizedBox(height: 4),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          icon: const Icon(Icons.copy, size: 16),
                          label: const Text('复制 APK 链接', style: TextStyle(fontSize: 12)),
                          onPressed: () => _copy('APK 链接', release.apkUrl!),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],

          if (release != null && !hasUpdate)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('最新版本 ${release.tag} · ${release.name}',
                  style: const TextStyle(fontSize: 12, color: Colors.grey)),
            ),

          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.code),
            title: const Text('项目主页'),
            subtitle: const Text(AppInfo.repoUrl),
            onTap: () => _open(AppInfo.repoUrl),
          ),
          ListTile(
            leading: const Icon(Icons.new_releases_outlined),
            title: const Text('全部版本'),
            subtitle: const Text(AppInfo.releasesUrl),
            onTap: () => _open(AppInfo.releasesUrl),
          ),
        ],
      ),
    );
  }
}
