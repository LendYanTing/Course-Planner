import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/local/view_models.dart';
import '../../domain/calendar.dart';
import '../../state/prefs.dart';
import '../../state/sync_controller.dart';
import '../adaptive/adaptive.dart';

/// 课程与学期 (`/settings/course-hub`).
///
/// Second-level page for everything that shapes the timetable: semesters,
/// courses, recurring schedules and the two importers. The hub keeps a single
/// entry for it so the settings list stays scannable.
class CourseSettingsPage extends ConsumerWidget {
  const CourseSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeId = ref.watch(activeSemesterProvider);
    // Active semester (and its course count) feeds the two row subtitles.
    AcademicCalendar? semester;
    var courseCount = 0;
    final snap = ref.watch(snapshotProvider).value;
    if (snap != null) {
      for (final cal in liveCalendars(snap)) {
        if (cal.value.id == activeId) semester = cal.value;
      }
      courseCount = liveCourses(snap, calendarId: semester?.id).length;
    }

    return Scaffold(
      appBar: AppTopBar(title: '课程与学期'),
      body: ListView(
        // Keeps the last row clear of the floating bottom bar / system inset.
        padding: EdgeInsets.only(
          bottom: MediaQuery.paddingOf(context).bottom + 16,
        ),
        children: [
          AppSegmentedColumn(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            children: [
              ListTile(
                leading: const AppIconTile(icon: Icons.calendar_view_month),
                title: const Text('学期管理'),
                subtitle: Text(semester == null
                    ? '创建学期与节次模板'
                    : '${semester.name} · ${semester.totalWeeks} 周'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/semesters'),
              ),
              ListTile(
                leading: const AppIconTile(icon: Icons.school_outlined),
                title: const Text('课程管理'),
                subtitle: Text(semester == null
                    ? '维护课程与每周上课安排'
                    : '本学期 $courseCount 门课程'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/courses'),
              ),
              ListTile(
                leading: const AppIconTile(icon: Icons.event_repeat),
                title: const Text('周期安排'),
                subtitle: const Text('自定义重复日程（非课程）'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/schedules'),
              ),
              ListTile(
                leading: const AppIconTile(icon: Icons.upload_file),
                title: const Text('导入课程'),
                subtitle: const Text('本地 CSV 导入'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/import'),
              ),
              ListTile(
                leading: const AppIconTile(icon: Icons.travel_explore),
                title: const Text('从教务系统导入'),
                subtitle: const Text('AI 解析 / 网页提取'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/settings/edu-import'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
