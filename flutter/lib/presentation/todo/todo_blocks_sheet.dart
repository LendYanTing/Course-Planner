import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/time/user_time.dart';
import '../../data/local/view_models.dart';
import '../../domain/entities.dart';
import '../../domain/todo.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';

/// Time-block manager for a project todo (docs/domain-model.md §8-9).
///
/// Lists the todo's scheduled execution windows and lets the user add, edit
/// (time + block note) and delete them. Times are interpreted in the user's
/// fixed timezone. Reads blocks reactively from the snapshot, so edits refresh
/// in place. Opened from the todo tile's menu for project-type todos.
class TodoBlocksSheet extends ConsumerStatefulWidget {
  const TodoBlocksSheet({super.key, required this.todo, required this.userTime});

  final Todo todo;
  final UserTime userTime;

  @override
  ConsumerState<TodoBlocksSheet> createState() => _TodoBlocksSheetState();
}

class _TodoBlocksSheetState extends ConsumerState<TodoBlocksSheet> {
  Future<void> _add() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BlockEditor(todo: widget.todo, userTime: widget.userTime),
    );
  }

  Future<void> _edit(TodoBlock block) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _BlockEditor(todo: widget.todo, userTime: widget.userTime, existing: block),
    );
  }

  Future<void> _delete(TodoBlock block) async {
    await ref.read(servicesProvider).repo.localDelete(entityType: EntityTypes.todoBlock, entityId: block.id);
    ref.read(syncCoordinatorProvider.notifier).syncNow();
  }

  @override
  Widget build(BuildContext context) {
    final snap = ref.watch(snapshotProvider).value;
    final blocks = (snap == null ? <Live<TodoBlock>>[] : liveBlocks(snap, todoId: widget.todo.id))
        .map((e) => e.value)
        .toList()
      ..sort((a, b) => a.startAt.compareTo(b.startAt));
    // A one-off is one errand: at most a single block (project cap is none).
    final atLimit = widget.todo.type == TodoType.oneOff && blocks.isNotEmpty;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.72,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text('时间块 · ${widget.todo.title}',
                        style: Theme.of(context).textTheme.titleMedium),
                  ),
                  Text('${blocks.length} 个', style: const TextStyle(color: Colors.grey, fontSize: 12)),
                ],
              ),
            ),
            Expanded(
              child: blocks.isEmpty
                  ? const Center(child: Text('还没有时间块，点下方添加'))
                  : ListView(
                      children: [
                        for (final b in blocks)
                          ListTile(
                            onTap: () => _edit(b),
                            leading: const Icon(Icons.schedule),
                            title: Text(_range(b, widget.userTime)),
                            subtitle: b.blockNote == null || b.blockNote!.isEmpty
                                ? null
                                : Text(b.blockNote!, maxLines: 2, overflow: TextOverflow.ellipsis),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _statusChip(b),
                                IconButton(
                                  icon: const Icon(Icons.delete_outline),
                                  onPressed: () => _delete(b),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
            ),
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (atLimit)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 6),
                        child: Text(
                          '一次性待办只安排 1 个时间块；多个时间块请把类型改为「项目」。',
                          style: TextStyle(fontSize: 11, color: Colors.grey),
                        ),
                      ),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.add),
                        label: const Text('添加时间块'),
                        onPressed: atLimit ? null : _add,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _range(TodoBlock b, UserTime userTime) {
    final s = userTime.localFromUtc(b.startAt);
    final e = userTime.localFromUtc(b.endAt);
    String hhmm(DateTime local) =>
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    if (s.month == e.month && s.day == e.day) {
      return '${s.month}月${s.day}日 ${hhmm(s)} – ${hhmm(e)}';
    }
    return '${s.month}月${s.day}日 ${hhmm(s)} – ${e.month}月${e.day}日 ${hhmm(e)}';
  }

  Widget _statusChip(TodoBlock b) {
    final map = {
      BlockStatus.scheduled: ('已安排', Colors.blueGrey),
      BlockStatus.inProgress: ('进行中', Colors.orange),
      BlockStatus.completed: ('已完成', Colors.green),
      BlockStatus.skipped: ('已跳过', Colors.grey),
    };
    final (label, color) = map[b.status]!;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(label, style: TextStyle(fontSize: 10, color: color)),
    );
  }
}

/// Add / edit one time block: start/end wall-clock + block note.
class _BlockEditor extends ConsumerStatefulWidget {
  const _BlockEditor({required this.todo, required this.userTime, this.existing});

  final Todo todo;
  final UserTime userTime;
  final TodoBlock? existing;

  @override
  ConsumerState<_BlockEditor> createState() => _BlockEditorState();
}

class _BlockEditorState extends ConsumerState<_BlockEditor> {
  late DateTime _start; // UTC instant
  late DateTime _end; // UTC instant
  late final TextEditingController _note;

  @override
  void initState() {
    super.initState();
    _note = TextEditingController(text: widget.existing?.blockNote ?? '');
    if (widget.existing != null) {
      _start = widget.existing!.startAt;
      _end = widget.existing!.endAt;
    } else {
      final local = widget.userTime.localFromUtc(DateTime.now().toUtc());
      final startMinute = ((local.hour + 1) * 60).clamp(0, 23 * 60);
      _start = widget.userTime
          .fromLocalParts(local.year, local.month, local.day, startMinute ~/ 60, 0)
          .toUtc();
      _end = _start.add(const Duration(minutes: 60));
    }
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(isEdit ? '编辑时间块' : '添加时间块', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: _timeLabel('开始', _start)),
            const SizedBox(width: 8),
            Expanded(child: _timeLabel('结束', _end)),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _note,
            maxLines: 2,
            decoration: const InputDecoration(labelText: '备注（可选）'),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
    );
  }

  Widget _timeLabel(String label, DateTime utc) {
    final local = widget.userTime.localFromUtc(utc);
    return OutlinedButton.icon(
      icon: const Icon(Icons.schedule),
      label: Text('$label ${local.month}/${local.day} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}'),
      onPressed: () => _pick(label == '开始'),
    );
  }

  Future<void> _pick(bool isStart) async {
    final base = widget.userTime.localFromUtc(isStart ? _start : _end);
    final date = await showDatePicker(
      context: context,
      initialDate: base,
      firstDate: DateTime(base.year - 1),
      lastDate: DateTime(base.year + 5),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: base.hour, minute: base.minute),
    );
    if (time == null || !mounted) return;
    final local = widget.userTime.fromLocalParts(date.year, date.month, date.day, time.hour, time.minute);
    setState(() {
      if (isStart) {
        _start = local.toUtc();
        if (_end.isBefore(_start)) _end = _start.add(const Duration(minutes: 60));
      } else {
        _end = local.toUtc();
      }
    });
  }

  Future<void> _save() async {
    final repo = ref.read(servicesProvider).repo;
    final note = _note.text.trim();
    if (widget.existing == null) {
      await repo.localCreate(
        entityType: EntityTypes.todoBlock,
        snapshot: {
          'todoId': widget.todo.id,
          'startAt': _start,
          'endAt': _end,
          'status': BlockStatus.scheduled.wire,
          if (note.isNotEmpty) 'blockNote': note,
        },
      );
    } else {
      await repo.localUpdate(
        entityType: EntityTypes.todoBlock,
        entityId: widget.existing!.id,
        changes: {
          'startAt': _start,
          'endAt': _end,
          'blockNote': note.isEmpty ? null : note,
        },
      );
    }
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}
