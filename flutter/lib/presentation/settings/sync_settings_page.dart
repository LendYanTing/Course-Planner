import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../state/app_services.dart';
import '../../state/prefs.dart';
import '../../state/session.dart';
import '../../state/sync_controller.dart';
import '../adaptive/adaptive.dart';

/// 云同步与服务器 (`/settings/sync`).
///
/// Holds everything that talks to the server: automatic sync, manual sync,
/// conflicts, network recovery and the server address. A local (no-account)
/// session only sees the "data stays on this device" hint and a way to sign in.
class SyncSettingsPage extends ConsumerWidget {
  const SyncSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(sessionControllerProvider);
    final sync = ref.watch(syncCoordinatorProvider);
    final snap = ref.watch(snapshotProvider).value;
    final pending = snap?.pendingOps.length ?? 0;
    final conflicts = snap?.conflicts ?? const [];
    final syncEnabled = ref.watch(syncEnabledProvider);
    final baseUrl = ref.watch(servicesProvider).http.baseUrl;
    final errorColor = Theme.of(context).colorScheme.error;

    // Local mode has no server to talk to: status + sign-in hint only.
    final statusSubtitle = session.isLocalMode
        ? (pending > 0 ? '数据保存在本机 · $pending 条待上传' : '数据保存在本机')
        : [
            if (session.profile?.username.isNotEmpty == true)
              '账号: ${session.profile!.username}',
            if (pending > 0) '$pending 条待上传',
            if (sync.lastError != null) '上次出错: ${sync.lastError}',
            sync.lastSyncAt == null ? '尚未同步' : '上次同步: ${_time(sync.lastSyncAt!)}',
            if (sync.lastError != null) '点按查看详细报错',
          ].join(' · ');

    return Scaffold(
      appBar: AppTopBar(title: '云同步与服务器'),
      body: ListView(
        // Keeps the last row clear of the system inset.
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          AppCard(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: ListTile(
              leading: Icon(
                session.isLocalMode
                    ? Icons.smartphone
                    : (sync.lastError == null ? Icons.cloud_sync_outlined : Icons.sync_problem),
                color: !session.isLocalMode && sync.lastError != null ? errorColor : null,
              ),
              title: Text(session.isLocalMode
                  ? '本地模式'
                  : (sync.syncing ? '正在同步…' : '同步状态')),
              subtitle: Text(statusSubtitle),
              // Tapping surfaces the full failure report (cursor, queue depth,
              // error code/status/message/details, stack) so a failure can be
              // copied out instead of needing a debugger attached.
              onTap: session.isLocalMode || sync.lastError == null
                  ? null
                  : () => _showSyncDetail(context, sync),
              trailing: !session.isLocalMode && sync.lastError != null
                  ? const Icon(Icons.chevron_right)
                  : null,
            ),
          ),
          if (session.isLocalMode) ...[
            AppCard(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                children: [
                  const ListTile(
                    leading: Icon(Icons.person_outline),
                    title: Text('数据保存在本机'),
                    subtitle: Text('登录云端账号后可开启自动云同步'),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () => context.go('/login'),
                        child: const Text('登录云端账号'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ] else ...[
            AppCard(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                children: [
                  // Local-first: once signed in the user opts into automatic
                  // sync here; switching it off keeps every edit on the device.
                  SwitchListTile(
                    value: syncEnabled,
                    onChanged: (v) => ref.read(syncEnabledProvider.notifier).set(v),
                    secondary: const Icon(Icons.cloud_sync_outlined),
                    title: const Text('自动云同步'),
                    subtitle: const Text('关闭后所有修改只保存在本机'),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync),
                    title: const Text('立即同步'),
                    subtitle: Text(sync.syncing ? '正在同步…' : '推送本地修改并拉取服务器最新数据'),
                    trailing: sync.syncing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right),
                    onTap: sync.syncing
                        ? null
                        : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
                  ),
                  ListTile(
                    leading: const Icon(Icons.sync_problem),
                    title: const Text('冲突处理'),
                    subtitle: Text(conflicts.isEmpty
                        ? '无待处理冲突'
                        : '${conflicts.length} 个字段冲突需要决定'),
                    trailing: conflicts.isEmpty ? null : const Icon(Icons.chevron_right),
                    onTap: conflicts.isEmpty ? null : () => context.push('/settings/conflicts'),
                  ),
                ],
              ),
            ),
            AppCard(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.wifi_off_outlined),
                    title: const Text('重置网络连接'),
                    subtitle: const Text('同步一直卡住或超时时用：丢弃现有连接并重新同步（超时会自动执行）'),
                    onTap: () => _resetNetwork(context, ref),
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('硬刷新本地缓存'),
                    subtitle: const Text('保留未上传修改，从服务器重建本地数据'),
                    onTap: () async {
                      final ok = await showAppDialog<bool>(
                        context: context,
                        title: '硬刷新？',
                        content: const Text('将清空本地缓存并按服务器重建（未上传的修改会保留并重放）。'),
                        actions: [
                          TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('取消')),
                          FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('硬刷新')),
                        ],
                      );
                      if (ok == true) {
                        await ref.read(syncCoordinatorProvider.notifier).hardRefresh();
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
          AppCard(
            padding: EdgeInsets.zero,
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('服务器'),
                  subtitle: Text(baseUrl),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/settings/server'),
                ),
                ListTile(
                  leading: const Icon(Icons.swap_horiz),
                  title: const Text('切换/登录账号'),
                  subtitle: Text(session.isLocalMode
                      ? '登录云端账号后可开启自动云同步'
                      : '切换服务器或登录其它账号'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.go('/login'),
                ),
              ],
            ),
          ),
          // Signing out is an account action, so it sits here rather than on
          // the settings hub. A local session has nothing to sign out of.
          if (!session.isLocalMode)
            AppCard(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: ListTile(
                leading: Icon(Icons.logout, color: errorColor),
                title: Text('退出登录', style: TextStyle(color: errorColor)),
                onTap: () => _confirmLogout(context, ref),
              ),
            ),
        ],
      ),
    );
  }
}

String _time(DateTime utc) {
  final l = utc.toLocal();
  return '${l.hour.toString().padLeft(2, '0')}:${l.minute.toString().padLeft(2, '0')}:${l.second.toString().padLeft(2, '0')}';
}

/// Asks before signing out: local data stays on the device, but the cloud
/// account has to log in again before it can sync.
Future<void> _confirmLogout(BuildContext context, WidgetRef ref) async {
  final ok = await showAppDialog<bool>(
    context: context,
    title: '退出登录？',
    content: const Text('本地数据会保留，云端账号需要重新登录才能同步。'),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
        child: const Text('退出'),
      ),
    ],
  );
  if (ok != true || !context.mounted) return;
  await ref.read(sessionControllerProvider.notifier).logout();
}

/// Drops the current connections and re-syncs. The same thing happens
/// automatically after a sync timeout, but a manual trigger makes a wedged app
/// recoverable without killing it.
Future<void> _resetNetwork(BuildContext context, WidgetRef ref) async {
  final ok = await showAppDialog<bool>(
    context: context,
    title: '重置网络连接？',
    content: const Text('会中断正在进行的同步，丢弃现有连接后重新读取服务器时间并同步一次。'
        '不会删除本地数据。'),
    actions: [
      TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(false), child: const Text('取消')),
      FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(true), child: const Text('重置')),
    ],
  );
  if (ok != true || !context.mounted) return;
  final messenger = ScaffoldMessenger.of(context);
  await ref.read(syncCoordinatorProvider.notifier).resetNetworkState(reason: '手动');
  messenger.showSnackBar(const SnackBar(content: Text('已重置网络连接并重新同步')));
}

/// Shows the last sync failure in full. The text is selectable and copyable so
/// it can be pasted into a bug report.
Future<void> _showSyncDetail(BuildContext context, SyncUiState sync) async {
  final detail = sync.lastErrorDetail ?? sync.lastError ?? '(无详情)';
  await showAppDialog<void>(
    context: context,
    title: '同步失败详情',
    content: SizedBox(
      width: double.maxFinite,
      child: SingleChildScrollView(
        child: SelectableText(
          detail,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: detail));
          if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
          if (context.mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(const SnackBar(content: Text('已复制报错详情')));
          }
        },
        child: const Text('复制'),
      ),
      FilledButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('关闭')),
    ],
  );
}
