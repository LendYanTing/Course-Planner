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

/// Readability of the 课表 weekday header and grid in light, dark and wallpaper
/// mode (phase 7, Step 3).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final userTime = UserTime.tryCreate('Asia/Shanghai')!;
  final days = <tz.TZDateTime>[
    for (var i = 0; i < 7; i++)
      tz.TZDateTime(userTime.location, 2026, 9, 7 + i),
  ];

  // 08:00 / 10:00 are morning rows, 14:00 is afternoon: both bands render.
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
      for (final p in [
        (1, '08:00', '08:45'),
        (2, '10:00', '10:45'),
        (3, '14:00', '14:45'),
      ])
        EntityRow(
          entityType: EntityTypes.period,
          entityId: 'p${p.$1}',
          revision: 1,
          payload: {
            'id': 'p${p.$1}',
            'calendarId': 'cal1',
            'periodNo': p.$1,
            'startLocal': p.$2,
            'endLocal': p.$3,
            'revision': 1,
          },
        ),
    ],
    pendingOps: const [],
    conflicts: const [],
  );

  Future<void> pumpGrid(
    WidgetTester tester, {
    required ThemeData theme,
    required bool hasBackground,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          prefStoreProvider.overrideWithValue(MemoryPrefs()),
          serverNowProvider.overrideWith(
            (ref) => Stream.value(DateTime.utc(2026, 9, 8, 0, 30)),
          ),
        ],
        child: MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              width: 900,
              height: 700,
              child: GridViewContent(
                userTime: userTime,
                days: days,
                events: const [],
                snapshot: snapshot,
                nowUtc: null,
                hasBackground: hasBackground,
                onCommitMove: (e, s, en) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The style actually applied to the [Text] whose data is [text].
  TextStyle styleOf(WidgetTester tester, String text) =>
      tester.widget<Text>(find.text(text)).style!;

  int coloredBoxCount(WidgetTester tester, Color color) => tester
      .widgetList(
        find.byWidgetPredicate((w) => w is ColoredBox && w.color == color),
      )
      .length;

  testWidgets('light header uses primary month and high-contrast weekdays', (
    tester,
  ) async {
    final theme = AppTheme.light();
    final scheme = theme.colorScheme;
    await pumpGrid(tester, theme: theme, hasBackground: false);

    expect(
      styleOf(tester, '周一').color,
      scheme.onSurface.withValues(alpha: 0.88),
    );
    expect(
      styleOf(tester, '周日').color,
      scheme.onSurface.withValues(alpha: 0.88),
    );
    expect(styleOf(tester, '周一').fontWeight, FontWeight.w600);
    expect(styleOf(tester, '9月').color, scheme.primary);
    expect(styleOf(tester, '9月').fontWeight, FontWeight.w700);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark grid drops the light pastels and the black45 time labels', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    final scheme = theme.colorScheme;
    await pumpGrid(tester, theme: theme, hasBackground: false);

    expect(
      coloredBoxCount(tester, const Color(0xFFEDF4FF)),
      0,
      reason: 'the light morning tint must not leak into dark mode',
    );
    expect(
      coloredBoxCount(tester, const Color(0xFFFFF2E4)),
      0,
      reason: 'the light afternoon tint must not leak into dark mode',
    );

    // The period gutter reads scheme.onSurfaceVariant instead of black45.
    expect(styleOf(tester, '08:00').color, scheme.onSurfaceVariant);
    expect(styleOf(tester, '08:00').fontSize, 10);
    final black45 = tester
        .widgetList<Text>(find.byType(Text))
        .where((t) => t.style?.color == Colors.black45);
    expect(black45, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('dark mode with a wallpaper keeps translucent tints and header', (
    tester,
  ) async {
    final theme = AppTheme.dark();
    final scheme = theme.colorScheme;
    await pumpGrid(tester, theme: theme, hasBackground: true);

    final am = Color.lerp(
      scheme.surfaceContainerLow,
      scheme.primary,
      0.10,
    )!.withValues(alpha: 0.55);
    final pm = Color.lerp(
      scheme.surfaceContainer,
      scheme.tertiary,
      0.10,
    )!.withValues(alpha: 0.55);
    expect(
      coloredBoxCount(tester, am),
      greaterThan(0),
      reason: 'the morning band goes dark-tonal and translucent',
    );
    expect(
      coloredBoxCount(tester, pm),
      greaterThan(0),
      reason: 'the afternoon band goes dark-tonal and translucent',
    );
    expect(am.a, lessThan(1.0));
    expect(pm.a, lessThan(1.0));

    // The weekday row keeps a half-transparent surface backdrop under it.
    final headerBg = scheme.surfaceContainer.withValues(alpha: 0.78);
    expect(coloredBoxCount(tester, headerBg), 1);

    // The labels themselves stay opaque on top of that backdrop.
    expect(styleOf(tester, '周一').color, isNotNull);
    expect(styleOf(tester, '9月').color, scheme.primary);
    expect(tester.takeException(), isNull);
  });
}
