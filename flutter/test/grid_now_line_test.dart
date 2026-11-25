import 'dart:async';

import 'package:course_planner/app/theme.dart';
import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/data/local/sync_store.dart';
import 'package:course_planner/domain/entities.dart';
import 'package:course_planner/presentation/calendar/grid_view.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

import 'helpers/memory_prefs.dart';

/// The 课表 grid's orange 「现在」 line must follow the clock provider, not a
/// `now` snapshot taken when the page was built: every sync re-reads the server
/// offset and re-emits, and the line has to jump to the new minute.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('grid now line redraws whenever the clock re-emits', (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++) tz.TZDateTime(ut.location, 2026, 9, 7 + i),
    ];

    final snapshot = EntitiesSnapshot(
      rows: [
        EntityRow(
          entityType: EntityTypes.calendar,
          entityId: 'cal1',
          revision: 1,
          payload: {
            'id': 'cal1',
            'name': '2026秋',
            'firstDay': '2026-09-07',
            'totalWeeks': 16,
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.period,
          entityId: 'p1',
          revision: 1,
          payload: {
            'id': 'p1',
            'calendarId': 'cal1',
            'periodNo': 1,
            'startLocal': '08:00',
            'endLocal': '08:45',
            'revision': 1,
          },
        ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    // Stands in for serverNowProvider: a sync bumps clockRevisionProvider and
    // the stream emits a fresh estimate.
    final clock = StreamController<DateTime>();
    addTearDown(clock.close);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          serverNowProvider.overrideWith((ref) => clock.stream),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: GridViewContent(
                userTime: ut,
                days: days,
                events: const [],
                snapshot: snapshot,
                // Deliberately stale: the line must not use this snapshot.
                nowUtc: DateTime.utc(2026, 9, 7, 0, 0),
                onCommitMove: (e, s, en) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    clock.add(DateTime.utc(2026, 9, 7, 0, 30)); // Mon 08:30 local
    await tester.pump();
    await tester.pump();
    expect(find.text('现在 08:30'), findsOneWidget);

    // The rule itself must be a full-width, 2 dp line — not a zero-height
    // remnant (a ColoredBox inside a tight vertical Padding once collapsed to
    // 0 height, leaving only the label).
    final rule = find.byWidgetPredicate(
        (w) => w is ColoredBox && w.color == AppTheme.nowLineColor);
    expect(rule, findsOneWidget);
    final ruleSize = tester.getSize(rule);
    expect(ruleSize.height, 2);
    expect(ruleSize.width, greaterThan(200),
        reason: 'the rule must span all seven day columns');

    clock.add(DateTime.utc(2026, 9, 7, 1, 15)); // Mon 09:15 local
    await tester.pump();
    await tester.pump();

    expect(find.text('现在 08:30'), findsNothing, reason: 'stale time must be replaced');
    expect(find.text('现在 09:15'), findsOneWidget, reason: 'sync must redraw the line');
    expect(tester.takeException(), isNull);
  });

  testWidgets('grid draws no now line for a week that does not contain today',
      (tester) async {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final days = <tz.TZDateTime>[
      for (var i = 0; i < 7; i++) tz.TZDateTime(ut.location, 2026, 9, 14 + i),
    ];
    final snapshot = EntitiesSnapshot(
      rows: [
        EntityRow(
          entityType: EntityTypes.calendar,
          entityId: 'cal1',
          revision: 1,
          payload: {
            'id': 'cal1',
            'name': '2026秋',
            'firstDay': '2026-09-07',
            'totalWeeks': 16,
            'revision': 1,
          },
        ),
        EntityRow(
          entityType: EntityTypes.period,
          entityId: 'p1',
          revision: 1,
          payload: {
            'id': 'p1',
            'calendarId': 'cal1',
            'periodNo': 1,
            'startLocal': '08:00',
            'endLocal': '08:45',
            'revision': 1,
          },
        ),
      ],
      pendingOps: const [],
      conflicts: const [],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          serverNowProvider
              .overrideWith((ref) => Stream.value(DateTime.utc(2026, 9, 7, 0, 30))),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: GridViewContent(
                userTime: ut,
                days: days,
                events: const [],
                snapshot: snapshot,
                nowUtc: DateTime.utc(2026, 9, 7, 0, 30),
                onCommitMove: (e, s, en) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('现在'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
