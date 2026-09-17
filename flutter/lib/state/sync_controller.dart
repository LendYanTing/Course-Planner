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

/// Bumped when the clock needs re-reading right now (e.g. the app came back
/// from the background and the per-minute ticker had been suspended).
class ClockRevisionController extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state = state + 1;
}

final clockRevisionProvider =
    NotifierProvider<ClockRevisionController, int>(ClockRevisionController.new);

/// Estimated server "now", refreshed once per minute (docs/datetime.md §8-9).
/// Only the current-time indicator watches this provider — calendar data has
/// its own provider, so a tick never rebuilds event grids.
///
/// Watching [clockRevisionProvider] restarts the generator, so a bump emits a
/// fresh value immediately instead of waiting out the suspended delay.
final serverNowProvider = StreamProvider<DateTime>((ref) async* {
  ref.watch(clockRevisionProvider);
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
    this.lastErrorDetail,
    this.hasRunOnce = false,
  });

  final bool syncing;
  final DateTime? lastSyncAt;
  final String? lastError;

  /// Verbose report of the last failure, shown by the sync-status dialog.
  final String? lastErrorDetail;
  final bool hasRunOnce;

  SyncUiState copyWith({
    bool? syncing,
    DateTime? lastSyncAt,
    String? lastError,
    String? lastErrorDetail,
    bool? hasRunOnce,
  }) =>
      SyncUiState(
        syncing: syncing ?? this.syncing,
        lastSyncAt: lastSyncAt ?? this.lastSyncAt,
        lastError: lastError ?? this.lastError,
        lastErrorDetail: lastErrorDetail ?? this.lastErrorDetail,
        hasRunOnce: hasRunOnce ?? this.hasRunOnce,
      );
}

/// Coordinates when the engine runs: debounced push after local mutations,
/// periodic catch-up, manual sync, hard refresh, conflict resolution.
class SyncCoordinatorController extends Notifier<SyncUiState> {
  Timer? _debounce;
  Timer? _periodic;
  bool _running = false;

  /// When the clock offset was last read from the server.
  DateTime? _clockFetchedAt;

  /// Consecutive timeouts, so the automatic network reset cannot loop.
  int _timeouts = 0;

  /// Consecutive offline cycles, for the same reason.
  int _transportFailures = 0;

  /// A hung request must not leave the UI spinning for ever.
  static const _cycleTimeout = Duration(seconds: 45);

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

  /// Reads `/meta/time` (or falls back to the persisted observation). Kept
  /// separate so returning from the background can refresh the clock without
  /// running a whole sync cycle.
  Future<void> syncClock() async {
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
      final meta = await services.store.meta();
      if (!services.clock.synced &&
          meta?.clockServerUtc != null &&
          meta?.clockFetchedAt != null) {
        services.clock.restore(meta!.clockServerUtc!, meta.clockFetchedAt!);
      }
    }
    _clockFetchedAt = DateTime.now();
    // The ticker may have been asleep for a long time; force it to re-emit.
    ref.read(clockRevisionProvider.notifier).bump();
  }

  /// Clock sync + initial pull after login/startup.
  Future<void> syncClockAndPull() async {
    debugPrint('[sync] syncClockAndPull start');
    await syncClock();
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
      // Any sync — automatic or the toolbar button — also puts the current-time
      // line back on the correct minute: refresh the offset when it is stale
      // and always re-emit so the line redraws now.
      final stale = _clockFetchedAt == null ||
          DateTime.now().difference(_clockFetchedAt!) > const Duration(minutes: 2);
      if (stale) {
        await syncClock();
      } else {
        ref.read(clockRevisionProvider.notifier).bump();
      }
      final engine = ref.read(servicesProvider).syncEngine;
      final result = await engine.syncOnce().timeout(_cycleTimeout);
      debugPrint('[sync] syncNow done: pushed=${result.pushed} pulled=${result.pulled} '
          'conflicts=${result.conflictCount} err=${result.error}');
      state = state.copyWith(
        syncing: false,
        lastSyncAt: DateTime.now().toUtc(),
        lastError: result.error,
        // Prefix the server so a report is self-contained when pasted.
        lastErrorDetail: result.error == null
            ? null
            : 'server: ${ref.read(servicesProvider).http.baseUrl}\n'
                '${result.errorDetail ?? result.error}',
        hasRunOnce: true,
      );
      if (result.error == 'offline') {
        // Two offline cycles in a row usually mean a dead socket rather than an
        // unhappy server: rebuild it once.
        _transportFailures++;
        if (_transportFailures == 2) {
          unawaited(resetNetworkState(reason: '连续离线'));
        }
      } else if (result.error == null) {
        _transportFailures = 0;
        _timeouts = 0;
      }
      return result;
    } on TimeoutException {
      // A half-open socket can outlive Dio's own timeouts; rebuild the transport
      // instead of leaving the UI stuck on "正在同步".
      debugPrint('[sync] syncNow timed out after ${_cycleTimeout.inSeconds}s');
      _timeouts++;
      state = state.copyWith(
        syncing: false,
        lastError: '同步超时',
        lastErrorDetail: 'server: ${ref.read(servicesProvider).http.baseUrl}\n'
            '请求超过 ${_cycleTimeout.inSeconds} 秒没有返回，已自动重置网络连接。',
        hasRunOnce: true,
      );
      if (_timeouts <= 1) unawaited(resetNetworkState(reason: '同步超时'));
      return null;
    } catch (e) {
      // Should not happen (engine catches), but keep the UI unstuck.
      debugPrint('[sync] syncNow threw: $e');
      state = state.copyWith(syncing: false, lastError: '$e', hasRunOnce: true);
      return null;
    } finally {
      _running = false;
    }
  }

  /// Throws the transport away and starts over: fresh sockets, a fresh clock
  /// reading, no stuck "syncing" flag. Runs automatically after a timeout (or
  /// two offline cycles) and is available from Settings when the app looks
  /// wedged.
  Future<void> resetNetworkState({String? reason}) async {
    final services = ref.read(servicesProvider);
    debugPrint('[sync] resetNetworkState${reason == null ? '' : ' ($reason)'}');
    _debounce?.cancel();
    _periodic?.cancel();
    _periodic = null;
    _running = false;
    _timeouts = 0;
    _transportFailures = 0;
    _clockFetchedAt = null;
    final rebuilt = services.http.resetConnections();
    state = SyncUiState(
      lastSyncAt: state.lastSyncAt,
      hasRunOnce: state.hasRunOnce,
      lastError: rebuilt ? null : '无法重建网络连接',
      lastErrorDetail: rebuilt ? null : '当前平台不支持重建连接，请重启应用。',
    );
    await syncClock();
    await syncNow();
    startPeriodicSync();
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
