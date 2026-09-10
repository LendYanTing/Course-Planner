import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/local/view_models.dart';
import '../../domain/entities.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../settings/courses_page.dart' show kPalette;
import 'todo_blocks_sheet.dart';

/// Todo list (docs/domain-model.md §7-9): one_off / project, priority, status,
/// deadline, estimated duration, tags/categories, linked blocks.
class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  bool _showCompleted = false;
  final Set<String> _filterTagIds = {};
  final Set<String> _collapsed = {};

  bool _matchesFilters(Todo t) {
    if (_filterTagIds.isNotEmpty && !_filterTagIds.any(t.tagIds.contains)) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final syncState = ref.watch(syncCoordinatorProvider);
    final todos = snap == null ? <Live<Todo>>[] : liveTodos(snap);
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    final blocks = snap == null ? <Live<TodoBlock>>[] : liveBlocks(snap);

    final open = todos.where((t) => !t.value.isCompleted && _matchesFilters(t.value)).toList();
    final done = todos.where((t) => t.value.isCompleted && _matchesFilters(t.value)).toList();

    final tagById = {for (final t in tags) t.value.id: t.value};
    final categoryById = {for (final c in categories) c.value.id: c.value};
    final blocksByTodo = <String, List<TodoBlock>>{};
    for (final b in blocks) {
      blocksByTodo.putIfAbsent(b.value.todoId, () => []).add(b.value);
    }

    // Group by category so the list reads as collapsible sections instead of
    // one flat run. Uncategorised todos get their own trailing group.
    final groups = <({String? id, List<Live<Todo>> items})>[
      for (final c in categories)
        if (open.any((t) => t.value.categoryId == c.value.id))
          (id: c.value.id, items: open.where((t) => t.value.categoryId == c.value.id).toList()),
      if (open.any((t) => t.value.categoryId == null ||
          !categoryById.containsKey(t.value.categoryId)))
        (
          id: null,
          items: open
              .where((t) => t.value.categoryId == null ||
                  !categoryById.containsKey(t.value.categoryId))
              .toList(),
        ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: const Text('待办'),
        actions: [
          IconButton(
            tooltip: '同步',
            onPressed: syncState.syncing
                ? null
                : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
            icon: syncState.syncing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.sync),
          ),
          PopupMenuButton<String>(
            onSelected: (v) => setState(() => _showCompleted = v == 'done'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'open', child: Text('仅进行中')),
              PopupMenuItem(value: 'done', child: Text('包含已完成')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _openEditor(context),
        icon: const Icon(Icons.add),
        label: const Text('新建待办'),
      ),
      body: Column(
        children: [
          if (tags.isNotEmpty) _buildFilters(context, tags),
          Expanded(
            child: todos.isEmpty && snap != null
                ? const Center(child: Text('还没有待办，点右下角新建'))
                : open.isEmpty && done.isEmpty
                    ? const Center(child: Text('没有符合条件的待办'))
                    : ListView(
                        children: [
                          for (final g in groups)
                            _CategoryGroup(
                              title: g.id == null ? '未分类' : categoryById[g.id]!.name,
                              color: g.id == null ? null : categoryById[g.id]!.color,
                              count: g.items.length,
                              expanded: !_collapsed.contains(g.id ?? '__none__'),
                              onToggle: () => setState(() {
                                final key = g.id ?? '__none__';
                                if (!_collapsed.remove(key)) _collapsed.add(key);
                              }),
                              children: [
                                for (final live in g.items)
                                  _TodoTile(
                                    todo: live.value,
                                    pending: live.pending,
                                    tagById: tagById,
                                    categoryById: categoryById,
                                    blocks: blocksByTodo[live.value.id] ?? const [],
                                    onChanged: (status) => _setStatus(live.value, status),
                                    onDelete: () => _delete(live.value),
                                    onEdit: () => _openEditor(context, existing: live.value),
                                    onManageBlocks: () => _openBlocks(context, live.value),
                                  ),
                              ],
                            ),
                          if (_showCompleted && done.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text('已完成', style: TextStyle(color: Colors.grey, fontSize: 12)),
                            ),
                            for (final live in done)
                              _TodoTile(
                                todo: live.value,
                                pending: live.pending,
                                tagById: tagById,
                                categoryById: categoryById,
                                blocks: blocksByTodo[live.value.id] ?? const [],
                                onChanged: (status) => _setStatus(live.value, status),
                                onDelete: () => _delete(live.value),
                                onEdit: () => _openEditor(context, existing: live.value),
                                onManageBlocks: () => _openBlocks(context, live.value),
                              ),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context, List<Live<Tag>> tags) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('按标签筛选', style: TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: [
              for (final t in tags)
                FilterChip(
                  label: Text(t.value.name),
                  selected: _filterTagIds.contains(t.value.id),
                  onSelected: (v) => setState(() {
                    if (v) {
                      _filterTagIds.add(t.value.id);
                    } else {
                      _filterTagIds.remove(t.value.id);
                    }
                  }),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openBlocks(BuildContext context, Todo todo) async {
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoBlocksSheet(todo: todo, userTime: userTime),
    );
  }

  Future<void> _setStatus(Todo todo, TodoStatus status) async {
    final services = ref.read(servicesProvider);
    await services.repo.localUpdate(
      entityType: EntityTypes.todo,
      entityId: todo.id,
      changes: {'status': status.wire},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  Future<void> _delete(Todo todo) async {
    final services = ref.read(servicesProvider);
    await services.repo.localDelete(entityType: EntityTypes.todo, entityId: todo.id);
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  Future<void> _openEditor(BuildContext context, {Todo? existing}) async {
    final snap = ref.read(snapshotProvider).value;
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoEditorSheet(
        existing: existing,
        tags: tags.map((e) => e.value).toList(),
        categories: categories.map((e) => e.value).toList(),
      ),
    );
  }
}

/// A collapsible category section of the todo list. Tapping the header
/// expands/collapses it; the count stays visible when collapsed.
class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.title,
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.children,
    this.color,
  });

  final String title;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final List<Widget> children;
  final String? color;

  @override
  Widget build(BuildContext context) {
    final accent = AppTheme.parseHex(color) ?? Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
            child: Row(
              children: [
                Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 20),
                const SizedBox(width: 4),
                Container(width: 10, height: 10, decoration: BoxDecoration(color: accent, shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent)),
                ),
                Text('$count', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ),
        ),
        if (expanded) ...children,
      ],
    );
  }
}

class _TodoTile extends StatelessWidget {
  const _TodoTile({
    required this.todo,
    required this.pending,
    required this.tagById,
    required this.categoryById,
    required this.blocks,
    required this.onChanged,
    required this.onDelete,
    required this.onEdit,
    this.onManageBlocks,
  });

  final Todo todo;
  final bool pending;
  final Map<String, Tag> tagById;
  final Map<String, Category> categoryById;
  final List<TodoBlock> blocks;
  final ValueChanged<TodoStatus> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback? onManageBlocks;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final category = todo.categoryId == null ? null : categoryById[todo.categoryId];
    final done = todo.isCompleted;
    return ListTile(
      onTap: onEdit,
      leading: Checkbox(
        value: done,
        onChanged: (_) => onChanged(done ? TodoStatus.todo : TodoStatus.completed),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              todo.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: done ? const TextStyle(decoration: TextDecoration.lineThrough, color: Colors.grey) : null,
            ),
          ),
          if (pending) ...[
            const SizedBox(width: 6),
            const Icon(Icons.cloud_upload_outlined, size: 14, color: Colors.orange),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (todo.description != null && todo.description!.isNotEmpty)
            Text(todo.description!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
          Wrap(
            spacing: 4,
            runSpacing: 2,
            children: [
              if (category != null)
                _Pill(text: category.name, color: AppTheme.parseHex(category.color) ?? colors.secondary),
              for (final id in todo.tagIds)
                if (tagById[id] != null) _Pill(text: tagById[id]!.name, color: AppTheme.parseHex(tagById[id]!.color) ?? colors.tertiary),
              if (todo.type == TodoType.project) const _Pill(text: '项目'),
              if (todo.priority == TodoPriority.urgent) const _Pill(text: '紧急', color: AppTheme.deadlineColor),
              if (todo.estimatedMinutes != null) _Pill(text: '约${todo.estimatedMinutes}分钟'),
              if (blocks.isNotEmpty)
                _Pill(text: '${blocks.where((b) => b.status == BlockStatus.completed).length}/${blocks.length} 块'),
            ],
          ),
          if (todo.deadlineAt != null)
            Text('截止 ${_formatDeadline(todo.deadlineAt!)}',
                style: TextStyle(fontSize: 12, color: _overdue(todo.deadlineAt!) ? AppTheme.deadlineColor : null)),
        ],
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (v) {
          if (v == 'delete') onDelete();
          if (v == 'blocks') onManageBlocks?.call();
        },
        itemBuilder: (_) => [
          if (onManageBlocks != null)
            const PopupMenuItem(value: 'blocks', child: Text('时间块')),
          const PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Colors.red))),
        ],
      ),
    );
  }

  String _formatDeadline(DateTime utc) {
    // Deadlines display in the fixed user timezone; caller guarantees tz.
    final local = utc.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  bool _overdue(DateTime utc) {
    final now = DateTime.now().toUtc();
    return utc.isBefore(now);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: (color ?? Colors.grey).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(text, style: TextStyle(fontSize: 10, color: color ?? Colors.grey)),
    );
  }
}

/// Create / edit sheet. Times are interpreted in the user's fixed timezone.
class TodoEditorSheet extends ConsumerStatefulWidget {
  const TodoEditorSheet({
    super.key,
    required this.tags,
    required this.categories,
    this.existing,
  });

  final Todo? existing;
  final List<Tag> tags;
  final List<Category> categories;

  @override
  ConsumerState<TodoEditorSheet> createState() => _TodoEditorSheetState();
}

class _TodoEditorSheetState extends ConsumerState<TodoEditorSheet> {
  late final TextEditingController _title;
  late final TextEditingController _desc;
  late final TextEditingController _est;
  late TodoType _type;
  late TodoPriority _priority;
  DateTime? _deadline;
  String? _categoryId;
  late final Set<String> _tagIds;
  late final List<Tag> _tags;
  late final List<Category> _categories;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.existing?.title ?? '');
    _desc = TextEditingController(text: widget.existing?.description ?? '');
    _est = TextEditingController(text: widget.existing?.estimatedMinutes?.toString() ?? '');
    _type = widget.existing?.type ?? TodoType.oneOff;
    _priority = widget.existing?.priority ?? TodoPriority.normal;
    _deadline = widget.existing?.deadlineAt;
    _categoryId = widget.existing?.categoryId;
    _tagIds = {...(widget.existing?.tagIds ?? const [])};
    _tags = [...widget.tags];
    _categories = [...widget.categories];
  }

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    _est.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isEdit ? '编辑待办' : '新建待办', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _title,
              autofocus: !isEdit,
              decoration: const InputDecoration(labelText: '标题'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _desc,
              maxLines: 2,
              decoration: const InputDecoration(labelText: '描述（可选）'),
            ),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: SegmentedButton<TodoType>(
                  segments: const [
                    ButtonSegment(value: TodoType.oneOff, label: Text('一次性')),
                    ButtonSegment(value: TodoType.project, label: Text('项目')),
                  ],
                  selected: {_type},
                  onSelectionChanged: (s) => setState(() => _type = s.first),
                ),
              ),
            ]),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // A one-off is a single errand / meeting / shopping list: at
                // most one block and no deadline. The server imposes neither —
                // this is our own model.
                _type == TodoType.oneOff
                    ? '临时活动、会议或购物清单：最多 1 个时间块，不设截止时间'
                    : '多阶段任务：可拆成多个时间块，可设截止时间',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
            const SizedBox(height: 10),
            DropdownButtonFormField<TodoPriority>(
              initialValue: _priority,
              decoration: const InputDecoration(labelText: '优先级'),
              items: const [
                DropdownMenuItem(value: TodoPriority.low, child: Text('低')),
                DropdownMenuItem(value: TodoPriority.normal, child: Text('普通')),
                DropdownMenuItem(value: TodoPriority.high, child: Text('高')),
                DropdownMenuItem(value: TodoPriority.urgent, child: Text('紧急')),
              ],
              onChanged: (v) => setState(() => _priority = v ?? TodoPriority.normal),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: _categoryId,
                    decoration: const InputDecoration(labelText: '分类'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('无')),
                      for (final c in _categories)
                        DropdownMenuItem(value: c.id, child: Text(c.name)),
                    ],
                    onChanged: (v) => setState(() => _categoryId = v),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '新建分类',
                  onPressed: _createCategory,
                ),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _est,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '预计时长（分钟，可选）', suffixText: '分'),
            ),
            if (_type == TodoType.project) ...[
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.schedule),
                      label: Text(_deadline == null
                          ? '设置截止时间'
                          : '截止 ${_formatLocal(_deadline!)}'),
                      onPressed: _pickDeadline,
                    ),
                  ),
                  if (_deadline != null)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() => _deadline = null),
                    ),
                ],
              ),
            ] else if (_deadline != null)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  '一次性待办不使用截止时间；保存后会清除原有的截止时间。',
                  style: TextStyle(fontSize: 11, color: Colors.orange),
                ),
              ),
            const SizedBox(height: 10),
            if (_tags.isNotEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text('标签', style: TextStyle(fontSize: 12, color: Colors.grey)),
              ),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final t in _tags)
                  FilterChip(
                    label: Text(t.name),
                    selected: _tagIds.contains(t.id),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _tagIds.add(t.id);
                      } else {
                        _tagIds.remove(t.id);
                      }
                    }),
                  ),
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: const Text('新建标签'),
                  onPressed: _createTag,
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  String _formatLocal(DateTime utc) {
    final local = utc.toLocal();
    return '${local.month}月${local.day}日 ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDeadline() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _deadline?.toLocal() ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: _deadline?.toLocal().hour ?? 18, minute: 0),
    );
    if (time == null || !mounted) return;
    final userTime = ref.read(userTimeProvider);
    if (userTime == null) return;
    // Interpret the picked wall-clock in the fixed user timezone.
    final local = userTime.fromLocalParts(date.year, date.month, date.day, time.hour, time.minute);
    setState(() => _deadline = local.toUtc());
  }

  Future<void> _createCategory() async {
    final r = await _showCreateDialog('新建分类');
    if (r == null || !mounted) return;
    final id = await ref.read(servicesProvider).repo.localCreate(
      entityType: EntityTypes.category,
      snapshot: {'name': r.name, 'color': r.color},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (!mounted) return;
    setState(() {
      _categories.add(Category(id: id, name: r.name, color: r.color, revision: 0));
      _categoryId = id;
    });
  }

  Future<void> _createTag() async {
    final r = await _showCreateDialog('新建标签');
    if (r == null || !mounted) return;
    final id = await ref.read(servicesProvider).repo.localCreate(
      entityType: EntityTypes.tag,
      snapshot: {'name': r.name, 'color': r.color},
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (!mounted) return;
    setState(() {
      _tags.add(Tag(id: id, name: r.name, color: r.color, revision: 0));
      _tagIds.add(id);
    });
  }

  /// Inline picker for a new category/tag: name + palette. Returns the entered
  /// name and chosen color, or null when cancelled.
  Future<({String name, String? color})?> _showCreateDialog(String title) async {
    final nameCtrl = TextEditingController();
    String? color;
    final result = await showDialog<({String name, String? color})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameCtrl,
                autofocus: true,
                decoration: const InputDecoration(labelText: '名称'),
              ),
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
                          border: Border.all(
                            color: color == hex ? Colors.black : Colors.transparent,
                            width: 2,
                          ),
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
                final name = nameCtrl.text.trim();
                if (name.isEmpty) return;
                Navigator.pop(ctx, (name: name, color: color));
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    nameCtrl.dispose();
    return result;
  }

  Future<void> _save() async {
    final services = ref.read(servicesProvider);
    final title = _title.text.trim();
    if (title.isEmpty) return;
    final est = int.tryParse(_est.text.trim());
    final changes = <String, dynamic>{
      'title': title,
      'type': _type.wire,
      'description': _desc.text.trim().isEmpty ? null : _desc.text.trim(),
      'categoryId': _categoryId,
      'tagIds': _tagIds.toList(),
      'priority': _priority.wire,
      // One-off tasks carry no deadline; switching type clears it.
      'deadlineAt': _type == TodoType.project ? _deadline : null,
    };
    if (est != null) {
      changes['estimatedMinutes'] = est;
    }
    final repo = services.repo;
    if (widget.existing == null) {
      await repo.localCreate(
        entityType: EntityTypes.todo,
        snapshot: {...changes, 'status': TodoStatus.todo.wire},
      );
    } else {
      await repo.localUpdate(
        entityType: EntityTypes.todo,
        entityId: widget.existing!.id,
        changes: changes,
      );
    }
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}
