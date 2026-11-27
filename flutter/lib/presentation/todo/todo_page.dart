import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../data/local/view_models.dart';
import '../../domain/entities.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../state/todo_controller.dart';
import '../adaptive/adaptive.dart';
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
          onDelete: () => _confirmDelete(context, live.value),
          onEdit: () => _openEditor(context, existing: live.value),
        );

    return Scaffold(
      appBar: AppTopBar(
        title: '待办',
        actions: [
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
            icon: const Icon(Icons.tune),
            tooltip: '排序与筛选',
            iconSize: 22,
            padding: EdgeInsets.zero,
            onSelected: (v) {
              if (v is TodoSortKey) controller.setSortKey(v);
              if (v is TodoSortScope) controller.setSortScope(v);
              if (v == 'completed') context.push('/todo/completed');
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
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'completed',
                child: Text('已完成任务'),
              ),
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
                : board.groups.isEmpty
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

  /// Deletes only after an explicit confirmation: a row tap opens the editor,
  /// so the trailing icon must never remove data by itself.
  Future<void> _confirmDelete(BuildContext context, Todo todo) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: '删除任务？',
      content: const Text('删除后无法恢复。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
          child: const Text('删除'),
        ),
      ],
    );
    if (confirmed != true || !mounted) return;
    await ref.read(todoControllerProvider.notifier).delete(todo);
  }

  Future<void> _openEditor(BuildContext context, {Todo? existing}) async {
    final snap = ref.read(snapshotProvider).value;
    final tags = snap == null ? <Live<Tag>>[] : liveTags(snap);
    final categories = snap == null ? <Live<Category>>[] : liveCategories(snap);
    // The editor shows an existing one-off block inline and hands a project's
    // blocks over to TodoBlocksSheet, so it needs the current windows.
    final existingBlocks = snap == null || existing == null
        ? const <TodoBlock>[]
        : liveBlocks(snap, todoId: existing.id).map((e) => e.value).toList();
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoEditorSheet(
        existing: existing,
        tags: tags.map((e) => e.value).toList(),
        categories: categories.map((e) => e.value).toList(),
        existingBlocks: existingBlocks,
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

/// A category section of the todo list: a dot + count badge header over the
/// category's rows, which sit together in one segmented card.
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
        _GroupHeader(
          title: title,
          count: count,
          accent: accent,
          expanded: expanded,
          onToggle: onToggle,
          countKey: ValueKey('todo-group-count-$title'),
        ),
        if (expanded)
          AppSegmentedColumn(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            children: children,
          ),
      ],
    );
  }
}

/// Collapsible group header: accent dot, title, count badge and a chevron.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({
    required this.title,
    required this.count,
    required this.accent,
    this.expanded = false,
    this.onToggle,
    this.countKey,
  });

  final String title;
  final int count;
  final Color accent;
  final bool expanded;
  final VoidCallback? onToggle;
  final Key? countKey;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent),
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '$count',
                key: countKey,
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: accent),
              ),
            ),
            if (onToggle != null)
              Icon(
                expanded ? Icons.expand_more : Icons.chevron_right,
                size: 18,
                color: accent,
              ),
          ],
        ),
      ),
    );
  }
}

class _TodoTile extends ConsumerWidget {
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

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final category = todo.categoryId == null ? null : categoryById[todo.categoryId];
    final done = todo.isCompleted;
    // A queue chip only means something when a cloud server can actually take
    // the push; local mode and switched-off sync never upload.
    final showPending = pending && ref.watch(cloudSyncEnabledProvider);
    final completedBlocks = blocks.where((b) => b.status == BlockStatus.completed).length;
    final pills = <Widget>[
      if (deadlineText != null)
        _Pill(
          text: '截止 $deadlineText',
          color: _overdue(todo.deadlineAt!) ? AppTheme.deadlineColor : null,
        ),
      if (category != null)
        _Pill(
          text: category.name,
          color: AppTheme.parseHex(category.color) ?? scheme.secondary,
        ),
      for (final id in todo.tagIds)
        if (tagById[id] != null)
          _Pill(
            text: tagById[id]!.name,
            color: AppTheme.parseHex(tagById[id]!.color) ?? scheme.tertiary,
          ),
      if (todo.type == TodoType.project) const _Pill(text: '项目'),
      // Every priority is visible, with its own wording and tone.
      switch (todo.priority) {
        TodoPriority.urgent => _Pill(
            text: '紧急',
            color: AppTheme.deadlineColor,
            background: scheme.errorContainer,
          ),
        TodoPriority.high => _Pill(
            text: '高',
            color: scheme.onTertiaryContainer,
            background: scheme.tertiaryContainer,
          ),
        TodoPriority.normal => _Pill(
            text: '普通',
            color: scheme.onSecondaryContainer,
            background: scheme.secondaryContainer,
          ),
        TodoPriority.low => _Pill(text: '低', color: scheme.outline),
      },
      if (todo.estimatedMinutes != null) _Pill(text: '约${todo.estimatedMinutes}分钟'),
      // A one-off is a single window, so a 0/1 counter would only add noise;
      // the project progress pill appears once there is something to track.
      if (todo.type == TodoType.project && blocks.length > 1)
        _Pill(text: '$completedBlocks 块已完成/${blocks.length}'),
    ];
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 3),
              child: Checkbox(
                value: done,
                visualDensity: VisualDensity.compact,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                onChanged: (_) => onChanged(done ? TodoStatus.todo : TodoStatus.completed),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          todo.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                            color: done ? scheme.onSurfaceVariant : scheme.onSurface,
                            decoration: done ? TextDecoration.lineThrough : null,
                          ),
                        ),
                      ),
                      if (showPending) ...[
                        const SizedBox(width: 6),
                        const Icon(Icons.cloud_upload_outlined, size: 14, color: Colors.orange),
                      ],
                    ],
                  ),
                  if (todo.description != null && todo.description!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        todo.description!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ),
                  if (pills.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Wrap(spacing: 5, runSpacing: 4, children: pills),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 2),
            // Scheduling and block management live in the editor now, so the
            // row keeps one action: delete (confirmed by the page first).
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 34, minHeight: 34),
              padding: EdgeInsets.zero,
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }

  bool _overdue(DateTime utc) {
    final now = DateTime.now().toUtc();
    return utc.isBefore(now);
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.text, this.color, this.background});

  final String text;
  final Color? color;

  /// Explicit fill for semantic pills (priority containers); otherwise the
  /// text colour is tinted to 14%.
  final Color? background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background ?? (color ?? Colors.grey).withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, color: color ?? Colors.grey),
      ),
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
    this.existingBlocks = const <TodoBlock>[],
  });

  final Todo? existing;
  final List<Tag> tags;
  final List<Category> categories;

  /// Windows already scheduled for [existing]. A one-off loads its single
  /// window inline; a project hands them to TodoBlocksSheet.
  final List<TodoBlock> existingBlocks;

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
  /// Existing one-off windows are loaded into [_blocks]; a project's windows
  /// stay in the mirror and are edited through TodoBlocksSheet.
  late bool _scheduleEnabled;
  final List<_DraftBlock> _blocks = [];

  /// Set when [_blocks] mirrors an already stored one-off window, so saving
  /// updates it instead of creating a duplicate.
  String? _replaceBlockId;

  /// The windows currently stored for [TodoEditorSheet.existing]. Kept in
  /// state because the project entry's subtitle and the "switch off" deletion
  /// must follow the sheet's edits.
  late List<TodoBlock> _persistedBlocks;

  bool _saving = false;

  /// Whether the "tags & more" row shows its chips. Editing a todo that
  /// already carries detail opens it, so nothing silently looks absent.
  late bool _moreExpanded;

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
    _persistedBlocks = [...widget.existingBlocks];
    _scheduleEnabled = widget.existingBlocks.isNotEmpty;
    // A one-off owns exactly one window: show it inline and update that row on
    // save. A project's windows are managed by TodoBlocksSheet instead.
    if (_type == TodoType.oneOff && widget.existingBlocks.isNotEmpty) {
      final block = widget.existingBlocks.first;
      _blocks.add(_DraftBlock(
        startUtc: block.startAt,
        endUtc: block.endAt,
        note: block.blockNote ?? '',
      ));
      _replaceBlockId = block.id;
    }
    _moreExpanded = widget.existing != null &&
        (widget.existing!.categoryId != null ||
            widget.existing!.tagIds.isNotEmpty ||
            widget.existing!.type == TodoType.project);
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
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 12,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(isEdit),
            const SizedBox(height: 12),
            // Visual block 1: title + note fused into one borderless card.
            _buildInputCard(scheme),
            const SizedBox(height: 12),
            // Visual block 2: time / reminder and scheduling.
            AppSegmentedColumn(
              children: [
                _buildTimeItem(userTime, scheme),
                _buildScheduleItem(isEdit, userTime, scheme),
              ],
            ),
            const SizedBox(height: 12),
            // Visual block 3: attributes.
            AppSegmentedColumn(
              children: [
                _buildPriorityItem(scheme),
                _buildCategoryItem(scheme),
                _buildMoreItem(scheme, userTime),
              ],
            ),
            const SizedBox(height: 16),
            // Bottom save stays for one-handed use (and test compatibility).
            FilledButton(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                shape: const StadiumBorder(),
              ),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  /// 18sp title on the left, a rounded save capsule on the right.
  Widget _buildHeader(bool isEdit) {
    return Row(
      children: [
        Expanded(
          child: Text(
            isEdit ? '编辑待办' : '新建待办',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          style: FilledButton.styleFrom(
            minimumSize: Size.zero,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
            shape: const StadiumBorder(),
          ),
          child: const Text('保存'),
        ),
      ],
    );
  }

  /// Immersive input card: borderless title row + hairline + borderless note.
  Widget _buildInputCard(ColorScheme scheme) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
      decoration: BoxDecoration(
        // One tonal step above the sheet (which itself is container-high in
        // dark mode), so the input card reads as its own surface.
        color: dark
            ? scheme.surfaceContainerHighest
            : scheme.surfaceBright,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _title,
                  autofocus: !(widget.existing != null),
                  textInputAction: TextInputAction.next,
                  style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                  decoration: const InputDecoration(
                    hintText: '准备做什么？',
                    // The card is the visual container: no fill, and the
                    // global focused ring must not draw a border inside it.
                    filled: false,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ),
              Container(
                margin: const EdgeInsets.only(left: 4),
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                  shape: BoxShape.circle,
                ),
                child: VoiceInputButton(
                  tooltip: '语音输入待办标题',
                  onText: (text) => setState(() {
                    _title.value = TextEditingValue(
                      text: text,
                      selection: TextSelection.collapsed(offset: text.length),
                    );
                  }),
                ),
              ),
            ],
          ),
          Divider(
            height: 1,
            thickness: 0.5,
            indent: 8,
            endIndent: 8,
            color: scheme.outlineVariant.withValues(alpha: 0.35),
          ),
          TextField(
            controller: _desc,
            minLines: 1,
            maxLines: 3,
            style: const TextStyle(fontSize: 13.5),
            decoration: InputDecoration(
              hintText: '添加备注、要求或步骤（可选）…',
              hintStyle: TextStyle(fontSize: 13.5, color: scheme.onSurfaceVariant),
              filled: false,
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              isDense: true,
              contentPadding: const EdgeInsets.only(top: 8, bottom: 8),
            ),
          ),
        ],
      ),
    );
  }

  /// Row 1: icon tile + reminder/deadline button + clear; row 2: one line of
  /// horizontally scrolling quick picks (never wraps).
  Widget _buildTimeItem(UserTime? userTime, ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const AppIconTile(icon: Icons.event_available_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    // Not a bordered input: a soft filled capsule that still
                    // is an OutlinedButton for the timezone tests.
                    style: OutlinedButton.styleFrom(
                      side: BorderSide.none,
                      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
                      disabledBackgroundColor:
                          scheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      foregroundColor: scheme.onSurface,
                      disabledForegroundColor: scheme.onSurfaceVariant,
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                      shape: const StadiumBorder(),
                    ),
                    icon: Icon(
                      _type == TodoType.oneOff ? Icons.notifications_none : Icons.schedule,
                      size: 18,
                    ),
                    label: Text(_deadlineLabel(userTime)),
                    onPressed: userTime == null ? null : () => _pickDeadline(userTime),
                  ),
                ),
              ),
              if (_deadline != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '清除时间',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => setState(() => _deadline = null),
                ),
            ],
          ),
          if (userTime == null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '用户时区未就绪，暂时无法设置或显示时间。',
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _actionChip(
                  '今天 22:00',
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _atDay(userTime, 0, 22, 0)),
                ),
                const SizedBox(width: 6),
                _actionChip(
                  '明天 18:00',
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _atDay(userTime, 1, 18, 0)),
                ),
                const SizedBox(width: 6),
                _actionChip(
                  '周日 23:59',
                  onPressed: userTime == null
                      ? null
                      : () => setState(() => _deadline = _sundayAt(userTime, 23, 59)),
                ),
                const SizedBox(width: 6),
                _actionChip(
                  '自定义',
                  onPressed: userTime == null ? null : () => _pickDeadline(userTime),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Switch row plus the windows it controls.
  ///
  /// A one-off always has exactly one inline window and no add/remove action.
  /// An existing project opens TodoBlocksSheet (its windows must survive a
  /// cancelled editor); a project being created still drafts its windows here
  /// because they must be written together with the todo.
  Widget _buildScheduleItem(bool isEdit, UserTime? userTime, ColorScheme scheme) {
    final enabled = userTime != null;
    final oneOff = _type == TodoType.oneOff;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: enabled ? () => _setSchedule(!_scheduleEnabled, userTime) : null,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                const AppIconTile(icon: Icons.more_time_rounded),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '排入日程时间表',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: enabled
                              ? scheme.onSurface
                              : scheme.onSurface.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '在课表/周视图中预留专门的执行时间段',
                        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: AppSwitch(
                    value: _scheduleEnabled,
                    onChanged: (v) {
                      if (userTime != null) _setSchedule(v, userTime);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_scheduleEnabled && userTime != null)
          if (oneOff)
            if (_blocks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
                child: _buildBlockEditor(
                  0,
                  userTime,
                  scheme,
                  canRemove: false,
                ),
              )
            else
              const SizedBox.shrink()
          else if (isEdit)
            _buildProjectBlocksEntry(userTime, scheme)
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 12, 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (var i = 0; i < _blocks.length; i++)
                    _buildBlockEditor(i, userTime, scheme, canRemove: true),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('添加执行时间段'),
                      onPressed: () => _addBlock(userTime),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  /// Existing project: its windows live in the mirror, so the editor only
  /// links to the manager sheet and re-reads the count when it closes.
  Widget _buildProjectBlocksEntry(UserTime userTime, ColorScheme scheme) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
      leading: const AppIconTile(icon: Icons.more_time_rounded),
      title: const Text(
        '编辑时间块',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
      ),
      subtitle: Text(
        '已安排 ${_persistedBlocks.length} 个时间块',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      ),
      trailing: Icon(Icons.chevron_right, size: 20, color: scheme.onSurfaceVariant),
      onTap: () => _openBlocksSheet(userTime),
    );
  }

  /// One drafted window as a soft inner card: date / range / duration pills and
  /// a borderless note field.
  Widget _buildBlockEditor(
    int index,
    UserTime userTime,
    ColorScheme scheme, {
    required bool canRemove,
  }) {
    final block = _blocks[index];
    final startLocal = userTime.localFromUtc(block.startUtc);
    final endLocal = userTime.localFromUtc(block.endUtc);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _actionChip(
                        _blockDateLabel(userTime, startLocal),
                        icon: Icons.event,
                        onPressed: () => _pickBlockDate(index, userTime),
                      ),
                      _actionChip(
                        '${_hhmm(startLocal)} – ${_hhmm(endLocal)}',
                        onPressed: () => _pickBlockStart(index, userTime),
                      ),
                      for (final minutes in const [45, 60, 120])
                        _actionChip(
                          _durationLabel(minutes),
                          onPressed: () => setState(
                            () => block.endUtc = _endOnSameDay(
                              userTime,
                              block.startUtc,
                              Duration(minutes: minutes),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (canRemove)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '删除这一段',
                  visualDensity: VisualDensity.compact,
                  onPressed: () => _removeBlock(index),
                ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 6, bottom: 2),
            child: TextField(
              controller: block.note,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                hintText: '这一段具体做什么？（如：查文献）',
                hintStyle: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 6),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Four priority capsules; the selected one takes its semantic container.
  Widget _buildPriorityItem(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          const AppIconTile(icon: Icons.flag_outlined),
          const SizedBox(width: 12),
          Text(
            '优先级',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: scheme.onSurface),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final p in TodoPriority.values) ...[
                    if (p != TodoPriority.values.first) const SizedBox(width: 6),
                    _priorityChip(p, scheme),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _priorityChip(TodoPriority priority, ColorScheme scheme) {
    final selected = _priority == priority;
    final (bg, fg) = switch (priority) {
      TodoPriority.low => (scheme.secondaryContainer, scheme.onSecondaryContainer),
      TodoPriority.normal => (scheme.primaryContainer, scheme.onPrimaryContainer),
      TodoPriority.high => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      TodoPriority.urgent => (scheme.errorContainer, scheme.onErrorContainer),
    };
    return _choiceChip(
      _priorityLabel(priority),
      selected: selected,
      selectedColor: bg,
      selectedForeground: fg,
      onTap: () => setState(() => _priority = priority),
      scheme: scheme,
    );
  }

  /// Category is picked by tapping a capsule; there is no dropdown any more.
  Widget _buildCategoryItem(ColorScheme scheme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          const AppIconTile(icon: Icons.folder_outlined),
          const SizedBox(width: 12),
          Text(
            '分类',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: scheme.onSurface),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _categoryChip(null, '无', scheme),
                  for (final c in _categories) ...[
                    const SizedBox(width: 6),
                    _categoryChip(
                      c.id,
                      c.name,
                      scheme,
                      dot: AppTheme.parseHex(c.color) ?? scheme.primary,
                    ),
                  ],
                  const SizedBox(width: 6),
                  _actionChip('新建', icon: Icons.add, onPressed: _createCategory),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _categoryChip(String? id, String label, ColorScheme scheme, {Color? dot}) {
    final selected = _categoryId == id;
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      avatar: dot == null
          ? null
          : Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
            ),
      onSelected: (_) => setState(() => _categoryId = id),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      selectedColor: scheme.primaryContainer,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: selected ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  /// Tags, estimate and type behind one quiet summary row.
  Widget _buildMoreItem(ColorScheme scheme, UserTime? userTime) {
    final estimate = int.tryParse(_est.text.trim());
    final summary = <String>[
      if (_tagIds.isNotEmpty) '${_tagIds.length} 个标签',
      if (estimate != null) '约$estimate分钟',
      if (_type == TodoType.project) '项目',
    ].join(' · ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _moreExpanded = !_moreExpanded),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
            child: Row(
              children: [
                const AppIconTile(icon: Icons.sell_outlined),
                const SizedBox(width: 12),
                Text(
                  '标签与更多',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500, color: scheme.onSurface),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      summary.isEmpty ? '标签 · 时长 · 类型' : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                    ),
                  ),
                ),
                Icon(
                  _moreExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        if (_moreExpanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
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
                    _actionChip('新建标签', icon: Icons.add, onPressed: _createTag),
                  ],
                ),
                const SizedBox(height: 10),
                Text('预计时长', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final minutes in const [30, 60, 120])
                      _choiceChip(
                        '$minutes分',
                        selected: estimate == minutes,
                        selectedColor: scheme.primaryContainer,
                        selectedForeground: scheme.onPrimaryContainer,
                        onTap: () => setState(() => _est.text = '$minutes'),
                        scheme: scheme,
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('类型', style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    _choiceChip(
                      '一次性',
                      selected: _type == TodoType.oneOff,
                      selectedColor: scheme.primaryContainer,
                      selectedForeground: scheme.onPrimaryContainer,
                      onTap: () => _setType(TodoType.oneOff, userTime),
                      scheme: scheme,
                    ),
                    _choiceChip(
                      '项目',
                      selected: _type == TodoType.project,
                      selectedColor: scheme.primaryContainer,
                      selectedForeground: scheme.onPrimaryContainer,
                      onTap: () => _setType(TodoType.project, userTime),
                      scheme: scheme,
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    // A one-off is a single errand / meeting / shopping list:
                    // at most one block, plus an optional reminder time.
                    _type == TodoType.oneOff
                        ? '临时活动、会议或购物清单：最多 1 个时间块，可设提醒时间'
                        : '多阶段任务：可拆成多个时间块，可设截止时间',
                    style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  /// Borderless capsule chip for quick picks and inline actions.
  Widget _actionChip(String label, {VoidCallback? onPressed, IconData? icon}) {
    final scheme = Theme.of(context).colorScheme;
    return ActionChip(
      avatar: icon == null ? null : Icon(icon, size: 16),
      label: Text(label),
      labelStyle: const TextStyle(fontSize: 12),
      onPressed: onPressed,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  /// Selected-state capsule (priority, estimate, type).
  Widget _choiceChip(
    String label, {
    required bool selected,
    required Color selectedColor,
    required Color selectedForeground,
    required VoidCallback onTap,
    required ColorScheme scheme,
  }) {
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      onSelected: (_) => onTap(),
      side: BorderSide.none,
      shape: const StadiumBorder(),
      backgroundColor: scheme.surfaceContainerHighest.withValues(alpha: 0.7),
      selectedColor: selectedColor,
      labelStyle: TextStyle(
        fontSize: 12,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        color: selected ? selectedForeground : scheme.onSurfaceVariant,
      ),
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      padding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }

  /// `45分` / `1小时` / `2小时`.
  String _durationLabel(int minutes) => switch (minutes) {
        45 => '45分',
        60 => '1小时',
        120 => '2小时',
        _ => '$minutes分',
      };

  /// Toggles scheduling. Turning it off for a todo that already owns windows
  /// asks first, because confirming deletes them; a never-saved draft simply
  /// disappears.
  Future<void> _setSchedule(bool value, UserTime userTime) async {
    if (value == _scheduleEnabled) return;
    if (value) {
      setState(() {
        _scheduleEnabled = true;
        if (_type == TodoType.oneOff) {
          // A one-off owns exactly one window.
          if (_blocks.length > 1) {
            for (final b in _blocks.skip(1)) {
              b.dispose();
            }
            _blocks.removeRange(1, _blocks.length);
          }
          if (_blocks.isEmpty) _blocks.add(_defaultBlock(userTime));
        }
      });
      return;
    }

    final persisted = _persistedBlocks;
    if (widget.existing != null && persisted.isNotEmpty) {
      final confirmed = await showAppDialog<bool>(
        context: context,
        title: '关闭排入日程时间表？',
        content: Text('关闭后会删除已安排的 ${persisted.length} 个时间块。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context, rootNavigator: true).pop(true),
            child: const Text('关闭'),
          ),
        ],
      );
      if (confirmed != true || !mounted) return;
      final repo = ref.read(servicesProvider).repo;
      for (final block in persisted) {
        await repo.localDelete(
          entityType: EntityTypes.todoBlock,
          entityId: block.id,
        );
      }
      if (!mounted) return;
      setState(() {
        _persistedBlocks = [];
        _replaceBlockId = null;
        _scheduleEnabled = false;
        for (final b in _blocks) {
          b.dispose();
        }
        _blocks.clear();
      });
      return;
    }

    setState(() {
      _scheduleEnabled = false;
      for (final b in _blocks) {
        b.dispose();
      }
      _blocks.clear();
    });
  }

  /// Switching type keeps the window UI coherent: a one-off can hold only the
  /// first drafted window and always shows one while scheduling is on.
  void _setType(TodoType type, UserTime? userTime) {
    setState(() {
      _type = type;
      if (type == TodoType.oneOff) {
        if (_blocks.length > 1) {
          for (final b in _blocks.skip(1)) {
            b.dispose();
          }
          _blocks.removeRange(1, _blocks.length);
        }
        if (_scheduleEnabled && _blocks.isEmpty && userTime != null) {
          _blocks.add(_defaultBlock(userTime));
        }
      }
    });
  }

  /// Existing project: windows are edited in the manager sheet, then re-read
  /// from the mirror. Closing it empty turns scheduling back off.
  Future<void> _openBlocksSheet(UserTime userTime) async {
    final todo = widget.existing;
    if (todo == null) return;
    await showAppBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => TodoBlocksSheet(todo: todo, userTime: userTime),
    );
    if (!mounted) return;
    final snap = ref.read(snapshotProvider).value;
    final blocks = snap == null
        ? <TodoBlock>[]
        : liveBlocks(snap, todoId: todo.id).map((e) => e.value).toList();
    setState(() {
      _persistedBlocks = blocks;
      if (blocks.isEmpty) _scheduleEnabled = false;
    });
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
    setState(() => _blocks.add(_defaultBlock(userTime)));
  }

  void _removeBlock(int index) {
    setState(() {
      _blocks.removeAt(index).dispose();
      // No drafts left means nothing to schedule: do not leave a switch on
      // for an empty list.
      if (_blocks.isEmpty) _scheduleEnabled = false;
    });
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

  Future<void> _pickBlockStart(int index, UserTime userTime) async {
    final block = _blocks[index];
    final startLocal = userTime.localFromUtc(block.startUtc);
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: startLocal.hour, minute: startLocal.minute),
    );
    if (time == null || !mounted) return;
    setState(() {
      final duration = block.endUtc.difference(block.startUtc);
      block.startUtc = userTime.utcFromLocalParts(startLocal.year,
          startLocal.month, startLocal.day, time.hour, time.minute);
      block.endUtc = _endOnSameDay(userTime, block.startUtc,
          duration.isNegative || duration == Duration.zero
              ? const Duration(hours: 1)
              : duration);
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
    final isEdit = widget.existing != null;
    // Blocks are written together with a new todo. An existing todo's blocks
    // are reconciled below instead, so they are never created twice.
    final newBlocks = !isEdit && _scheduleEnabled
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
      if (isEdit) await _saveExistingBlocks();
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Existing todo only: a one-off's single window is updated or created, and
  /// switching scheduling off removes anything still stored. A project's
  /// windows belong to TodoBlocksSheet and are left untouched here.
  Future<void> _saveExistingBlocks() async {
    final todo = widget.existing;
    if (todo == null || _type == TodoType.project) return;
    final repo = ref.read(servicesProvider).repo;
    if (!_scheduleEnabled) {
      // Defensive: the toggle already deleted them, but a stale window must
      // never outlive a switched-off schedule.
      for (final block in _persistedBlocks) {
        await repo.localDelete(
          entityType: EntityTypes.todoBlock,
          entityId: block.id,
        );
      }
      _persistedBlocks = [];
      return;
    }
    if (_blocks.isEmpty) return;
    final draft = _blocks.first;
    final note = draft.note.text.trim();
    final blockNote = note.isEmpty ? null : note;
    final replaceId = _replaceBlockId;
    if (replaceId != null) {
      await repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: replaceId,
        changes: {
          'startAt': draft.startUtc,
          'endAt': draft.endUtc,
          'blockNote': blockNote,
        },
      );
    } else {
      await repo.localCreate(
        entityType: EntityTypes.todoBlock,
        snapshot: {
          'todoId': todo.id,
          'startAt': draft.startUtc,
          'endAt': draft.endUtc,
          'blockNote': blockNote,
          'status': BlockStatus.scheduled.wire,
        },
      );
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
