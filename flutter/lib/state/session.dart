import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../domain/user.dart';
import 'app_services.dart';
import 'sync_controller.dart';

/// Current session state.
enum AuthPhase { unknown, signedOut, signedIn }

class SessionState {
  const SessionState({
    this.phase = AuthPhase.unknown,
    this.profile,
    this.error,
    this.busy = false,
  });

  final AuthPhase phase;
  final SessionProfile? profile;
  final String? error;
  final bool busy;

  SessionState copyWith({
    AuthPhase? phase,
    SessionProfile? profile,
    String? error,
    bool? busy,
  }) =>
      SessionState(
        phase: phase ?? this.phase,
        profile: profile ?? this.profile,
        error: error,
        busy: busy ?? this.busy,
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

  /// The parked switch intent, if the user started one that needs sign-in.
  PendingServerSwitch? get pendingSwitch => _pendingSwitch;

  @override
  SessionState build() => const SessionState(phase: AuthPhase.unknown);

  /// Startup: show the cached profile immediately (offline-first), then
  /// refresh the access token in the background. The UI never blocks on a
  /// network round-trip — that block previously made restarts spin forever
  /// whenever a refresh/secure-storage read stalled.
  Future<void> bootstrap() async {
    try {
      debugPrint('[session] bootstrap start');
      final services = ref.read(servicesProvider);
      final meta = await services.store.meta().timeout(const Duration(seconds: 15));
      debugPrint('[session] meta read ok: user=${meta?.userId} tz=${meta?.timezone}');
      final refresh = await services.tokenBox
          .readRefreshToken()
          .timeout(const Duration(seconds: 15))
          .catchError((_) => null);
      debugPrint('[session] refresh token present=${refresh != null && refresh.isNotEmpty}');

      // The cached mirror only belongs to the active server when they match;
      // otherwise resuming would show (and later push) another server's data.
      final active = services.http.baseUrl;
      final dataServer = await services.serverStore.dataServer();
      final dataMatchesServer = dataServer == null || dataServer == active;

      final cached = meta;
      final hasCachedProfile =
          cached?.userId != null && cached!.timezone != null && dataMatchesServer;
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
        );
        bumpSessionRevision(ref);
        // Fire-and-forget token refresh; do not hold the homepage hostage.
        if (refresh != null && refresh.isNotEmpty) {
          unawaited(_ensureAccessToken(refresh));
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

      // No cached profile: we must authenticate over the network.
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

  /// Background access-token refresh using the stored refresh token. Updates
  /// the in-memory token + metadata; any failure is non-fatal (the Dio
  /// interceptor retries a refresh on the next 401 anyway).
  Future<void> _ensureAccessToken(String refresh) async {
    try {
      debugPrint('[session] background access-token refresh…');
      final session = await ref.read(servicesProvider).authApi.refresh(refresh);
      final services = ref.read(servicesProvider);
      await services.tokenBox.writeRefreshToken(session.refreshToken);
      services.tokenBox.setAccessToken(session.accessToken);
      services.http.setAccessToken(session.accessToken);
      await services.persistUser(SessionProfile(
        userId: session.user.id,
        username: session.user.username,
        email: session.user.email,
        timezone: session.user.timezone,
      ));
      debugPrint('[session] background refresh ok');
    } on Object catch (e) {
      debugPrint('[session] background refresh failed: $e');
    }
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
    final profile = SessionProfile(
      userId: user.id,
      username: user.username,
      email: user.email,
      timezone: user.timezone,
    );
    await services.persistUser(profile);
    await services.serverStore.setDataServer(services.http.baseUrl);

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

    state = SessionState(phase: AuthPhase.signedIn, profile: profile);
    bumpSessionRevision(ref);
    unawaited(ref.read(syncCoordinatorProvider.notifier).syncClockAndPull());
  }

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
    await services.syncEngine.resetLocalData();
    state = const SessionState(phase: AuthPhase.signedOut);
    bumpSessionRevision(ref);
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
