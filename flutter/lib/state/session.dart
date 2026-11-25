import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../core/error/api_exception.dart';
import '../core/time/user_time.dart';
import '../domain/user.dart';
import 'app_services.dart';
import 'prefs.dart';
import 'sync_controller.dart';

/// Current session state.
enum AuthPhase { unknown, signedOut, signedIn }

class SessionState {
  const SessionState({
    this.phase = AuthPhase.unknown,
    this.profile,
    this.error,
    this.busy = false,
    this.authExpired = false,
  });

  /// The reserved user id of the no-account (offline-first) session.
  static const String localUserId = 'local';

  final AuthPhase phase;
  final SessionProfile? profile;
  final String? error;
  final bool busy;

  /// True when the signed-in profile is the local, server-less default user.
  ///
  /// A local session never talks to the network: no token refresh, no clock
  /// fetch, no push/pull. It only ends when the user signs in to a server
  /// (or parks a server switch).
  bool get isLocalMode =>
      phase == AuthPhase.signedIn && profile?.userId == localUserId;

  /// The server definitively rejected our credentials (refresh token dead).
  ///
  /// The session deliberately stays [AuthPhase.signedIn]: the local mirror,
  /// the pending queue and every screen keep working offline-first, and the UI
  /// only warns that a fresh sign-in is needed. Pending edits stay queued and
  /// upload after the next successful sign-in.
  final bool authExpired;

  SessionState copyWith({
    AuthPhase? phase,
    SessionProfile? profile,
    String? error,
    bool? busy,
    bool? authExpired,
  }) =>
      SessionState(
        phase: phase ?? this.phase,
        profile: profile ?? this.profile,
        error: error,
        busy: busy ?? this.busy,
        authExpired: authExpired ?? this.authExpired,
      );
}

/// A requested server change that still needs credentials on the target
/// server. Parked until the next successful sign-in, then applied.
class PendingServerSwitch {
  const PendingServerSwitch({required this.baseUrl, required this.cloudToLocal});

  final String baseUrl;

  /// true = cloud overwrites local, false = local overwrites cloud.
  final bool cloudToLocal;
}

/// Session lifecycle: bootstrap / login / register / logout / server switch.
class SessionController extends Notifier<SessionState> {
  PendingServerSwitch? _pendingSwitch;

  /// Pref key remembering «credentials rejected» across restarts, so the app
  /// opens on the cached mirror and warns again instead of silently failing.
  static const _expiredPrefKey = 'auth_expired';

  /// The parked switch intent, if the user started one that needs sign-in.
  PendingServerSwitch? get pendingSwitch => _pendingSwitch;

  @override
  SessionState build() {
    ref
        .read(servicesProvider)
        .sessionSignals
        .onSessionInvalidated = _onSessionInvalidated;
    return const SessionState(phase: AuthPhase.unknown);
  }

  /// The server rejected the stored refresh token (see
  /// [AppServices.refreshAccessToken]).
  ///
  /// Deliberately does NOT sign the user out: the mirror, the pending queue and
  /// every read-only screen keep working, so content stays visible while the
  /// user re-authenticates. Only the expired flag is raised — the app root
  /// shows a toast with a 重新登录 action, and the settings page keeps an entry.
  void _onSessionInvalidated(String reason) {
    // A local session has no credentials to reject, so it never "expires".
    if (state.isLocalMode) return;
    if (state.phase != AuthPhase.signedIn) return;
    if (state.authExpired) return; // already reported; do not spam the UI
    debugPrint('[session] credentials rejected: $reason — staying signed in, local-only');
    state = state.copyWith(authExpired: true, error: reason);
    unawaited(ref.read(servicesProvider).prefStore.write(_expiredPrefKey, 'true'));
    bumpSessionRevision(ref);
  }

  /// Clears the persisted «expired» marker after fresh credentials land.
  Future<void> _clearExpired() async {
    try {
      await ref.read(servicesProvider).prefStore.write(_expiredPrefKey, 'false');
    } on Object {
      // Best effort: the in-memory state is authoritative for this run.
    }
  }

  /// Startup: open the cached session immediately (offline-first). A local
  /// (no-account) profile stops there. A cloud profile only refreshes the
  /// access token and pulls in the background when automatic sync is enabled.
  /// The UI never blocks on a network round-trip — that block previously made
  /// restarts spin forever whenever a refresh/secure-storage read stalled.
  Future<void> bootstrap() async {
    try {
      debugPrint('[session] bootstrap start');
      final services = ref.read(servicesProvider);
      final meta = await services.store.meta().timeout(const Duration(seconds: 15));
      debugPrint('[session] meta read ok: user=${meta?.userId} tz=${meta?.timezone}');

      // The cached mirror only belongs to the active server when they match;
      // otherwise resuming would show (and later push) another server's data.
      final active = services.http.baseUrl;
      final dataServer = await services.serverStore.dataServer();
      final dataMatchesServer = dataServer == null || dataServer == active;

      final cached = meta;
      final hasCachedProfile =
          cached?.userId != null && cached!.timezone != null && dataMatchesServer;

      // A no-account (local) profile opens straight into the app. Startup must
      // never touch the network here: no token read, no refresh, no clock/pull.
      if (hasCachedProfile && cached.userId == SessionState.localUserId) {
        debugPrint('[session] resume local mode (no account, offline)');
        state = SessionState(
          phase: AuthPhase.signedIn,
          profile: SessionProfile(
            userId: cached.userId!,
            username: cached.username ?? '本地用户',
            timezone: cached.timezone!,
            email: cached.email,
          ),
        );
        bumpSessionRevision(ref);
        return;
      }

      final refresh = await services.tokenBox
          .readRefreshToken()
          .timeout(const Duration(seconds: 15))
          .catchError((_) => null);
      debugPrint('[session] refresh token present=${refresh != null && refresh.isNotEmpty}');
      // A rejected-credentials marker from an earlier run: keep opening the
      // cached mirror, but do not pretend a background refresh can fix it.
      final expired = await services.prefStore
              .read(_expiredPrefKey)
              .timeout(const Duration(seconds: 5))
              .catchError((_) => null) ==
          'true';
      debugPrint('[session] credentials marked expired=$expired');

      if (hasCachedProfile) {
        debugPrint('[session] resume from cached profile (offline-first)');
        state = SessionState(
          phase: AuthPhase.signedIn,
          profile: SessionProfile(
            userId: cached.userId!,
            username: cached.username ?? '',
            timezone: cached.timezone!,
            email: cached.email,
          ),
          authExpired: expired,
          error: expired ? '登录已过期，请重新登录' : null,
        );
        bumpSessionRevision(ref);
        if (expired) {
          // Nothing to retry with, and no reason to hammer the server: the
          // mirror is complete locally. Re-login restarts sync.
          return;
        }
        // Cloud sync is opt-in: a restart of a cloud account must stay quiet
        // unless the user left automatic sync on.
        if (!ref.read(syncEnabledProvider)) {
          debugPrint('[session] cloud sync disabled → skip refresh + initial pull');
          return;
        }
        // Fire-and-forget token refresh; do not hold the homepage hostage.
        if (refresh != null && refresh.isNotEmpty) {
          unawaited(_ensureAccessToken());
        }
        // Start the sync coordinator (clock + initial pull) like a normal
        // sign-in so restart doesn't leave the app without periodic sync.
        unawaited(ref.read(syncCoordinatorProvider.notifier).syncClockAndPull());
        return;
      }
      if (cached?.userId != null && !dataMatchesServer) {
        debugPrint('[session] local data belongs to $dataServer, active is $active '
            '→ require sign-in');
      }

      // No cached profile: try the stored refresh token, then fall back to a
      // no-account local profile instead of the login wall.
      if (refresh != null && refresh.isNotEmpty) {
        try {
          debugPrint('[session] trying online refresh…');
          final session = await services.authApi.refresh(refresh);
          debugPrint('[session] online refresh ok');
          await _accept(session);
          return;
        } on Object catch (e) {
          debugPrint('[session] refresh failed: $e');
        }
      }
      // Nothing to resume: open the app as the local default user (offline).
      // The login wall only appears if even that local bootstrap fails.
      try {
        await enterLocalMode();
        return;
      } on Object catch (e) {
        debugPrint('[session] enterLocalMode failed: $e');
      }
      debugPrint('[session] no session → signedOut');
      state = const SessionState(phase: AuthPhase.signedOut);
      bumpSessionRevision(ref);
    } on Object catch (e, st) {
      // Never leave the UI on the unknown phase forever: surface a hard
      // failure as signed-out so the login screen (and its error path) can
      // show what happened.
      debugPrint('[session] bootstrap failed: $e\n$st');
      state = const SessionState(phase: AuthPhase.signedOut);
      bumpSessionRevision(ref);
    }
  }

  /// Background access-token refresh using the stored refresh token. Delegates
  /// to [AppServices.refreshAccessToken] so every refresh path shares the same
  /// 401 classification, race retry and session-invalidation handling.
  Future<void> _ensureAccessToken() async {
    try {
      debugPrint('[session] background access-token refresh…');
      final ok = await ref.read(servicesProvider).refreshAccessToken();
      debugPrint(
          ok ? '[session] background refresh ok' : '[session] background refresh failed');
    } on Object catch (e) {
      debugPrint('[session] background refresh failed: $e');
    }
  }

  /// Enters the no-account (local) session: a default profile is persisted and
  /// the app opens on the local mirror. Purely local — no network, and the
  /// existing mirror / pending queue are kept as they are.
  Future<void> enterLocalMode() async {
    final services = ref.read(servicesProvider);
    final profile = SessionProfile(
      userId: SessionState.localUserId,
      username: '本地用户',
      timezone: ref.read(localTimezoneProvider),
    );
    await services.persistUser(profile);
    state = SessionState(phase: AuthPhase.signedIn, profile: profile);
    bumpSessionRevision(ref);
  }

  /// Changes the timezone of the local session (设置 → 时区). Only meaningful
  /// without an account: a cloud profile takes its timezone from the server.
  ///
  /// Throws [ApiException] with [ApiErrorCodes.invalidTimezone] for an unknown
  /// IANA name; does nothing when the session is not local.
  Future<void> setLocalTimezone(String timezone) async {
    final current = state.profile;
    if (!state.isLocalMode || current == null) return;
    final valid = UserTime.tryCreate(timezone);
    if (valid == null) {
      throw ApiException(
        code: ApiErrorCodes.invalidTimezone,
        message: '无效的时区: $timezone',
      );
    }
    await ref.read(localTimezoneProvider.notifier).set(valid.ianaName);
    final profile = SessionProfile(
      userId: current.userId,
      username: current.username,
      timezone: valid.ianaName,
      email: current.email,
    );
    await ref.read(servicesProvider).persistUser(profile);
    state = SessionState(phase: AuthPhase.signedIn, profile: profile);
    bumpSessionRevision(ref);
  }

  Future<String?> login({
    required String username,
    required String password,
    String? serverUrl,
  }) async {
    final services = ref.read(servicesProvider);
    state = state.copyWith(busy: true, error: null);
    try {
      if (serverUrl != null && serverUrl.trim().isNotEmpty) {
        await services.useServer(serverUrl);
      }
      final session = await services.authApi.login(
        username: username,
        password: password,
      );
      await _accept(session);
      return null;
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '$e');
      return '$e';
    }
  }

  Future<String?> register({
    required String username,
    String? email,
    required String password,
    required String timezone,
    String? serverUrl,
  }) async {
    final services = ref.read(servicesProvider);
    state = state.copyWith(busy: true, error: null);
    try {
      if (serverUrl != null && serverUrl.trim().isNotEmpty) {
        await services.useServer(serverUrl);
      }
      final session = await services.authApi.register(
        username: username,
        email: email,
        password: password,
        timezone: timezone,
      );
      await _accept(session);
      return null;
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '$e');
      return '$e';
    }
  }

  /// Switches the active server and migrates data in [cloudToLocal] direction.
  ///
  /// Returns null on success; `'needsLogin'` when the target server has no
  /// usable credentials (the intent is parked and replayed after sign-in); or
  /// an error string.
  Future<String?> switchServer({
    required String rawUrl,
    required bool cloudToLocal,
  }) async {
    final services = ref.read(servicesProvider);
    state = state.copyWith(busy: true, error: null);
    try {
      final normalized = await services.useServer(rawUrl);
      final authed = await services.refreshAccessToken();
      if (!authed) {
        debugPrint('[session] switch: no credential for $normalized → sign-in');
        _pendingSwitch = PendingServerSwitch(
          baseUrl: normalized,
          cloudToLocal: cloudToLocal,
        );
        state = const SessionState(phase: AuthPhase.signedOut);
        bumpSessionRevision(ref);
        return 'needsLogin';
      }
      final me = await services.authApi.me();
      debugPrint('[session] switch → $normalized cloudToLocal=$cloudToLocal');
      await _migrateServer(cloudToLocal: cloudToLocal, user: me);
      return null;
    } on Object catch (e) {
      state = state.copyWith(busy: false, error: '$e');
      return '$e';
    }
  }

  /// Stores tokens + profile, resets local data when switching accounts,
  /// and kicks off clock sync + initial pull.
  Future<void> _accept(SessionData data) async {
    final services = ref.read(servicesProvider);
    final meta = await services.store.meta();
    final user = data.user;

    await services.tokenBox.writeRefreshToken(data.refreshToken);
    services.tokenBox.setAccessToken(data.accessToken);
    services.http.setAccessToken(data.accessToken);
    await services.serverStore.remember(services.http.baseUrl, username: user.username);
    // A real cloud account just signed in: automatic sync starts enabled.
    await ref.read(syncEnabledProvider.notifier).set(true);

    final pending = _pendingSwitch;
    _pendingSwitch = null;
    if (pending != null) {
      // A parked server switch: migrate in the direction the user picked.
      await _migrateServer(
        cloudToLocal: pending.cloudToLocal,
        user: user,
        serverBaseUrl: pending.baseUrl,
      );
      return;
    }

    // Local-first: when the previous session was the offline profile, the
    // mirror is the only copy of the user's data. Upload it instead of wiping
    // it (the old account-switch path treated it as "another user's data").
    final wasLocal = meta?.userId == SessionState.localUserId;
    if (wasLocal) {
      debugPrint('[session] first cloud sign-in from local mode → upload local data');
      await services.syncEngine.uploadAllLocal();
    } else {
      // Signing in on a server whose data we do not mirror yet: never push the
      // previous server's working copy upstream. Pull the cloud copy instead.
      final dataServer = await services.serverStore.dataServer();
      final serverChanged =
          dataServer != null && dataServer != services.http.baseUrl;
      if (serverChanged || (meta?.userId != null && meta!.userId != user.id)) {
        if (serverChanged) {
          debugPrint('[session] first sign-in on ${services.http.baseUrl} → adopt cloud data');
        }
        await services.syncEngine.resetLocalData();
        await services.syncEngine.pull(after: 0);
      }
    }
    final profile = SessionProfile(
      userId: user.id,
      username: user.username,
      email: user.email,
      timezone: user.timezone,
    );
    await services.persistUser(profile);
    await services.serverStore.setDataServer(services.http.baseUrl);

    await _clearExpired();
    state = SessionState(phase: AuthPhase.signedIn, profile: profile);
    bumpSessionRevision(ref);

    unawaited(ref.read(syncCoordinatorProvider.notifier).syncClockAndPull());
  }

  /// Applies an explicit server migration and signs the session in.
  Future<void> _migrateServer({
    required bool cloudToLocal,
    required User user,
    String? serverBaseUrl,
  }) async {
    final services = ref.read(servicesProvider);
    final target = serverBaseUrl ?? services.http.baseUrl;
    if (cloudToLocal) {
      // Cloud wins: drop the local working copy and rebuild from the server.
      await services.store.resetForNewUser();
      await services.syncEngine.pull(after: 0);
    } else {
      // Local wins: keep the working copy, restart the journal cursor (the
      // new server's cursors are unrelated) and re-upload everything.
      await services.store.resetCursor();
      await services.syncEngine.uploadAllLocal();
    }
    final profile = SessionProfile(
      userId: user.id,
      username: user.username,
      email: user.email,
      timezone: user.timezone,
    );
    await services.persistUser(profile);
    await services.serverStore.setActive(target);
    await services.serverStore.setDataServer(target);
    services.tokenBox.serverKey = AppConfig.tokenServerKey(target);

    await _clearExpired();
    state = SessionState(phase: AuthPhase.signedIn, profile: profile);
    bumpSessionRevision(ref);
    unawaited(ref.read(syncCoordinatorProvider.notifier).syncClockAndPull());
  }

  /// Signs out of the cloud account but keeps the app usable: the local
  /// mirror and pending operations are the user's only copy, so they are never
  /// wiped. The session returns to the no-account local mode instead of the
  /// login wall.
  Future<void> logout() async {
    final services = ref.read(servicesProvider);
    final refresh = await services.tokenBox.readRefreshToken();
    try {
      if (refresh != null) await services.authApi.logout(refresh);
    } on Object {
      // best effort server-side revoke
    }
    await services.tokenBox.clearAll();
    services.http.setAccessToken(null);
    // Leaving the account stops every automatic network call.
    await ref.read(syncEnabledProvider.notifier).set(false);
    await _clearExpired();
    try {
      await enterLocalMode();
    } on Object catch (e) {
      debugPrint('[session] enterLocalMode after logout failed: $e');
      state = const SessionState(phase: AuthPhase.signedOut);
      bumpSessionRevision(ref);
    }
  }
}

final sessionControllerProvider =
    NotifierProvider<SessionController, SessionState>(SessionController.new);

/// Bumped on every auth transition; the router listens to it so redirects
/// fire the moment the session state changes.
final sessionRevisionProvider = Provider<ValueNotifier<int>>(
  (ref) => ValueNotifier<int>(0),
);

void bumpSessionRevision(Ref ref) {
  ref.read(sessionRevisionProvider).value++;
}
