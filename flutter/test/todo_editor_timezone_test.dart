import 'package:course_planner/core/time/user_time.dart';
import 'package:course_planner/presentation/todo/todo_page.dart';
import 'package:course_planner/state/providers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;

/// Issue #2: the editor must interpret and echo a chosen wall-clock in the
/// fixed user timezone, never the device timezone. The `timezone` package sets
/// `tz.local` to `Etc/UTC` (see lib/core/time/tz_init.dart), and `toLocal()` on
/// a UTC `TZDateTime` is a no-op, so a leaked `TZDateTime` renders UTC
/// wall-clock (09:00 +08 shows as 01:00).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('tz.local is Etc/UTC once the tz database is loaded', () {
    // Creating a UserTime loads the database, which sets tz.local = Etc/UTC.
    UserTime.tryCreate('Asia/Shanghai');
    expect(tz.local.name, 'Etc/UTC');
  });

  test('utcFromLocalParts returns a plain UTC DateTime (no TZDateTime leak)', () {
    final ut = UserTime.tryCreate('Asia/Shanghai')!;
    final instant = ut.utcFromLocalParts(2026, 10, 16, 9, 0);
    expect(instant.isUtc, isTrue);
    expect(instant.runtimeType, DateTime);
    // 09:00 Asia/Shanghai (+08) == 01:00 UTC the same day.
    expect(instant.hour, 1);
    // And the user-tz wall-clock is recoverable for display.
    expect(ut.localFromUtc(instant).hour, 9);
  });

  testWidgets('new todo: chosen 09:00 is echoed as 09:00 in the editor',
      (tester) async {
    final userTime = UserTime.tryCreate('Asia/Shanghai')!;
    await tester.pumpWidget(ProviderScope(
      overrides: [userTimeProvider.overrideWithValue(userTime)],
      child: MaterialApp(
        // 24-hour clock so the picker reads "09:00" literally rather than
        // 12-hour with an AM/PM selector. The builder sits above the Navigator
        // so the dialog route inherits it too.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        ),
        home: const Scaffold(body: TodoEditorSheet(tags: [], categories: [])),
      ),
    ));

    // Default type is one-off, so the time point reads as a reminder.
    expect(find.text('设置提醒时间'), findsOneWidget);
    await tester.tap(find.text('设置提醒时间'));
    await tester.pumpAndSettle();

    // Date picker: keep the default day.
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // Time picker: type 09:00 through the keyboard entry mode.
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.descendant(
      of: find.byType(TimePickerDialog),
      matching: find.byType(TextField),
    );
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), '09');
    await tester.enterText(fields.at(1), '00');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();

    // The bug rendered this as 01:00 (UTC wall-clock).
    expect(find.textContaining('09:00'), findsOneWidget);
    expect(find.textContaining('01:00'), findsNothing);
  });
}
