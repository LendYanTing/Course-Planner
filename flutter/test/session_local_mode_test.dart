import 'package:course_planner/state/app_services.dart';
import 'package:course_planner/state/prefs.dart';
import 'package:course_planner/state/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers/memory_prefs.dart';

ProviderContainer _container(MemoryPrefs prefs) {
  final container = ProviderContainer(
    overrides: [prefStoreProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('SyncEnabledController', () {
    test('defaults to off', () {
      final container = _container(MemoryPrefs());
      expect(container.read(syncEnabledProvider), isFalse);
    });

    test('set(true) flips the state and persists it', () async {
      final prefs = MemoryPrefs();
      final container = _container(prefs);
      await container.read(syncEnabledProvider.notifier).set(true);
      expect(container.read(syncEnabledProvider), isTrue);
      expect(await prefs.read('sync_enabled'), 'true');
    });

    test('a fresh container restores the persisted flag', () async {
      final prefs = MemoryPrefs({'sync_enabled': 'true'});
      final container = _container(prefs);
      expect(container.read(syncEnabledProvider), isFalse);
      await pumpEventQueue();
      expect(container.read(syncEnabledProvider), isTrue);
    });
  });

  group('LocalTimezoneController', () {
    test('defaults to Asia/Shanghai', () {
      final container = _container(MemoryPrefs());
      expect(container.read(localTimezoneProvider), 'Asia/Shanghai');
    });

    test('set() flips the state and persists it', () async {
      final prefs = MemoryPrefs();
      final container = _container(prefs);
      await container.read(localTimezoneProvider.notifier).set('Europe/Berlin');
      expect(container.read(localTimezoneProvider), 'Europe/Berlin');
      expect(await prefs.read('local_timezone'), 'Europe/Berlin');
    });

    test('a fresh container restores the persisted zone', () async {
      final prefs = MemoryPrefs({'local_timezone': 'America/New_York'});
      final container = _container(prefs);
      // Build the notifier first (that is what kicks off the async restore),
      // then let the restore land.
      expect(container.read(localTimezoneProvider), 'Asia/Shanghai');
      await pumpEventQueue();
      expect(container.read(localTimezoneProvider), 'America/New_York');
    });
  });

  group('SessionState.isLocalMode', () {
    const localProfile = SessionProfile(
      userId: SessionState.localUserId,
      username: '本地用户',
      timezone: 'Asia/Shanghai',
    );
    const cloudProfile = SessionProfile(
      userId: 'u1',
      username: 'webdev',
      timezone: 'Asia/Shanghai',
    );

    test('only a signed-in local profile is local mode', () {
      expect(
        const SessionState(phase: AuthPhase.signedIn, profile: localProfile)
            .isLocalMode,
        isTrue,
      );
      expect(
        const SessionState(phase: AuthPhase.signedIn, profile: cloudProfile)
            .isLocalMode,
        isFalse,
      );
      expect(
        const SessionState(phase: AuthPhase.signedOut, profile: localProfile)
            .isLocalMode,
        isFalse,
      );
      expect(const SessionState().isLocalMode, isFalse);
    });
  });
}
