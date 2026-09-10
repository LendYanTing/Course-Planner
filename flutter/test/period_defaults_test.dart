import 'package:course_planner/domain/calendar.dart';
import 'package:course_planner/presentation/settings/settings_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// Prefilling the "add period" form: the number continues after the highest
/// existing one and the start time follows the previous period's end + 10
/// minutes, so adding 第2节, 第3节… needs no retyping.
void main() {
  PeriodTemplate p(int no, String start, String end) => PeriodTemplate(
        id: 'p$no',
        calendarId: 'cal1',
        periodNo: no,
        startLocal: start,
        endLocal: end,
        revision: 1,
      );

  String hhmm(int minutes) =>
      '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
      '${(minutes % 60).toString().padLeft(2, '0')}';

  test('empty semester falls back to 第1节 08:00 (45 min)', () {
    final d = nextPeriodDefaults(const []);
    expect(d.periodNo, 1);
    expect(hhmm(d.startMinute), '08:00');
    expect(hhmm(d.endMinute), '08:45');
  });

  test('second period starts 10 minutes after the first ends', () {
    // 第1节 08:00–08:45 → 第2节 08:55–09:40
    final d = nextPeriodDefaults([p(1, '08:00', '08:45')]);
    expect(d.periodNo, 2);
    expect(hhmm(d.startMinute), '08:55');
    expect(hhmm(d.endMinute), '09:40');
  });

  test('chains from the latest period, keeping its length', () {
    // 第1节 08:00–08:45, 第2节 08:55–09:40, 第3节 10:00–10:45 → 第4节 10:55–11:40
    final d = nextPeriodDefaults([
      p(1, '08:00', '08:45'),
      p(2, '08:55', '09:40'),
      p(3, '10:00', '10:45'),
    ]);
    expect(d.periodNo, 4);
    expect(hhmm(d.startMinute), '10:55');
    expect(hhmm(d.endMinute), '11:40');
  });

  test('after a single long period the next one keeps that length', () {
    // 第1节 14:00–15:40 (100 min) → 第2节 15:50–17:30
    final d = nextPeriodDefaults([p(1, '14:00', '15:40')]);
    expect(d.periodNo, 2);
    expect(hhmm(d.startMinute), '15:50');
    expect(hhmm(d.endMinute), '17:30');
  });

  test('numbering uses max+1 so deleting a middle period cannot collide', () {
    // 第2节 was deleted: numbering continues at 4, never reusing 3.
    final d = nextPeriodDefaults([p(1, '08:00', '08:45'), p(3, '10:00', '10:45')]);
    expect(d.periodNo, 4);
  });

  test('chains by start time, not by number', () {
    // A re-numbered timetable: the 14:00 entry is numbered 1 but is the last
    // one in the day, so the next period must follow it.
    final d = nextPeriodDefaults([p(5, '08:00', '08:45'), p(1, '14:00', '14:45')]);
    expect(d.periodNo, 6);
    expect(hhmm(d.startMinute), '14:55');
  });

  test('a late last period stays inside the same day', () {
    final d = nextPeriodDefaults([p(1, '23:00', '23:50')]);
    expect(d.startMinute, greaterThan(0));
    expect(d.startMinute, lessThanOrEqualTo(23 * 60 + 54));
    expect(d.endMinute, lessThanOrEqualTo(23 * 60 + 59));
    expect(d.endMinute, greaterThan(d.startMinute));
  });
}
