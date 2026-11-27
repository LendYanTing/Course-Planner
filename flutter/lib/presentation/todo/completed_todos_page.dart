import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/time/user_time.dart';
import '../../data/local/view_models.dart';
import '../../domain/todo.dart';
import '../../state/prefs.dart';
import '../../state/providers.dart';
import '../../state/sync_controller.dart';
import '../../state/todo_controller.dart';
import '../adaptive/adaptive.dart';

/// Read-only history of completed todos.
///
/// Completed items left the main todo list; this second-level page owns
/// searching, category/time filtering, the history size preference and the
/// bulk "restore to open / delete" actions. Every write still goes through
/// [TodoController], so the page holds only transient view state.
class CompletedTodosPage extends ConsumerStatefulWidget {
  const CompletedTodosPage({super.key});

  @override
  ConsumerState<CompletedTodosPage> createState() => _CompletedTodosPageState();
}

class _CompletedTodosPageState extends ConsumerState<CompletedTodosPage> {
  final TextEditingController _search = TextEditingController();
  String _keyword = '';
  String? _categoryId;
  DateTimeRange? _range;

  final Set<String> _selected = {};
  bool _selecting = false;
  bool _working = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  static DateTime _sortInstant(Todo todo) =>
      todo.deadlineAt ??
      todo.createdAt ??
      DateTime.fromMillisecondsSinceEpoch(0);

  @override
  Widget build(BuildContext context) {
    // The bulk actions fire later; watching the notifier keeps the
    // auto-dispose controller alive while this page is open.
    ref.watch(todoControllerProvider.notifier);
    final snap = ref.watch(snapshotProvider).value;
    final userTime = ref.watch(userTimeProvider);
    final limit = ref.watch(completedHistoryLimitProvider);
    final todos = snap == null ? const <Live<Todo>>[] : liveTodos(snap);
    final categories =
        snap == null ? const <Live<Category>>[] : liveCategories(snap);
    final categoryById = {
      for (final c in categories) c.value.id: c.value,
    };

    final completed = todos.where((t) => t.value.isCompleted).toList()
      ..sort((a, b) => _sortInstant(b.value).compareTo(_sortInstant(a.value)));

    final keyword = _keyword.trim().toLowerCase();
    final filtered = completed.where((live) {
      final todo = live.value;
      if (keyword.isNotEmpty) {
        final haystack =
            '${todo.title}\n${todo.description ?? ''}'.toLowerCase();
        if (!haystack.contains(keyword)) return false;
      }
      if (_categoryId != null && todo.categoryId != _categoryId) return false;
      final range = _range;
      if (range != null) {
        final raw = todo.deadlineAt ?? todo.createdAt;
        if (raw == null) return false;
        final local = userTime?.localFromUtc(raw) ?? raw.toUtc();
        final day = DateTime(local.year, local.month, local.day);
        final start =
            DateTime(range.start.year, range.start.month, range.start.day);
        final end = DateTime(range.end.year, range.end.month, range.end.day);
        if (day.isBefore(start) || day.isAfter(end)) return false;
      }
      return true;
    }).toList();

    // Newest first, then cap to the persisted history size (0 = all).
    final shown = limit == 0 || filtered.length <= limit
        ? filtered
        : filtered.sublist(0, limit);

    final groups = <({Category? category, List<Live<Todo>> items})>[];
    for (final c in categories) {
      final items =
          shown.where((t) => t.value.categoryId == c.value.id).toList();
      if (items.isNotEmpty) groups.add((category: c.value, items: items));
    }
    final uncategorised = shown.where((t) {
      final id = t.value.categoryId;
      return id == null || !categoryById.containsKey(id);
    }).toList();
    if (uncategorised.isNotEmpty) {
      groups.add((category: null, items: uncategorised));
    }

    final shownIds = {for (final t in shown) t.value.id};

    return Scaffold(
      appBar: AppTopBar(
        title: '已完成',
        actions: _selecting
            ? [
                Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Center(
                    child: Text(
                      '已选 ${_selected.length}',
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selected
                      ..clear()
                      ..addAll(shownIds);
                  }),
                  child: const Text('全选'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selected.clear();
                    _selecting = false;
                  }),
                  child: const Text('取消'),
                ),
              ]
            : [
                IconButton(
                  icon: const Icon(Icons.checklist),
                  tooltip: '多选',
                  onPressed: () => setState(() => _selecting = true),
                ),
              ],
      ),
      bottomNavigationBar: _selecting && _selected.isNotEmpty
          ? _buildSelectionBar(completed)
          : null,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          _buildFilterCard(categories, limit),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 6),
            child: Text(
              limit == 0
                  ? '共 ${filtered.length} 条'
                  : '共 ${filtered.length} 条 · 显示最近 ${shown.length} 条',
              key: const ValueKey('completed-count'),
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (shown.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 48),
              child: Center(child: Text('没有符合条件的已完成任务')),
            )
          else
            for (final g in groups) ...[
              _GroupHeading(
                title: g.category?.name ?? '未分类',
                accent: AppTheme.parseHex(g.category?.color) ??
                    Theme.of(context).colorScheme.primary,
                count: g.items.length,
              ),
              AppSegmentedColumn(
                margin: const EdgeInsets.only(bottom: 8),
                children: [
                  for (final live in g.items)
                    _buildTile(live.value, categoryById, userTime),
                ],
              ),
            ],
        ],
      ),
    );
  }

  Widget _buildFilterCard(
    List<Live<Category>> categories,
    int limit,
  ) {
    final scheme = Theme.of(context).colorScheme;
    return AppCard(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            onChanged: (v) => setState(() => _keyword = v),
            decoration: InputDecoration(
              hintText: '搜索标题或备注',
              prefixIcon: const Icon(Icons.search, size: 20),
              isDense: true,
              filled: true,
              fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _categoryChip(
                  null,
                  '全部',
                  scheme,
                ),
                for (final c in categories) ...[
                  const SizedBox(width: 6),
                  _categoryChip(
                    c.value.id,
                    c.value.name,
                    scheme,
                    dot: AppTheme.parseHex(c.value.color) ?? scheme.primary,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.date_range, size: 18),
                    label: Text(_rangeLabel()),
                  ),
                ),
              ),
              if (_range != null)
                IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: '清除时间范围',
                  onPressed: () => setState(() => _range = null),
                ),
            ],
          ),
          const SizedBox(height: 2),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                '显示条数',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              for (final value in CompletedHistoryLimitController.choices)
                ChoiceChip(
                  label: Text(value == 0 ? '全部' : '$value'),
                  selected: limit == value,
                  onSelected: (_) =>
                      ref.read(completedHistoryLimitProvider.notifier).set(value),
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _categoryChip(
    String? id,
    String label,
    ColorScheme scheme, {
    Color? dot,
  }) {
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

  String _rangeLabel() {
    final range = _range;
    if (range == null) return '全部时间';
    return '${range.start.month}月${range.start.day}日 – '
        '${range.end.month}月${range.end.day}日';
  }

  Future<void> _pickRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      initialDateRange: _range,
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
  }

  Widget _buildTile(
    Todo todo,
    Map<String, Category> categoryById,
    UserTime? userTime,
  ) {
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(8, 0, 10, 0),
      leading: _selecting
          ? Checkbox(
              value: _selected.contains(todo.id),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(6),
              ),
              onChanged: (_) => _toggle(todo),
            )
          : null,
      title: Text(
        todo.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      subtitle: _subtitle(todo, categoryById, userTime),
      trailing: _PriorityPill(priority: todo.priority),
      onTap: _selecting ? () => _toggle(todo) : null,
      onLongPress: () => _startSelection(todo),
    );
  }

  Widget? _subtitle(
    Todo todo,
    Map<String, Category> categoryById,
    UserTime? userTime,
  ) {
    final parts = <String>[];
    final category = todo.categoryId == null
        ? null
        : categoryById[todo.categoryId];
    if (category != null) parts.add(category.name);
    final deadline = todo.deadlineAt;
    if (deadline != null && userTime != null) {
      parts.add('截止 ${userTime.formatDateMonthDayHm(deadline)}');
    } else {
      final created = todo.createdAt;
      if (created != null && userTime != null) {
        final local = userTime.localFromUtc(created);
        parts.add('创建 ${local.month}月${local.day}日');
      }
    }
    if (parts.isEmpty) return null;
    final scheme = Theme.of(context).colorScheme;
    return Text(
      parts.join(' · '),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
    );
  }

  void _toggle(Todo todo) {
    setState(() {
      if (!_selected.remove(todo.id)) _selected.add(todo.id);
      if (_selected.isEmpty) _selecting = false;
    });
  }

  void _startSelection(Todo todo) {
    setState(() {
      _selecting = true;
      _selected.add(todo.id);
    });
  }

  Widget _buildSelectionBar(List<Live<Todo>> completed) {
    final scheme = Theme.of(context).colorScheme;
    final count = _selected.length;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: _working ? null : () => _restore(completed),
                child: Text('恢复为待办 ($count)'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: scheme.error,
                  foregroundColor: scheme.onError,
                ),
                onPressed: _working ? null : () => _confirmDelete(completed),
                child: Text('删除 ($count)'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Todo> _selectedTodos(List<Live<Todo>> completed) => [
        for (final live in completed)
          if (_selected.contains(live.value.id)) live.value,
      ];

  Future<void> _restore(List<Live<Todo>> completed) async {
    final todos = _selectedTodos(completed);
    if (todos.isEmpty || _working) return;
    setState(() => _working = true);
    final controller = ref.read(todoControllerProvider.notifier);
    for (final todo in todos) {
      await controller.setStatus(todo, TodoStatus.todo);
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _selected.clear();
      _selecting = false;
    });
  }

  Future<void> _confirmDelete(List<Live<Todo>> completed) async {
    final todos = _selectedTodos(completed);
    if (todos.isEmpty || _working) return;
    final confirmed = await showAppDialog<bool>(
      context: context,
      title: '删除已完成任务？',
      content: Text('删除 ${todos.length} 个已完成任务？删除后无法恢复。'),
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
    setState(() => _working = true);
    final controller = ref.read(todoControllerProvider.notifier);
    for (final todo in todos) {
      await controller.delete(todo);
    }
    if (!mounted) return;
    setState(() {
      _working = false;
      _selected.clear();
      _selecting = false;
    });
  }
}

/// Category section header: accent dot, title and count badge.
class _GroupHeading extends StatelessWidget {
  const _GroupHeading({
    required this.title,
    required this.accent,
    required this.count,
  });

  final String title;
  final Color accent;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 8, 6, 6),
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
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              '$count',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: accent,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Small priority capsule shown at the row's trailing edge.
class _PriorityPill extends StatelessWidget {
  const _PriorityPill({required this.priority});

  final TodoPriority priority;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, label) = switch (priority) {
      TodoPriority.low => (
          scheme.surfaceContainerHighest,
          scheme.onSurfaceVariant,
          '低',
        ),
      TodoPriority.normal => (
          scheme.secondaryContainer,
          scheme.onSecondaryContainer,
          '普通',
        ),
      TodoPriority.high => (
          scheme.tertiaryContainer,
          scheme.onTertiaryContainer,
          '高',
        ),
      TodoPriority.urgent => (
          scheme.errorContainer,
          scheme.error,
          '紧急',
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, color: foreground),
      ),
    );
  }
}
