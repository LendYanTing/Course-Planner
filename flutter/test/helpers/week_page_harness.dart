import 'package:course_planner/data/local/entities_snapshot.dart';
import 'package:course_planner/presentation/calendar/week_page.dart';
import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:course_planner/state/sync_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'memory_prefs.dart';

/// Signed-in session with a fixed timezone (no providers touched).
class FakeSession extends SessionController {
  @override
  SessionState build() => const SessionState(
        phase: AuthPhase.signedIn,
        profile: SessionProfile(
          userId: 'u1',
          username: 'webdev',
          timezone: 'Asia/Shanghai',
        ),
      );
}

/// Pumps [WeekPage] against a fixed [snapshot]. "Now" is the real clock, so the
/// current-time line renders and the page anchors on the week containing today.
Future<void> pumpWeekPage(
  WidgetTester tester,
  EntitiesSnapshot snapshot,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        prefStoreProvider.overrideWithValue(MemoryPrefs()),
        snapshotProvider.overrideWith((ref) => Stream.value(snapshot)),
        sessionControllerProvider.overrideWith(FakeSession.new),
        serverNowProvider
            .overrideWith((ref) => Stream.value(DateTime.now().toUtc())),
      ],
      child: const MaterialApp(home: WeekPage()),
    ),
  );
  await tester.pump();
  await tester.pump();
}
