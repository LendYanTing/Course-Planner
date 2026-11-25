import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/presentation/calendar/week_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// The week header must say how far the shown week is from this one, e.g.
/// 「第3周 · 1 周前」 / 「第3周 · 本周」 / 「第4周 · 1 周后」.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final ut = UserTime.tryCreate('Asia/Shanghai')!;

  group('weekSubtitle', () {
    test('appends the distance from this week after the semester week', () {
      expect(weekSubtitle(semesterWeek: 3, weeksFromThisWeek: 0), '第3周 · 本周');
      expect(weekSubtitle(semesterWeek: 3, weeksFromThisWeek: -1), '第3周 · 1 周前');
      expect(weekSubtitle(semesterWeek: 2, weeksFromThisWeek: -4), '第2周 · 4 周前');
      expect(weekSubtitle(semesterWeek: 5, weeksFromThisWeek: 1), '第5周 · 1 周后');
      expect(weekSubtitle(semesterWeek: 5, weeksFromThisWeek: 3), '第5周 · 3 周后');
    });

    test('still reports the distance outside every semester', () {
      expect(weekSubtitle(semesterWeek: null, weeksFromThisWeek: 2), '不在本学期 · 2 周后');
      expect(weekSubtitle(semesterWeek: null, weeksFromThisWeek: -1), '不在本学期 · 1 周前');
    });

    test('omits the distance while "now" is unknown', () {
      expect(weekSubtitle(semesterWeek: 7, weeksFromThisWeek: null), '第7周');
      expect(weekSubtitle(semesterWeek: null, weeksFromThisWeek: null), '不在本学期');
    });
  });

  group('weeksFromThisWeek', () {
    test('counts whole weeks between local Mondays', () {
      final wednesday = ut.fromLocalParts(2026, 11, 25, 10, 0);
      final thisMonday = mondayOf(ut, wednesday);

      expect(weeksFromThisWeek(ut, thisMonday, wednesday), 0);
      expect(weeksFromThisWeek(ut, ut.addLocalDays(thisMonday, 7), wednesday), 1);
      expect(weeksFromThisWeek(ut, ut.addLocalDays(thisMonday, -7), wednesday), -1);
      expect(weeksFromThisWeek(ut, ut.addLocalDays(thisMonday, -28), wednesday), -4);
    });

    test('a Sunday belongs to the week of the Monday before it', () {
      final sunday = ut.fromLocalParts(2026, 11, 29, 23, 30);
      final sundayMonday = mondayOf(ut, sunday);
      expect(weeksFromThisWeek(ut, sundayMonday, sunday), 0);
      expect(weeksFromThisWeek(ut, ut.addLocalDays(sundayMonday, 7), sunday), 1);
    });

    test('is null while the server clock has not answered', () {
      expect(weeksFromThisWeek(ut, mondayOf(ut, ut.fromLocalParts(2026, 11, 25, 9, 0)), null), isNull);
    });
  });
}
