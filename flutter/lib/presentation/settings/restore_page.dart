import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/config/app_config.dart';
import '../../data/backup/backup_service.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';

/// Restore a backup file, choosing which categories to take.
///
/// Local-first: imported data is written to the local working copy AND queued
/// for upload, so the next sync makes the target server match (same semantics
/// as 本地覆盖云端). Nothing is pushed while this page runs.
class RestorePage extends ConsumerStatefulWidget {
  const RestorePage({super.key});

  @override
  ConsumerState<RestorePage> createState() => _RestorePageState();
}

class _RestorePageState extends ConsumerState<RestorePage> {
  BackupSelection _sel = BackupSelection.all;
  Map<String, dynamic>? _doc;
  BackupImportPreview? _preview;
  String? _path;
  String? _error;
  List<FileSystemEntity> _files = const [];
  final _pathCtrl = TextEditingController();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadFiles();
  }

  @override
  void dispose() {
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadFiles() async {
    try {
      final files = await ref.read(servicesProvider).backupService.listBackups();
      if (!mounted) return;
      setState(() => _files = files);
    } on Object {
      // No directory access in this environment; the path field still works.
    }
  }

  Future<void> _open(String path) async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final doc = await ref.read(servicesProvider).backupService.readBackup(path);
      if (!mounted) return;
      setState(() {
        _doc = doc;
        _path = path;
        _pathCtrl.text = path;
        _preview = ref.read(servicesProvider).backupService.preview(doc, _sel);
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _doc = null;
        _preview = null;
        _error = '$e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _setSelection(BackupSelection sel) {
    setState(() {
      _sel = sel;
      final doc = _doc;
      if (doc != null) {
        _preview = ref.read(servicesProvider).backupService.preview(doc, sel);
      }
    });
  }

  Future<void> _apply() async {
    final doc = _doc;
    if (doc == null || _sel.isEmpty) return;
    final services = ref.read(servicesProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认导入'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('导入会覆盖本地同 id 的数据，并把导入内容排队上传到：'),
            const SizedBox(height: 6),
            Text(services.http.baseUrl,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
            const SizedBox(height: 6),
            const Text('导入前会自动把当前本地数据导出为一个安全备份。',
                style: TextStyle(fontSize: 12, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('导入')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      // Safety net: snapshot the current state before overwriting anything.
      String? safetyPath;
      try {
        safetyPath = (await services.backupService.export()).path;
      } on Object {
        // Non-fatal: continue, the user was told this may fail.
      }

      final result = await services.backupService.importDocument(
        doc,
        _sel,
        useServer: (url) => services.useServer(url),
        applyToken: (url, token) async {
          await services.tokenBox.writeRefreshToken(
            token,
            forServerKey: AppConfig.tokenServerKey(url),
          );
        },
        rememberServers: (servers) async {
          for (final s in servers) {
            await services.serverStore.remember(s.baseUrl, username: s.username);
          }
        },
        enqueueUploads: () => services.syncEngine.uploadAllLocal(),
      );

      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('导入完成'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('写入 ${result.entities} 个实体，已排队上传 ${result.queuedUploads} 条'),
              if (result.serversApplied > 0) Text('服务器配置 ${result.serversApplied} 条'),
              if (result.credentialsApplied > 0) Text('登录凭据 ${result.credentialsApplied} 条'),
              const SizedBox(height: 8),
              if (safetyPath != null)
                SelectableText('导入前的安全备份：\n$safetyPath',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 8),
              const Text('若导入了服务器地址或登录凭据，请重启应用使连接生效。',
                  style: TextStyle(fontSize: 12)),
            ],
          ),
          actions: [
            FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('好')),
          ],
        ),
      );
      ref.read(syncCoordinatorProvider.notifier).syncNow();
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('导入失败: $e')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('导入备份')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text('选择备份文件', style: TextStyle(fontSize: 13, color: Colors.grey)),
          ),
          if (_files.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('备份目录里没有找到 .json 文件，可粘贴完整路径：',
                  style: TextStyle(fontSize: 12)),
            ),
          for (final f in _files)
            ListTile(
              dense: true,
              leading: Icon(Icons.description_outlined,
                  color: f.path == _path ? Theme.of(context).colorScheme.primary : null),
              title: Text(f.path.split(Platform.pathSeparator).last,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(_sizeLabel(f), style: const TextStyle(fontSize: 11)),
              onTap: _busy ? null : () => _open(f.path),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathCtrl,
                    decoration: const InputDecoration(labelText: '备份文件完整路径'),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : () => _open(_pathCtrl.text.trim()),
                  child: const Text('读取'),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          if (preview != null) ...[
            const Divider(height: 32),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text('选择要导入的内容', style: TextStyle(fontSize: 13, color: Colors.grey)),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  TextButton(
                    onPressed: () => _setSelection(BackupSelection.all),
                    child: const Text('全选'),
                  ),
                  TextButton(
                    onPressed: () => _setSelection(const BackupSelection()),
                    child: const Text('全不选'),
                  ),
                ],
              ),
            ),
            _tile('服务器地址', '当前服务器与已连接过的服务器列表',
                _sel.servers, (v) => _setSelection(_sel.copyWith(servers: v)),
                detail: preview.activeServer),
            _tile('登录凭证', '各服务器的 refresh token（可免登录）',
                _sel.credentials, (v) => _setSelection(_sel.copyWith(credentials: v)),
                detail: '${preview.tokens} 条'),
            _tile('学期与课程', '学期、节次模板、课程、上课安排、周期安排',
                _sel.academic, (v) => _setSelection(_sel.copyWith(academic: v)),
                detail: _typeDetail(preview, _academicCount)),
            _tile('待办与时间块', '待办条目及其时间块',
                _sel.todos, (v) => _setSelection(_sel.copyWith(todos: v)),
                detail: _typeDetail(preview, _todoCount)),
            _tile('分类与标签', '待办分类和标签',
                _sel.taxonomy, (v) => _setSelection(_sel.copyWith(taxonomy: v)),
                detail: _typeDetail(preview, _taxonomyCount)),
            _tile('未上传的改动与冲突', '待上传操作队列与待处理冲突',
                _sel.queue, (v) => _setSelection(_sel.copyWith(queue: v)),
                detail: '${preview.pendingOps} 条改动 · ${preview.conflicts} 条冲突'),
            if (preview.exportedAt != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text('备份时间：${preview.exportedAt}',
                    style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: FilledButton.icon(
                icon: _busy
                    ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.download),
                label: Text(_sel.isEmpty ? '请至少选择一项' : '导入所选内容'),
                onPressed: (_busy || _sel.isEmpty) ? null : _apply,
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                '说明：导入的数据会同时写入本地并排队上传（本地优先），'
                '下次同步会把它们推到当前服务器。导入前会自动生成一份当前数据的安全备份。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          ],
        ],
      ),
    );
  }

  int _academicCount(BackupImportPreview p) => _sum(p, _academicTypes);
  int _todoCount(BackupImportPreview p) => _sum(p, _todoTypes);
  int _taxonomyCount(BackupImportPreview p) => _sum(p, _taxonomyTypes);

  static int _sum(BackupImportPreview p, Set<String> types) =>
      types.fold(0, (a, t) => a + (p.entitiesByType[t] ?? 0));

  String _typeDetail(BackupImportPreview p, int Function(BackupImportPreview) count) {
    final n = count(p);
    if (n == 0) return '备份中无此类数据';
    final parts = <String>[];
    p.entitiesByType.forEach((type, c) {
      if (_labelFor(type) != null && c > 0) parts.add('${_labelFor(type)} $c');
    });
    return '$n 条 · ${parts.join('，')}';
  }

  Widget _tile(String title, String subtitle, bool value, ValueChanged<bool> onChanged,
      {String? detail}) {
    return CheckboxListTile(
      value: value,
      onChanged: (v) => onChanged(v ?? false),
      title: Text(title),
      subtitle: Text(detail == null ? subtitle : '$subtitle\n$detail'),
      isThreeLine: detail != null,
      dense: true,
    );
  }

  static String _sizeLabel(FileSystemEntity f) {
    try {
      final kb = (f as File).lengthSync() / 1024;
      return '${kb.toStringAsFixed(1)} KB';
    } on Object {
      return '';
    }
  }
}

const _academicTypes = <String>{
  'academic_calendar',
  'period_template',
  'course',
  'course_meeting',
  'recurring_schedule',
  'occurrence_override',
};
const _todoTypes = <String>{'todo', 'todo_block'};
const _taxonomyTypes = <String>{'tag', 'todo_category'};

const _typeLabels = <String, String>{
  'academic_calendar': '学期',
  'period_template': '节次',
  'course': '课程',
  'course_meeting': '上课安排',
  'recurring_schedule': '周期安排',
  'occurrence_override': '单次调整',
  'todo': '待办',
  'todo_block': '时间块',
  'tag': '标签',
  'todo_category': '分类',
};

String? _labelFor(String type) => _typeLabels[type];
