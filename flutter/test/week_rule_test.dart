import 'package:course_planner/core/util/week_text.dart';
import 'package:course_planner/domain/week_rule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WeekRule', () {
    test('parses full-range to empty-ish semantics', () {
      final r = WeekRule([WeekSegment(start: 1, end: 60, parity: WeekParity.all)]);
      expect(r.isEveryWeek, isTrue);
      expect(r.weeks(16), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16]);
    });

    test('parity filtering odd/even', () {
      final r = WeekRule([
        WeekSegment(start: 1, end: 5, parity: WeekParity.odd),
        WeekSegment(start: 6, end: 10, parity: WeekParity.even),
      ]);
      expect(r.weeks(10), [1, 3, 5, 6, 8, 10]);
      expect(r.matchesWeek(4), isFalse);
      expect(r.matchesWeek(6), isTrue);
    });

    test('describe produces compact Chinese text', () {
      final r = WeekRule([
        WeekSegment(start: 1, end: 5, parity: WeekParity.all),
        WeekSegment(start: 7, end: 11, parity: WeekParity.odd),
        WeekSegment(start: 12, end: 16, parity: WeekParity.even),
      ]);
      expect(r.describe(), '1-5、7-11单、12-16双');
    });

    test('json round trip', () {
      final r = WeekRule([WeekSegment(start: 2, end: 8, parity: WeekParity.even)]);
      expect(WeekRule.fromJson(r.toJson()).describe(), '2-8双');
      // wrapped segments object accepted like the server parser
      expect(WeekRule.fromJson({'segments': r.toJson()}).segments, hasLength(1));
    });
  });

  group('parseWeekRuleText', () {
    test('mirrors csv-import syntax', () {
      final r = parseWeekRuleText('1-5、7-11单、12-16双')!;
      expect(r.describe(), '1-5、7-11单、12-16双');
    });

    test('supports 、 ， , and space separators', () {
      expect(parseWeekRuleText('2，5，8')!.weeks(16), [2, 5, 8]);
      expect(parseWeekRuleText('1-3 5 7')!.weeks(16), [1, 2, 3, 5, 7]);
    });

    test('rejects garbage', () {
      expect(parseWeekRuleText('abc'), isNull);
      expect(parseWeekRuleText('5-1'), isNull);
      expect(parseWeekRuleText(''), isNull);
    });
  });
}
