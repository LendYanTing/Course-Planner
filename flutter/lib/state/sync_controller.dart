import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/util/streams.dart';
import '../data/local/entities_snapshot.dart';
import '../data/local/sync_store.dart';
import '../sync/clock.dart';
import '../sync/sync_engine.dart';
import 'app_services.dart';
import 'providers.dart';
import 'session.dart';

/// The server clock singleton.
final serverClockProvider = Provider<ServerClock>(
  (ref) => ref.watch(servicesProvider).clock,
);

/// Estimated server "now", refreshed once per minute (docs/datetime.md §8-9).
/// Only the current-time indicator watches this provider — calendar data has
/// its own provider, so a tick never rebuilds event grids.
final serverNowProvider = StreamProvider<DateTime>((ref) async* {
  final clock = ref.watch(serverClockProvider);
  while (true) {
    yield clock.estimateNow().toUtc();
    await Future<void>.delayed(const Duration(seconds: 60));
  }
});

/// Reactive mirror snapshot: entities + pending ops + conflicts combined from
/// the three drift watch streams. UI derives everything from this provider.
final snapshotProvider = StreamProvider<EntitiesSnapshot>((ref) async* {
  final store = ref.watch(syncStoreProvider);
  yield* combineLatest3(
    store.watchAll(),
    store.watchPendingOps(),
    store.watchConflicts(),
  ).map((tuple) {
    final snap = EntitiesSnapshot(
      rows: tuple.$1,
      pendingOps: tuple.$2,
      conflicts: tuple.$3,
    );
    // ignore: avoid_print
    debugPrint('[snapshot] cam rows=${snap.rows.length} pending=${snap.pendingOps.length}');
    return snap;
  });
});

/// Engine coordination state shown in the UI.
class SyncUiState {
  const SyncUiState({
    this.syncing = false,
    this.lastSyncAt,
    this.lastError,
    this.hasRunOnce = false,
  });

  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;
  final bool hasRunOnce;

  SyncUiState copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? lastError,
    bool? hasRunOnce,
  }) =>
      SyncUiState(
        syncing: syncing ?? this.syncing,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastError: lastError ?? this.lastError,
        hasRunOnce: hasRunOnce ?? this.hasRunOnce,
      );
}

/// Coordinates when the engine runs: debounced push after local mutations,
/// periodic catch-up, manual sync, hard refresh, conflict resolution.
class SyncCoordinatorController extends Notifier<SyncUiState> {
  Timer? _debounce;
  Timer? _periodic;
  bool _running = false;

  @override
  SyncUiState build() {
    return const SyncUiState();
  }

  /// Debounced push trigger — called by the app root when the snapshot shows
  /// newly queued operations (kept out of `build()`: a Notifier must not
  /// subscribe to streams synchronously).
  void schedulePush() {
    if (ref.read(sessionControllerProvider).phase != AuthPhase.signedIn) return;
    _schedule(seconds: 2);
  }

  void startPeriodicSync() {
    _periodic ??= Timer.periodic(const Duration(seconds: 60), (_) {
      if (ref.read(sessionControllerProvider).phase != AuthPhase.signedIn) return;
      unawaited(syncNow());
    });
  }

  void _schedule({int seconds = 2}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(seconds: seconds), () {
      if (ref.read(sessionControllerProvider).phase == AuthPhase.signedIn) {
        unawaited(syncNow());
      }
    });
  }

  /// Clock sync + initial pull after login/startup.
  Future<void> syncClockAndPull() async {
    debugPrint('[sync] syncClockAndPull start');
    final services = ref.read(servicesProvider);
    try {
      final serverNow = await services.authApi.serverTime();
      final now = DateTime.now().toUtc();
      services.clock.record(serverNow, now);
      final meta = await services.store.meta();
      await services.store.saveMeta((meta ?? const AppMetaSnapshot()).copyWith(
        clockFetchedAt: now,
        clockServerUtc: serverNow,
      ));
      debugPrint('[sync] clock fetched: ${serverNow.toIso8601String()}');
    } on Object catch (e) {
      debugPrint('[sync] clock fetch failed: $e');
      // offline: fall back to the persisted clock observation below
    }
    final meta = await services.store.meta();
    if (!services.clock.synced && meta?.clockServerUtc != null && meta?.clockFetchedAt != null) {
      services.clock.restore(meta!.clockServerUtc!, meta.clockFetchedAt!);
    }
    await syncNow();
    startPeriodicSync();
    debugPrint('[sync] syncClockAndPull done');
  }

  /// Runs one engine cycle if none is currently running.
  Future<SyncCycleResult?> syncNow() async {
    if (_running) return null;
    _running = true;
    state = state.copyWith(syncing: true, lastError: null);
    debugPrint('[sync] syncNow start');
    try {
      final engine = ref.read(servicesProvider).syncEngine;
      final result = await engine.syncOnce();
      debugPrint('[sync] syncNow done: pushed=${result.pushed} pulled=${result.pulled} '
          'conflicts=${result.conflictCount} err=${result.error}');
      state = state.copyWith(
        syncing: false,
        lastSyncAt: DateTime.now().toUtc(),
        lastError: result.error,
        hasRunOnce: true,
      );
      return result;
    } catch (e) {
      // Should not happen (engine catches), but keep the UI unstuck.
      debugPrint('[sync] syncNow threw: $e');
      state = state.copyWith(syncing: false, lastError: '$e', hasRunOnce: true);
      return null;
    } finally {
      _running = false;
    }
  }

  /// Hard refresh: preserve pending ops, wipe + rebuild the mirror, replay
  /// the queue (docs/sync-protocol.md §16).
  Future<void> hardRefresh() async {
    if (_running) return;
    _running = true;
    state = state.copyWith(syncing: true, lastError: null);
    try {
      final engine = ref.read(servicesProvider).syncEngine;
      await engine.hardRefresh();
      state = state.copyWith(syncing: false, lastSyncAt: DateTime.now().toUtc(), hasRunOnce: true);
    } on Object catch (e) {
      state = state.copyWith(syncing: false, lastError: '$e');
    } finally {
      _running = false;
    }
  }

  /// Conflict resolution entry point for the UI.
  Future<void> resolveConflict(ConflictRecord conflict, {required bool keepLocal}) async {
    final engine = ref.read(servicesProvider).syncEngine;
    await engine.resolveConflict(conflict, keepLocal: keepLocal);
    unawaited(syncNow());
  }
}

final syncCoordinatorProvider =
    NotifierProvider<SyncCoordinatorController, SyncUiState>(SyncCoordinatorController.new);
