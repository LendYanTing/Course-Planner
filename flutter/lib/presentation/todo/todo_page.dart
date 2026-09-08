import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../data/local/view_models.dart';
import '../../domain/entities.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';

/// Todo list (docs/domain-model.md §7-9): one_off / project, priority, status,
/// deadline, estimated duration, tags/categories, linked blocks.
class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  bool _showCompleted = false;

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final syncState = ref.watch(syncCoordinatorProvider);
    final todos = snap == null ? <Live<Todo>>[] : liveTodos(snap);
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    final blocks = snap == null ? <Live<TodoBlock>>[] : liveBlocks(snap);

    final open = todos.where((t) => !t.value.isCompleted).toList();
    final done = todos.where((t) => t.value.isCompleted).toList();

    final tagById = {for (final t in tags) t.value.id: t.value};
    final categoryById = {for (final c in categories) c.value.id: c.value};
    final blocksByTodo = <String, List<TodoBlock>>{};
    for (final b in blocks) {
      blocksByTodo.putIfAbsent(b.value.todoId, () => []).add(b.value);
    }

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
      body: todos.isEmpty && snap != null
          ? const Center(child: Text('还没有待办，点右下角新建'))
          : ListView(
              children: [
                for (final live in open)
                  _TodoTile(
                    todo: live.value,
                    pending: live.pending,
                    tagById: tagById,
                    categoryById: categoryById,
                    blocks: blocksByTodo[live.value.id] ?? const [],
                    onChanged: (status) => _setStatus(live.value, status),
                    onDelete: () => _delete(live.value),
                    onEdit: () => _openEditor(context, existing: live.value),
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
                    ),
                ],
              ],
            ),
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
  });

  final Todo todo;
  final bool pending;
  final Map<String, Tag> tagById;
  final Map<String, Category> categoryById;
  final List<TodoBlock> blocks;
  final ValueChanged<TodoStatus> onChanged;
  final VoidCallback onDelete;
  final VoidCallback onEdit;

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
        },
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'delete', child: Text('删除', style: TextStyle(color: Colors.red))),
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
            DropdownButtonFormField<String?>(
              initialValue: _categoryId,
              decoration: const InputDecoration(labelText: '分类'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('无')),
                for (final c in widget.categories)
                  DropdownMenuItem(value: c.id, child: Text(c.name)),
              ],
              onChanged: (v) => setState(() => _categoryId = v),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _est,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '预计时长（分钟，可选）', suffixText: '分'),
            ),
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
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              children: [
                for (final t in widget.tags)
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
      'deadlineAt': _deadline,
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
