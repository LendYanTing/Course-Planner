import 'package:course_planner/core/config/app_info.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/domain/calendar.dart';
import 'package:course_planner/presentation/calendar/month_page.dart';
import 'package:course_planner/presentation/calendar/week_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('semesterWeekFor', () {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    AcademicCalendar cal(String firstDay, int weeks) => AcademicCalendar(
          id: 'cal-$firstDay',
          name: 'test',
          firstDay: firstDay,
          totalWeeks: weeks,
          revision: 1,
        );

    DateTime monday(int y, int m, int d) => ut.fromLocalParts(y, m, d, 0, 0);

    test('counts weeks from the semester first day', () {
      final cals = [cal('2026-09-07', 16)];
      expect(semesterWeekFor(cals, ut, monday(2026, 9, 7))!.week, 1);
      expect(semesterWeekFor(cals, ut, monday(2026, 9, 14))!.week, 2);
      expect(semesterWeekFor(cals, ut, monday(2026, 12, 21))!.week, 16);
    });

    test('returns null outside the semester', () {
      final cals = [cal('2026-09-07', 16)];
      // The week before week 1.
      expect(semesterWeekFor(cals, ut, monday(2026, 8, 31)), isNull);
      // The week after the last week (16 weeks end 2026-12-27).
      expect(semesterWeekFor(cals, ut, monday(2027, 1, 4)), isNull);
    });

    test('picks the semester that contains the week when several exist', () {
      final cals = [cal('2026-02-23', 16), cal('2026-09-07', 16)];
      expect(semesterWeekFor(cals, ut, monday(2026, 3, 2))!.week, 2);
      expect(semesterWeekFor(cals, ut, monday(2026, 9, 21))!.week, 3);
      // Between the two semesters.
      expect(semesterWeekFor(cals, ut, monday(2026, 7, 6)), isNull);
    });

    test('no semesters at all is simply "not in a semester"', () {
      expect(semesterWeekFor(const [], ut, monday(2026, 9, 7)), isNull);
    });
  });

  group('weekGutterLabel', () {
    test('single month', () {
      expect(
        weekGutterLabel([DateTime(2026, 9, 7), DateTime(2026, 9, 13)]),
        '9月',
      );
    });

    test('week spanning two months names both', () {
      expect(
        weekGutterLabel([DateTime(2026, 8, 31), DateTime(2026, 9, 6)]),
        '8/9月',
      );
    });

    test('empty is blank', () {
      expect(weekGutterLabel(const []), '');
    });
  });

  group('compareVersions', () {
    test('equal versions', () {
      expect(compareVersions('0.2.3', '0.2.3'), 0);
      expect(compareVersions('v0.2.3', '0.2.3'), 0);
      expect(compareVersions('0.2.3+5', '0.2.3'), 0, reason: 'build metadata is ignored');
    });

    test('newer release tags compare greater', () {
      expect(compareVersions('v0.2.3', '0.2.2'), greaterThan(0));
      expect(compareVersions('v0.3.0', '0.2.9'), greaterThan(0));
      expect(compareVersions('v1.0.0', '0.9.9'), greaterThan(0));
    });

    test('older release tags compare lower', () {
      expect(compareVersions('v0.2.1', '0.2.2'), lessThan(0));
      expect(compareVersions('0.1.9', '0.2.0'), lessThan(0));
    });

    test('shorter versions are padded with zeros', () {
      expect(compareVersions('0.2', '0.2.0'), 0);
      expect(compareVersions('1', '0.9.9'), greaterThan(0));
    });

    test('the app version is reported as up to date against its own tag', () {
      expect(compareVersions('v${AppInfo.version}', AppInfo.version), 0);
    });
  });
}
