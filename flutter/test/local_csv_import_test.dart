import 'package:course_planner/data/db/app_database.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/data/local/view_models.dart';
import 'package:course_planner/data/repo/entity_repo.dart';
import 'package:course_planner/domain/calendar.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/domain/local_csv_import.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/host_sqlite.dart';

AcademicCalendar _calendar({int totalWeeks = 16}) => AcademicCalendar(
  id: 'cal1',
  name: '2026 秋',
  firstDay: '2026-09-07',
  totalWeeks: totalWeeks,
  revision: 0,
);

List<PeriodTemplate> _periods(int count) => [
  for (var i = 1; i <= count; i++)
    PeriodTemplate(
      id: 'p$i',
      calendarId: 'cal1',
      periodNo: i,
      startLocal: '08:00',
      endLocal: '08:45',
      revision: 0,
    ),
];

Future<EntitiesSnapshot> _snapshot(SyncStore store) async => EntitiesSnapshot(
  rows: await store.allEntities(),
  pendingOps: await store.pendingOps(),
  conflicts: const [],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  configureHostSqlite();

  group('parseAndValidate', () {
    test('parses a standard 7-column CSV', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
            '高等数学,1,1,2,小明,逸夫楼201,1-16\n'
            '线性代数,2,3,4,小红,理工楼110,1-16\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(4),
      );

      expect(result.errors, isEmpty);
      expect(result.preview, isNotNull);
      expect(result.preview!.courses, hasLength(2));
      final first = result.preview!.courses.first;
      expect(first.name, '高等数学');
      expect(first.weekday, 1);
      expect(first.periodStart, 1);
      expect(first.periodEnd, 2);
      expect(first.teacher, '小明');
      expect(first.location, '逸夫楼201');
      expect(first.weekRuleText, '1-16');
      expect(first.line, 2);
      expect(result.maxPeriod, 4);
      expect(result.needsPeriodTemplates, isFalse);
    });

    test('supports Chinese headers, Chinese weekdays and parity rules', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名,星期,开始节数,结束节数,老师,地点,周次\n'
            '高等数学,周一,1,2,小明,逸夫楼201,1-5、7-11单、12-16双\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(4),
      );

      expect(result.errors, isEmpty);
      final course = result.preview!.courses.single;
      expect(course.name, '高等数学');
      expect(course.weekday, 1);
      expect(course.weekRuleText, '1-5、7-11单、12-16双');
    });

    test('merges same name/teacher/location rows into one course', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
            '高等数学,1,1,2,小明,逸夫楼201,1-16\n'
            '高等数学,3,3,4,小明,逸夫楼201,1-16\n'
            '高等数学,5,5,6,小明,逸夫楼201,1-16\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(6),
      );

      expect(result.errors, isEmpty);
      expect(result.preview!.courses, hasLength(1));
      expect(result.preview!.courses.single.name, '高等数学');
    });

    test('collects every row-level error and returns no preview', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
            '高等数学,9,1,2,,,1-16\n'
            '线性代数,2,4,3,,,1-16\n'
            '大学英语,3,1,2,,,1-20\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(6),
      );

      expect(result.preview, isNull);
      bool has(int line, String field, String code) => result.errors.any(
        (e) => e.line == line && e.field == field && e.code == code,
      );
      expect(has(2, '星期', 'BAD_WEEKDAY'), isTrue);
      expect(has(3, '节次', 'BAD_PERIOD_RANGE'), isTrue);
      expect(has(4, '周数', 'WEEK_OUT_OF_RANGE'), isTrue);
    });

    test('flags missing period templates', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
            '高等数学,1,9,10,小明,逸夫楼201,1-16\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(4),
      );

      expect(result.errors, isEmpty);
      expect(result.maxPeriod, 10);
      expect(result.needsPeriodTemplates, isTrue);
    });

    test(
      'tolerates BOM, full-width commas, quotes, blank and comment lines',
      () {
        final result = LocalCsvImporter.parseAndValidate(
          csv:
              '\uFEFF课程名称，星期，开始节数，结束节数，老师，地点，周数\r\n'
              '\r\n'
              '# 这是注释行\r\n'
              '高等数学，周一，1，2，小明，"逸夫楼,201"，1-16\r\n',
          calendarId: 'cal1',
          calendar: _calendar(),
          periods: _periods(4),
        );

        expect(result.errors, isEmpty);
        final course = result.preview!.courses.single;
        expect(course.name, '高等数学');
        expect(course.weekday, 1);
        expect(course.location, '逸夫楼,201');
      },
    );

    test('full-width commas split unquoted fields', () {
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称，星期，开始节数，结束节数，老师，地点，周数\n'
            '高等数学，周三，1，2，小明，逸夫楼201，1-16\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: _periods(4),
      );

      expect(result.errors, isEmpty);
      expect(result.preview!.courses.single.weekday, 3);
    });
  });

  group('commit', () {
    late AppDatabase db;
    late SyncStore store;
    late EntityRepo repo;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = SyncStore(db);
      repo = EntityRepo(db, store);
    });

    tearDown(() async {
      await db.close();
    });

    test('writes one course and one meeting per merged row', () async {
      final periods = _periods(6);
      final result = LocalCsvImporter.parseAndValidate(
        csv:
            '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
            '高等数学,1,1,2,小明,逸夫楼201,1-16\n'
            '高等数学,3,3,4,小明,逸夫楼201,1-16\n'
            '高等数学,5,5,6,小明,逸夫楼201,1-16\n',
        calendarId: 'cal1',
        calendar: _calendar(),
        periods: periods,
      );

      final written = await LocalCsvImporter.commit(
        repo: repo,
        preview: result.preview!,
        calendarId: 'cal1',
        periods: periods,
      );
      expect(written, 1);

      final snap = await _snapshot(store);
      final courses = liveCourses(snap, calendarId: 'cal1');
      expect(courses, hasLength(1));
      expect(courses.single.value.name, '高等数学');
      expect(courses.single.value.teacher, '小明');
      expect(courses.single.value.location, '逸夫楼201');

      final meetings = liveMeetings(snap);
      expect(meetings, hasLength(3));
      expect(meetings.map((m) => m.value.weekday).toSet(), {1, 3, 5});
      for (final m in meetings) {
        expect(m.value.courseId, courses.single.value.id);
        expect(m.value.weekRule.segments, hasLength(1));
      }

      // No extra entities were created besides the one course and meetings.
      final rows = await store.allEntities();
      expect(
        rows.where((r) => r.entityType == EntityTypes.course),
        hasLength(1),
      );
      expect(
        rows.where((r) => r.entityType == EntityTypes.courseMeeting),
        hasLength(3),
      );
    });

    test(
      'fills missing period templates when autoCreatePeriods is true',
      () async {
        final periods = _periods(4);
        final result = LocalCsvImporter.parseAndValidate(
          csv:
              '课程名称,星期,开始节数,结束节数,老师,地点,周数\n'
              '高等数学,1,9,10,小明,逸夫楼201,1-16\n',
          calendarId: 'cal1',
          calendar: _calendar(),
          periods: periods,
        );

        expect(result.needsPeriodTemplates, isTrue);

        // The four existing templates live in the mirror, exactly like the
        // settings page passes them from the snapshot.
        for (final p in periods) {
          await repo.localCreate(
            entityType: EntityTypes.period,
            snapshot: {
              'calendarId': p.calendarId,
              'periodNo': p.periodNo,
              'startLocal': p.startLocal,
              'endLocal': p.endLocal,
            },
          );
        }

        final written = await LocalCsvImporter.commit(
          repo: repo,
          preview: result.preview!,
          calendarId: 'cal1',
          periods: periods,
        );
        expect(written, 1);

        final snap = await _snapshot(store);
        final live = livePeriods(snap, calendarId: 'cal1');
        expect(live.length, greaterThanOrEqualTo(10));
        final p5 = live.firstWhere((p) => p.value.periodNo == 5).value;
        // 08:00 + 4 * (45 + 10) minutes = 11:40, lesson ends 12:25.
        expect(p5.startLocal, '11:40');
        expect(p5.endLocal, '12:25');

        final byNo = {for (final p in live) p.value.periodNo: p.value};
        expect(byNo.keys, contains(10));
        expect(byNo[1]!.startLocal, '08:00');
        expect(byNo[1]!.endLocal, '08:45');
      },
    );
  });
}
