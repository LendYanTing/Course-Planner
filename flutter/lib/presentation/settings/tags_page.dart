import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/local/view_models.dart';
import '../../domain/entities.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';
import 'courses_page.dart' show kPalette;

/// Tag & category manager (docs/domain-model.md §10-11).
class TagsPage extends ConsumerStatefulWidget {
  const TagsPage({super.key});

  @override
  ConsumerState<TagsPage> createState() => _TagsPageState();
}

class _TagsPageState extends ConsumerState<TagsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    final onTagTab = _tabs.index == 0;

    return Scaffold(
      appBar: AppBar(
        title: const Text('标签 / 分类'),
        bottom: TabBar(
          controller: _tabs,
          tabs: [
            Tab(text: '标签 (${tags.length})'),
            Tab(text: '分类 (${categories.length})'),
          ],
        ),
      ),
      // Always available: previously "add" only appeared when a list was
      // empty, so an existing non-empty list had no way to add another entry.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _add(onTagTab ? EntityTypes.tag : EntityTypes.category),
        icon: const Icon(Icons.add),
        label: Text(onTagTab ? '新建标签' : '新建分类'),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          _List(
            entries: tags.map((e) => (id: e.value.id, name: e.value.name, color: e.value.color, pending: e.pending)).toList(),
            emptyLabel: '还没有标签',
            onAdd: () => _add(EntityTypes.tag),
            onDelete: (id) => _delete(EntityTypes.tag, id),
          ),
          _List(
            entries: categories.map((e) => (id: e.value.id, name: e.value.name, color: e.value.color, pending: e.pending)).toList(),
            emptyLabel: '还没有分类',
            onAdd: () => _add(EntityTypes.category),
            onDelete: (id) => _delete(EntityTypes.category, id),
          ),
        ],
      ),
    );
  }

  Future<void> _add(String type) async {
    final name = TextEditingController();
    String? color;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(type == EntityTypes.tag ? '新建标签' : '新建分类'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: '名称')),
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                children: [
                  for (final hex in kPalette)
                    InkWell(
                      onTap: () => setDialogState(() => color = hex),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: AppTheme.parseHex(hex),
                          shape: BoxShape.circle,
                          border: Border.all(color: color == hex ? Colors.black : Colors.transparent, width: 2),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(
              onPressed: () {
                if (name.text.trim().isNotEmpty) {
                  ref.read(servicesProvider).repo.localCreate(
                    entityType: type,
                    snapshot: {'name': name.text.trim(), 'color': color},
                  );
                  ref.read(syncCoordinatorProvider.notifier).syncNow();
                }
                Navigator.pop(ctx);
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
  }

  Future<void> _delete(String type, String id) async {
    await ref.read(servicesProvider).repo.localDelete(entityType: type, entityId: id);
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.entries,
    required this.onAdd,
    required this.onDelete,
    this.emptyLabel = '暂无数据',
  });

  final List<({String id, String name, String? color, bool pending})> entries;
  final VoidCallback onAdd;
  final ValueChanged<String> onDelete;
  final String emptyLabel;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(emptyLabel),
            TextButton(onPressed: onAdd, child: const Text('添加')),
          ],
        ),
      );
    }
    return ListView(
      // Leave room for the floating action button.
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        for (final e in entries)
          ListTile(
            leading: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(color: AppTheme.parseHex(e.color) ?? Colors.grey, shape: BoxShape.circle),
            ),
            title: Text('${e.name}${e.pending ? ' ⏳' : ''}'),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => onDelete(e.id),
            ),
          ),
      ],
    );
  }
}
