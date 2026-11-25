import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../data/local/view_models.dart';
import '../../domain/todo.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../state/todo_controller.dart';
import '../adaptive/adaptive.dart';
import '../agent/agent_chat_sheet.dart';
import '../settings/courses_page.dart' show kPalette;
import '../widgets/voice_input_button.dart';
import 'todo_blocks_sheet.dart';
import '../../state/todo_sorting.dart';

/// Todo list (docs/domain-model.md §7-9): one_off / project, priority, status,
/// deadline, estimated duration, tags/categories, linked blocks.
///
/// The page renders [todoBoardProvider] and forwards taps to
/// [todoControllerProvider]; filtering, grouping, sorting and every repository
/// write live in `lib/state/todo_controller.dart`. Only transient view state
/// (collapsed sections, text controllers) stays here.
class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  /// Collapsed category sections (`__none__` for the uncategorised group).
  final Set<String> _collapsed = {};


  @override
  Widget build(BuildContext context) {
    final board = ref.watch(todoBoardProvider);
    final query = ref.watch(todoControllerProvider);
    final controller = ref.read(todoControllerProvider.notifier);
    final syncState = ref.watch(syncCoordinatorProvider);
    final userTime = ref.watch(userTimeProvider);
    // A deadline reads as its user-tz wall clock (§5). Without a known user
    // timezone there is no honest clock to print (§3 forbids the device zone),
    // so the deadline text is simply omitted rather than faked.
    String? deadlineTextFor(Todo t) => userTime == null || t.deadlineAt == null
        ? null
        : userTime.formatDateYmdHm(t.deadlineAt!);

    Widget tile(Live<Todo> live) => _TodoTile(
          todo: live.value,
          pending: live.pending,
          tagById: board.tagById,
          categoryById: board.categoryById,
          blocks: board.blocksByTodo[live.value.id] ?? const [],
          deadlineText: deadlineTextFor(live.value),
          onChanged: (status) => controller.setStatus(live.value, status),
          onDelete: () => controller.delete(live.value),
          onEdit: () => _openEditor(context, existing: live.value),
          onManageBlocks: () => _openBlocks(context, live.value),
        );

    return Scaffold(
      appBar: AppTopBar(
        title: '待办',
        actions: [
          IconButton(
            tooltip: 'AI 助手',
            icon: const Icon(Icons.auto_awesome),
            onPressed: () => AgentChatSheet.show(context),
          ),
          // Hidden for a local session (no server to sync with).
          if (ref.watch(cloudSyncEnabledProvider))
            IconButton(
              tooltip: '同步',
              onPressed: syncState.syncing
                  ? null
                  : () => ref.read(syncCoordinatorProvider.notifier).syncNow(),
              icon: syncState.syncing
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
            ),
          PopupMenuButton<Object>(
            tooltip: '排序',
            icon: const Icon(Icons.sort),
            onSelected: (v) {
              if (v is TodoSortKey) controller.setSortKey(v);
              if (v is TodoSortScope) controller.setSortScope(v);
            },
            itemBuilder: (_) => [
              for (final k in TodoSortKey.values)
                CheckedPopupMenuItem<Object>(
                  value: k,
                  checked: query.sort.key == k,
                  child: Text(_sortKeyLabel(k)),
                ),
              const PopupMenuDivider(),
              for (final s in TodoSortScope.values)
                CheckedPopupMenuItem<Object>(
                  value: s,
                  checked: query.sort.scope == s,
                  child: Text(_sortScopeLabel(s)),
                ),
            ],
          ),
          PopupMenuButton<String>(
            onSelected: (v) => controller.setShowCompleted(v == 'done'),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'open', child: Text('仅进行中')),
              PopupMenuItem(value: 'done', child: Text('包含已完成')),
            ],
          ),
        ],
      ),
      // The floating nav bar lives in the shell's bottom slot, so this page's
      // own Scaffold still places the FAB at the very bottom — i.e. under the
      // bar. Lifting it by the same inset the body receives keeps it above the
      // capsule (Scaffold only accounts for a *Material* bottomNavigationBar).
      floatingActionButton: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
        child: FloatingActionButton.extended(
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('新建待办'),
        ),
      ),
      body: Column(
        children: [
          if (board.tags.isNotEmpty) _buildFilters(context, board.tags, query, controller),
          Expanded(
            child: board.todoCount == 0 && board.loaded
                ? const Center(child: Text('还没有待办，点右下角新建'))
                : board.groups.isEmpty && board.done.isEmpty
                    ? const Center(child: Text('没有符合条件的待办'))
                    : ListView(
                        // Reserve the translucent floating nav bar's height
                        // (extendBody) plus room for the FAB over the last row.
                        padding: EdgeInsets.only(
                          bottom: MediaQuery.paddingOf(context).bottom + 72,
                        ),
                        children: [
                          for (final g in board.groups)
                            _CategoryGroup(
                              title: g.id == null ? '未分类' : board.categoryById[g.id]!.name,
                              color: g.id == null ? null : board.categoryById[g.id]!.color,
                              count: g.items.length,
                              expanded: !_collapsed.contains(g.id ?? '__none__'),
                              onToggle: () => setState(() {
                                final key = g.id ?? '__none__';
                                if (!_collapsed.remove(key)) _collapsed.add(key);
                              }),
                              children: [for (final live in g.items) tile(live)],
                            ),
                          if (query.showCompleted && board.done.isNotEmpty) ...[
                            const Padding(
                              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
                              child: Text('已完成', style: TextStyle(color: Colors.grey, fontSize: 12)),
                            ),
                            for (final live in board.done) tile(live),
                          ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters(
    BuildContext context,
    List<Live<Tag>> tags,
    TodoQuery query,
    TodoController controller,
  ) {
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
                  selected: query.tagIds.contains(t.value.id),
                  onSelected: (_) => controller.toggleTagFilter(t.value.id),
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
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoBlocksSheet(todo: todo, userTime: userTime),
    );
  }

  Future<void> _openEditor(BuildContext context, {Todo? existing}) async {
    final snap = ref.read(snapshotProvider).value;
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    // The editor does not load existing blocks (it stays a quick create sheet);
    // it only mentions how many the todo already has.
    final existingBlockCount = snap == null || existing == null
        ? 0
        : liveBlocks(snap, todoId: existing.id).length;
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoEditorSheet(
        existing: existing,
        tags: tags.map((e) => e.value).toList(),
        categories: categories.map((e) => e.value).toList(),
        existingBlockCount: existingBlockCount,
      ),
    );
  }
}

/// Menu labels for the sorter (kept beside the page, not in the sort logic).
String _sortKeyLabel(TodoSortKey key) => switch (key) {
      TodoSortKey.deadlineAsc => '截止时间（近→远）',
      TodoSortKey.deadlineDesc => '截止时间（远→近）',
      TodoSortKey.priorityDesc => '优先级（高→低）',
      TodoSortKey.createdDesc => '创建时间（新→旧）',
    };

String _sortScopeLabel(TodoSortScope scope) => switch (scope) {
      TodoSortScope.wholePage => '整页',
      TodoSortScope.withinGroup => '仅组内',
    };

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
    required this.deadlineText,
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

  /// The deadline's already-formatted user-tz wall clock, or null when the
  /// user timezone is unknown (nothing honest to print then). The tile holds
  /// no timezone logic of its own.
  final String? deadlineText;
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
          if (deadlineText != null)
            Text('截止 $deadlineText',
                style: TextStyle(fontSize: 12, color: _overdue(todo.deadlineAt!) ? AppTheme.deadlineColor : null)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // One tap to schedule an existing todo: the same sheet the menu opens,
          // without the two-level detour.
          if (onManageBlocks != null)
            IconButton(
              icon: const Icon(Icons.more_time, size: 20),
              tooltip: '排入日程',
              onPressed: onManageBlocks,
            ),
          PopupMenuButton<String>(
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
        ],
      ),
    );
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
    this.existingBlockCount = 0,
  });

  final Todo? existing;
  final List<Tag> tags;
  final List<Category> categories;

  /// How many blocks the edited todo already has. The sheet never loads them
  /// (it stays a quick create sheet) — it only mentions the count.
  final int existingBlockCount;

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

  /// "排入日程时间表": draft windows written together with the todo on save.
  /// Existing blocks are never loaded here; these are always new ones.
  bool _scheduleEnabled = false;
  final List<_DraftBlock> _blocks = [];
  bool _saving = false;

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
    for (final b in _blocks) {
      b.dispose();
    }
    _title.dispose();
    _desc.dispose();
    _est.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    // Watched here so the build and the button agree; the picker handler
    // (_pickDeadline) stays a ref.read, as it runs outside build.
    final userTime = ref.watch(userTimeProvider);
    // Editing a todo that already carries detail opens the folded section, so
    // nothing silently looks absent.
    final expandMore = isEdit &&
        ((widget.existing!.description?.isNotEmpty ?? false) ||
            widget.existing!.categoryId != null ||
            widget.existing!.tagIds.isNotEmpty ||
            widget.existing!.type == TodoType.project);
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
            // 1. What to do.
            TextField(
              controller: _title,
              autofocus: !isEdit,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                hintText: '要做什么？（例如：完成高数作业第三章）',
                suffixIcon: VoiceInputButton(
                  tooltip: '语音输入待办标题',
                  onText: (text) => setState(() {
                    _title.value = TextEditingValue(
                      text: text,
                      selection: TextSelection.collapsed(offset: text.length),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // 2. Reminder (one-off) / deadline (project) plus quick picks.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    // A one-off is a single moment (take out the trash), so its
                    // time point reads as a reminder rather than a deadline.
                    icon: Icon(_type == TodoType.oneOff
                        ? Icons.notifications_none
                        : Icons.schedule),
                    label: Text(_deadlineLabel(userTime)),
                    onPressed:
                        userTime == null ? null : () => _pickDeadline(userTime),
                  ),
                ),
                if (_deadline != null)
                  IconButton(
                    icon: const Icon(Icons.clear),
                    tooltip: '清除时间',
                    onPressed: () => setState(() => _deadline = null),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                ActionChip(
                  label: const Text('今天 22:00'),
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _atDay(userTime, 0, 22, 0)),
                ),
                ActionChip(
                  label: const Text('明天 18:00'),
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _atDay(userTime, 1, 18, 0)),
                ),
                ActionChip(
                  label: const Text('周日 23:59'),
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _sundayAt(userTime, 23, 59)),
                ),
                ActionChip(
                  avatar: const Icon(Icons.edit_calendar, size: 16),
                  label: const Text('自定义'),
                  onPressed: userTime == null ? null : () => _pickDeadline(userTime),
                ),
              ],
            ),
            if (userTime == null)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '用户时区未就绪，暂时无法设置或显示时间。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            if (_type == TodoType.oneOff)
              const Padding(
                padding: EdgeInsets.only(top: 4),
                child: Text(
                  '提醒时间用于「到点做一下」的一次性事情（比如扔垃圾），不需要再分配时间块。',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 12),
            // 3. Same-sheet scheduling: todo + blocks in one save.
            _buildScheduleSection(isEdit, userTime),
            const SizedBox(height: 12),
            // 4. Priority in one row.
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final p in TodoPriority.values)
                  ChoiceChip(
                    label: Text(_priorityLabel(p)),
                    selected: _priority == p,
                    onSelected: (_) => setState(() => _priority = p),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            // 5. Everything else stays available, one tap away.
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('更多选项：分类、标签、描述、类型', style: TextStyle(fontSize: 14)),
              initiallyExpanded: expandMore,
              children: [_buildMoreOptions()],
            ),
            const SizedBox(height: 8),
            // 6. Save (todo + drafted blocks).
            FilledButton(
              onPressed: _saving ? null : _save,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// The folded section: type, category, estimate, tags, description — the
  /// fields that used to occupy the first screen.
  Widget _buildMoreOptions() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
            // most one block, plus an optional reminder time.
            _type == TodoType.oneOff
                ? '临时活动、会议或购物清单：最多 1 个时间块，可设提醒时间'
                : '多阶段任务：可拆成多个时间块，可设截止时间',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
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
        Wrap(
          spacing: 6,
          children: [
            for (final minutes in const [30, 60, 120])
              ActionChip(
                label: Text('$minutes分'),
                onPressed: () => setState(() => _est.text = '$minutes'),
              ),
          ],
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
        const SizedBox(height: 10),
        TextField(
          controller: _desc,
          maxLines: 2,
          decoration: const InputDecoration(hintText: '描述（可选）'),
        ),
      ],
    );
  }

  /// The schedule card: one switch, then the draft windows it will write.
  Widget _buildScheduleSection(bool isEdit, UserTime? userTime) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 8),
            title: const Text('排入日程时间表', style: TextStyle(fontSize: 14)),
            subtitle: const Text('保存时一并创建时间块', style: TextStyle(fontSize: 11)),
            value: _scheduleEnabled,
            onChanged: userTime == null
                ? null
                : (v) => setState(() {
                      _scheduleEnabled = v;
                      if (v && _blocks.isEmpty) {
                        _blocks.add(_defaultBlock(userTime));
                      }
                    }),
          ),
          if (isEdit && widget.existingBlockCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: Text(
                '已有 ${widget.existingBlockCount} 个时间块（在待办菜单中管理）',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          if (_scheduleEnabled && userTime != null) ...[
            if (isEdit)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Text(
                  '将新增 ${_blocks.length} 个时间块',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            for (var i = 0; i < _blocks.length; i++) _buildBlockEditor(i, userTime),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                child: TextButton.icon(
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('添加执行时间段'),
                  onPressed: () => _addBlock(userTime),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// One drafted window: date, start/end wall clock, note, quick durations.
  Widget _buildBlockEditor(int index, UserTime userTime) {
    final block = _blocks[index];
    final startLocal = userTime.localFromUtc(block.startUtc);
    final endLocal = userTime.localFromUtc(block.endUtc);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ActionChip(
                      avatar: const Icon(Icons.event, size: 16),
                      label: Text(_blockDateLabel(userTime, startLocal)),
                      onPressed: () => _pickBlockDate(index, userTime),
                    ),
                    ActionChip(
                      label: Text('开始 ${_hhmm(startLocal)}'),
                      onPressed: () =>
                          _pickBlockTime(index, userTime, isStart: true),
                    ),
                    ActionChip(
                      label: Text('结束 ${_hhmm(endLocal)}'),
                      onPressed: () =>
                          _pickBlockTime(index, userTime, isStart: false),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: '删除这一段',
                onPressed: () => _removeBlock(index),
              ),
            ],
          ),
          TextField(
            controller: block.note,
            decoration: const InputDecoration(
              isDense: true,
              hintText: '这一时段准备完成什么？',
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              for (final minutes in const [45, 60, 120])
                ActionChip(
                  label: Text(minutes == 60 ? '1小时' : (minutes == 120 ? '2小时' : '$minutes分')),
                  onPressed: () => setState(
                    () => block.endUtc = _endOnSameDay(
                        userTime, block.startUtc, Duration(minutes: minutes)),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _priorityLabel(TodoPriority p) => switch (p) {
        TodoPriority.low => '低',
        TodoPriority.normal => '普通',
        TodoPriority.high => '高',
        TodoPriority.urgent => '紧急',
      };

  /// The local date [days] from now at [hour]:[minute], as a UTC instant.
  DateTime _atDay(UserTime userTime, int days, int hour, int minute) {
    final now = userTime.localFromUtc(DateTime.now().toUtc());
    final day = userTime.addLocalDays(now, days);
    return userTime.utcFromLocalParts(day.year, day.month, day.day, hour, minute);
  }

  /// The coming Sunday at [hour]:[minute] (today when today is Sunday).
  DateTime _sundayAt(UserTime userTime, int hour, int minute) {
    final now = userTime.localFromUtc(DateTime.now().toUtc());
    final daysAhead = (DateTime.sunday - now.weekday + 7) % 7;
    return _atDay(userTime, daysAhead, hour, minute);
  }

  /// Default draft window: the next full hour for one hour; at/after 22:00 it
  /// moves to tomorrow 09:00–10:00 (otherwise it would cross midnight).
  _DraftBlock _defaultBlock(UserTime userTime) {
    final now = userTime.localFromUtc(DateTime.now().toUtc());
    if (now.hour >= 22) {
      final tomorrow = userTime.addLocalDays(now, 1);
      final start = userTime.utcFromLocalParts(
          tomorrow.year, tomorrow.month, tomorrow.day, 9, 0);
      return _DraftBlock(
          startUtc: start, endUtc: start.add(const Duration(hours: 1)));
    }
    final start = userTime.utcFromLocalParts(
        now.year, now.month, now.day, now.hour + 1, 0);
    return _DraftBlock(
        startUtc: start, endUtc: start.add(const Duration(hours: 1)));
  }

  void _addBlock(UserTime userTime) {
    setState(() {
      _blocks.add(_defaultBlock(userTime));
      // More than one window means a multi-stage task: upgrade silently, the
      // user should not have to reason about the type up front.
      if (_blocks.length > 1) _type = TodoType.project;
    });
  }

  void _removeBlock(int index) {
    setState(() => _blocks.removeAt(index).dispose());
  }

  String _blockDateLabel(UserTime userTime, DateTime local) {
    final now = userTime.localFromUtc(DateTime.now().toUtc());
    final tomorrow = userTime.addLocalDays(now, 1);
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '今天';
    }
    if (local.year == tomorrow.year &&
        local.month == tomorrow.month &&
        local.day == tomorrow.day) {
      return '明天';
    }
    return '${local.month}月${local.day}日';
  }

  Future<void> _pickBlockDate(int index, UserTime userTime) async {
    final block = _blocks[index];
    final startLocal = userTime.localFromUtc(block.startUtc);
    final date = await showDatePicker(
      context: context,
      initialDate: startLocal,
      firstDate: DateTime(startLocal.year - 1),
      lastDate: DateTime(startLocal.year + 5),
    );
    if (date == null || !mounted) return;
    final duration = block.endUtc.difference(block.startUtc);
    setState(() {
      block.startUtc = userTime.utcFromLocalParts(
          date.year, date.month, date.day, startLocal.hour, startLocal.minute);
      block.endUtc = _endOnSameDay(userTime, block.startUtc,
          duration.isNegative || duration == Duration.zero
              ? const Duration(hours: 1)
              : duration);
    });
  }

  /// [start] + [duration], clamped to the end of [start]'s local day so a
  /// drafted block never crosses midnight (the server rejects those).
  DateTime _endOnSameDay(UserTime userTime, DateTime start, Duration duration) {
    final end = start.add(duration);
    if (userTime.sameLocalDay(start, end)) return end;
    final local = userTime.localFromUtc(start);
    return userTime.utcFromLocalParts(
        local.year, local.month, local.day, 23, 59);
  }

  Future<void> _pickBlockTime(
    int index,
    UserTime userTime, {
    required bool isStart,
  }) async {
    final block = _blocks[index];
    final anchor = userTime.localFromUtc(isStart ? block.startUtc : block.endUtc);
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: anchor.hour, minute: anchor.minute),
    );
    if (time == null || !mounted) return;
    final startLocal = userTime.localFromUtc(block.startUtc);
    setState(() {
      if (isStart) {
        final duration = block.endUtc.difference(block.startUtc);
        block.startUtc = userTime.utcFromLocalParts(startLocal.year,
            startLocal.month, startLocal.day, time.hour, time.minute);
        block.endUtc = _endOnSameDay(userTime, block.startUtc,
            duration.isNegative || duration == Duration.zero
                ? const Duration(hours: 1)
                : duration);
      } else {
        block.endUtc = userTime.utcFromLocalParts(startLocal.year,
            startLocal.month, startLocal.day, time.hour, time.minute);
        // A block must run forward inside one local day; a same-day end at or
        // before the start is read as a mis-tap and pushed an hour on.
        if (!block.endUtc.isAfter(block.startUtc)) {
          block.endUtc = _endOnSameDay(
              userTime, block.startUtc, const Duration(hours: 1));
        }
      }
    });
  }

  /// The reminder/deadline button's label. Without a user timezone there is no
  /// honest wall clock, so it falls back to the action wording (the button is
  /// also disabled then).
  String _deadlineLabel(UserTime? userTime) {
    final oneOff = _type == TodoType.oneOff;
    final action = oneOff ? '设置提醒时间' : '设置截止时间';
    if (_deadline == null || userTime == null) return action;
    return '${oneOff ? '提醒' : '截止'} ${userTime.formatDateMonthDayHm(_deadline!)}';
  }

  Future<void> _pickDeadline(UserTime userTime) async {
    final now = DateTime.now();
    final base = _deadline == null ? null : userTime.localFromUtc(_deadline!);
    final date = await showDatePicker(
      context: context,
      initialDate: base ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: base?.hour ?? 18, minute: 0),
    );
    if (time == null || !mounted) return;
    // Interpret the picked wall-clock in the fixed user timezone, and keep a
    // plain UTC DateTime in UI state: a TZDateTime would render UTC wall-clock
    // (see UserTime.utcFromLocalParts).
    setState(() => _deadline = userTime.utcFromLocalParts(
        date.year, date.month, date.day, time.hour, time.minute));
  }

  Future<void> _createCategory() async {
    final r = await _showCreateDialog('新建分类');
    if (r == null || !mounted) return;
    final id = await ref
        .read(todoControllerProvider.notifier)
        .createCategory(name: r.name, color: r.color);
    if (!mounted) return;
    setState(() {
      _categories.add(Category(id: id, name: r.name, color: r.color, revision: 0));
      _categoryId = id;
    });
  }

  Future<void> _createTag() async {
    final r = await _showCreateDialog('新建标签');
    if (r == null || !mounted) return;
    final id = await ref
        .read(todoControllerProvider.notifier)
        .createTag(name: r.name, color: r.color);
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
    final result = await showAppDialog<({String name, String? color})>(
      context: context,
      title: title,
      content: StatefulBuilder(
        builder: (ctx, setDialogState) => Column(
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
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context, rootNavigator: true).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () {
            final name = nameCtrl.text.trim();
            if (name.isEmpty) return;
            Navigator.of(context, rootNavigator: true).pop((name: name, color: color));
          },
          child: const Text('保存'),
        ),
      ],
    );
    nameCtrl.dispose();
    return result;
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (title.isEmpty || _saving) return;
    setState(() => _saving = true);
    final newBlocks = _scheduleEnabled
        ? <NewTodoBlock>[
            for (final b in _blocks)
              (
                startUtc: b.startUtc,
                endUtc: b.endUtc,
                blockNote:
                    b.note.text.trim().isEmpty ? null : b.note.text.trim(),
              ),
          ]
        : const <NewTodoBlock>[];
    try {
      // The controller writes the todo and every block in one transaction, and
      // upgrades the type to project when more than one block is drafted.
      await ref.read(todoControllerProvider.notifier).saveTodo(
            existingId: widget.existing?.id,
            title: title,
            type: _type,
            description: _desc.text.trim().isEmpty ? null : _desc.text.trim(),
            categoryId: _categoryId,
            tagIds: _tagIds,
            priority: _priority,
            deadlineAt: _deadline,
            estimatedMinutes: int.tryParse(_est.text.trim()),
            newBlocks: newBlocks,
          );
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// `HH:mm` wall clock of an already user-tz local instant.
String _hhmm(DateTime local) =>
    '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';

/// One execution window being drafted in the editor (UTC instants + note).
class _DraftBlock {
  _DraftBlock({required this.startUtc, required this.endUtc, String note = ''})
      : note = TextEditingController(text: note);

  DateTime startUtc;
  DateTime endUtc;
  final TextEditingController note;

  void dispose() => note.dispose();
}
