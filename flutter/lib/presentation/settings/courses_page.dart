import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/theme.dart';
import '../../core/util/week_text.dart';
import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../domain/course.dart';
import '../../domain/entities.dart';
import '../../state/app_services.dart';
import '../../state/sync_controller.dart';

const kPalette = <String>[
  '#4A6FA5', '#26A69A', '#7E57C2', '#EF6C00', '#E53935',
  '#43A047', '#8D6E63', '#5C6BC0', '#F4511E', '#00897B',
];

/// Course management: semester tabs; per semester courses + their meetings.
class CoursesPage extends ConsumerWidget {
  const CoursesPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final snap = ref.watch(snapshotProvider).value;
    final calendars = snap == null ? <Live<AcademicCalendar>>[] : liveCalendars(snap);
    final courses = snap == null ? <Live<Course>>[] : liveCourses(snap);
    final meetings = snap == null ? <Live<CourseMeeting>>[] : liveMeetings(snap);

    final byCourse = <String, List<CourseMeeting>>{};
    for (final m in meetings) {
      byCourse.putIfAbsent(m.value.courseId, () => []).add(m.value);
    }

    if (calendars.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('课程管理')),
        body: const Center(child: Text('请先在「学期管理」中创建学期')),
      );
    }
    if (calendars.length == 1) {
      return Scaffold(
        appBar: AppBar(title: const Text('课程管理')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: () => showModalBottomSheet<void>(
            context: context,
            isScrollControlled: true,
            builder: (_) => CourseEditor(
              calendarId: calendars.first.value.id,
              periods: livePeriodsOrEmpty(ref, calendars.first.value.id),
            ),
          ),
          icon: const Icon(Icons.add),
          label: const Text('添加课程'),
        ),
        body: _Body(
          calendar: calendars.first.value,
          courses: courses.where((c) => c.value.calendarId == calendars.first.value.id).map((e) => e.value).toList(),
          meetingsByCourse: byCourse,
        ),
      );
    }

    return DefaultTabController(
      length: calendars.length,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('课程管理'),
          bottom: TabBar(isScrollable: true, tabs: [for (final c in calendars) Tab(text: c.value.name)]),
        ),
        body: TabBarView(
          children: [
            for (final cal in calendars)
              _Body(
                calendar: cal.value,
                courses: courses.where((c) => c.value.calendarId == cal.value.id).map((e) => e.value).toList(),
                meetingsByCourse: byCourse,
              ),
          ],
        ),
      ),
    );
  }

  List<PeriodTemplate> livePeriodsOrEmpty(WidgetRef ref, String calendarId) {
    final snap = ref.read(snapshotProvider).value;
    if (snap == null) return const [];
    return livePeriods(snap, calendarId: calendarId).map((e) => e.value).toList();
  }
}

class _Body extends StatelessWidget {
  const _Body({
    required this.calendar,
    required this.courses,
    required this.meetingsByCourse,
  });

  final AcademicCalendar calendar;
  final List<Course> courses;
  final Map<String, List<CourseMeeting>> meetingsByCourse;

  @override
  Widget build(BuildContext context) {
    if (courses.isEmpty) return const Center(child: Text('还没有课程'));
    return ListView(
      children: [
        for (final c in courses)
          _CourseCard(
            course: c,
            meetings: meetingsByCourse[c.id] ?? const [],
            calendar: calendar,
          ),
      ],
    );
  }
}

class _CourseCard extends ConsumerWidget {
  const _CourseCard({
    required this.course,
    required this.meetings,
    required this.calendar,
  });

  final Course course;
  final List<CourseMeeting> meetings;
  final AcademicCalendar calendar;

  static const _wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(servicesProvider).repo;
    return Card(
      child: ExpansionTile(
        leading: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: AppTheme.parseHex(course.color) ?? Colors.grey,
            shape: BoxShape.circle,
          ),
        ),
        title: Text(course.name),
        subtitle: Text([if (course.teacher != null) course.teacher!, if (course.location != null) course.location!].join(' · ')),
        children: [
          for (final m in meetings)
            ListTile(
              dense: true,
              title: Text('${_wd[m.weekday - 1]} 第${m.periodStart}–${m.periodEnd}节'),
              subtitle: Text('周次：${m.weekRule.describe()}'),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  repo.localDelete(entityType: EntityTypes.courseMeeting, entityId: m.id);
                  ref.read(syncCoordinatorProvider.notifier).syncNow();
                },
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                TextButton.icon(
                  icon: const Icon(Icons.add),
                  label: const Text('添加课次'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    builder: (_) => MeetingEditor(courseId: course.id, calendar: calendar),
                  ),
                ),
                TextButton.icon(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('编辑课程'),
                  onPressed: () => showModalBottomSheet<void>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => CourseEditor(calendarId: course.calendarId, existing: course),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.delete),
                  onPressed: () {
                    repo.localDelete(entityType: EntityTypes.course, entityId: course.id);
                    ref.read(syncCoordinatorProvider.notifier).syncNow();
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Course create/edit form.
class CourseEditor extends ConsumerStatefulWidget {
  const CourseEditor({super.key, required this.calendarId, this.existing, this.periods = const []});

  final String calendarId;
  final Course? existing;
  final List<PeriodTemplate> periods;

  @override
  ConsumerState<CourseEditor> createState() => _CourseEditorState();
}

class _CourseEditorState extends ConsumerState<CourseEditor> {
  late final TextEditingController _name;
  late final TextEditingController _teacher;
  late final TextEditingController _location;
  String? _color;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _teacher = TextEditingController(text: widget.existing?.teacher ?? '');
    _location = TextEditingController(text: widget.existing?.location ?? '');
    _color = widget.existing?.color;
  }

  @override
  void dispose() {
    _name.dispose();
    _teacher.dispose();
    _location.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return Padding(
      padding: EdgeInsets.only(left: 20, right: 20, top: 16, bottom: MediaQuery.of(context).viewInsets.bottom + 16),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(isEdit ? '编辑课程' : '添加课程', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(controller: _name, decoration: const InputDecoration(labelText: '课程名称')),
            const SizedBox(height: 10),
            TextField(controller: _teacher, decoration: const InputDecoration(labelText: '老师（可选）')),
            const SizedBox(height: 10),
            TextField(controller: _location, decoration: const InputDecoration(labelText: '地点（可选）')),
            const SizedBox(height: 10),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('颜色（课表/周视图色块）', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                // No explicit colour → the timetable falls back to its default
                // course blue. Lets courses stay visually distinct from each
                // other instead of every course sharing the first palette entry.
                ChoiceChip(
                  label: const Text('默认'),
                  selected: _color == null,
                  onSelected: (_) => setState(() => _color = null),
                ),
                for (final hex in kPalette)
                  InkWell(
                    onTap: () => setState(() => _color = hex),
                    child: Container(
                      width: 26,
                      height: 26,
                      decoration: BoxDecoration(
                        color: AppTheme.parseHex(hex),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _color == hex ? Colors.black : Colors.transparent,
                          width: 2,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final repo = ref.read(servicesProvider).repo;
    final fields = {
      'calendarId': widget.calendarId,
      'name': name,
      'teacher': _teacher.text.trim().isEmpty ? null : _teacher.text.trim(),
      'location': _location.text.trim().isEmpty ? null : _location.text.trim(),
      'color': _color,
      'notes': null,
    };
    if (widget.existing == null) {
      await repo.localCreate(entityType: EntityTypes.course, snapshot: fields);
    } else {
      await repo.localUpdate(
        entityType: EntityTypes.course,
        entityId: widget.existing!.id,
        changes: Map.of(fields)..remove('calendarId'),
      );
    }
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}

/// One course meeting form: weekday + period range + week rule text.
class MeetingEditor extends ConsumerStatefulWidget {
  const MeetingEditor({super.key, required this.courseId, required this.calendar});

  final String courseId;
  final AcademicCalendar calendar;

  @override
  ConsumerState<MeetingEditor> createState() => _MeetingEditorState();
}

class _MeetingEditorState extends ConsumerState<MeetingEditor> {
  static const _wd = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  int _weekday = 1;
  late final TextEditingController _periodStart;
  late final TextEditingController _periodEnd;
  late final TextEditingController _weeks;

  @override
  void initState() {
    super.initState();
    _periodStart = TextEditingController(text: '1');
    _periodEnd = TextEditingController(text: '1');
    _weeks = TextEditingController(text: '1-${widget.calendar.totalWeeks}');
  }

  @override
  void dispose() {
    _periodStart.dispose();
    _periodEnd.dispose();
    _weeks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('添加课次', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          DropdownButtonFormField<int>(
            initialValue: _weekday,
            decoration: const InputDecoration(labelText: '星期'),
            items: [for (var i = 0; i < 7; i++) DropdownMenuItem(value: i + 1, child: Text(_wd[i]))],
            onChanged: (v) => setState(() => _weekday = v ?? 1),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: TextField(controller: _periodStart, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '开始节次')),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextField(controller: _periodEnd, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '结束节次')),
            ),
          ]),
          const SizedBox(height: 10),
          TextField(
            controller: _weeks,
            decoration: const InputDecoration(
              labelText: '周次规则',
              helperText: '如 1-16、1-5、2、5、8、1-5、7-11单、12-16双',
            ),
          ),
          const SizedBox(height: 10),
          Text('学期共 ${widget.calendar.totalWeeks} 周'),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _save,
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Future<void> _save() async {
    final rule = parseWeekRuleText(_weeks.text);
    if (rule == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('周次规则无法解析')));
      return;
    }
    await ref.read(servicesProvider).repo.localCreate(
      entityType: EntityTypes.courseMeeting,
      snapshot: {
        'courseId': widget.courseId,
        'weekday': _weekday,
        'periodStart': int.tryParse(_periodStart.text.trim()) ?? 1,
        'periodEnd': int.tryParse(_periodEnd.text.trim()) ?? 1,
        'weekRule': rule.toJson(),
      },
    );
    ref.read(syncCoordinatorProvider.notifier).syncNow();
    if (mounted) Navigator.of(context).pop();
  }
}
