import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/domain/calendar_event.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/event_projection.dart';
import 'package:course_planner/presentation/calendar/month_page.dart';
import 'package:flutter_test/flutter_test.dart';

/// Regression: the month grid bucketed events under unpadded keys
/// (`2026-9-10`) while the day cells looked them up with the padded
/// `UserTime.localDateString` (`2026-09-10`). No day ever matched, so every
/// month rendered empty and the day sheet always said "0 项".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('events bucket under padded local-date keys (incl. single-digit month)', () {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;

    UiEvent ev(String title, DateTime startUtc) => UiEvent(
          id: 'x:$title',
          type: EventType.course,
          title: title,
          startUtc: startUtc,
          endUtc: startUtc.add(const Duration(minutes: 45)),
          sourceType: EntityTypes.courseMeeting,
          sourceId: 'm1',
          conflict: ConflictState.none,
        );

    // Sep 10 2026 09:40 Asia/Shanghai (+08) == 01:40Z. Single-digit month.
    final byDay = groupEventsByLocalDay(
      [ev('生物化学', DateTime.utc(2026, 9, 10, 1, 40))],
      ut,
    );

    expect(byDay.keys.single, '2026-09-10');
    expect(byDay['2026-09-10'], hasLength(1));
    // The unpadded form must NOT be what keys the map.
    expect(byDay.containsKey('2026-9-10'), isFalse);
    // And the key equals what the day cells look up.
    expect(byDay.keys.single, ut.localDateString(ut.fromLocalParts(2026, 9, 10, 0, 0)));
  });
}
