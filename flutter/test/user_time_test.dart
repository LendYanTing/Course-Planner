import 'package:course_planner/core/time/user_time.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UserTime (Asia/Shanghai, fixed, no DST)', () {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;

    test('localFromUtc converts UTC to local wall clock', () {
      final local = ut.localFromUtc(DateTime.utc(2026, 9, 7, 0, 0));
      expect(local.year, 2026);
      expect(local.month, 9);
      expect(local.day, 7);
      expect(local.hour, 8);
      expect(local.minute, 0);
    });

    test('fromLocalParts builds the correct UTC instant', () {
      final local = ut.fromLocalParts(2026, 9, 7, 8, 0);
      // 08:00 Asia/Shanghai == 00:00 UTC the same day (+08:00).
      expect(local.toUtc(), DateTime.utc(2026, 9, 7, 0, 0));
      expect(local.isUtc, isFalse);
    });

    test('minuteOfDayUtc is local-minute based', () {
      // 2026-09-06T16:30Z == 2026-09-07 00:30 Asia/Shanghai
      expect(ut.minuteOfDayUtc(DateTime.utc(2026, 9, 6, 16, 30)), 30);
      // 2026-09-07T00:30Z == 08:30 local
      expect(ut.minuteOfDayUtc(DateTime.utc(2026, 9, 7, 0, 30)), 8 * 60 + 30);
    });

    test('sameLocalDay rejects cross-midnight windows', () {
      final start = DateTime.utc(2026, 9, 7, 15, 0); // 23:00 local 9/7
      final nextDay = DateTime.utc(2026, 9, 7, 16, 0); // 00:00 local 9/8
      expect(ut.sameLocalDay(start, nextDay), isFalse);
      final sameDayEnd = DateTime.utc(2026, 9, 7, 15, 59); // 23:59 local 9/7
      expect(ut.sameLocalDay(start, sameDayEnd), isTrue);
    });

    test('localDatesBetween walks calendar days', () {
      final a = ut.parseLocalDate('2026-09-07')!;
      final b = ut.parseLocalDate('2026-09-10')!;
      final dates = ut.localDatesBetween(a, b).toList();
      expect(dates.length, 3);
      expect(ut.isoWeekday(dates.first), 1); // Monday
      expect(ut.localDateString(dates.last), '2026-09-09');
    });
  });

  group('UserTime with DST (Europe/Berlin)', () {
    final ut = UserTime.tryCreate('Europe/Berlin')!;

    test('local date string is stable across DST boundary', () {
      // 2026-03-29 02:00 Europe/Berlin does not exist (spring forward).
      final before = ut.localFromUtc(DateTime.utc(2026, 3, 28, 23, 30));
      expect(ut.localDateString(before), '2026-03-29'); // 00:30 CET
      final after = ut.localFromUtc(DateTime.utc(2026, 3, 29, 0, 30));
      expect(ut.localDateString(after), '2026-03-29'); // 02:30 CEST
      expect(ut.sameLocalDay(before, after), isTrue);
    });
  });
}
