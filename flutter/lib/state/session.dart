import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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

/// Session lifecycle: bootstrap / login / register / logout.
class SessionController extends Notifier<SessionState> {
  @override
  SessionState build() => const SessionState(phase: AuthPhase.unknown);

  /// Startup: resume an existing session from the stored refresh token, or
  /// fall back to the cached profile when offline (offline-first).
  Future<void> bootstrap() async {
    final services = ref.read(servicesProvider);
    final meta = await services.store.meta();
    final refresh = await services.tokenBox.readRefreshToken();
    if (refresh != null && refresh.isNotEmpty) {
      try {
        final session = await services.authApi.refresh(refresh);
        await _accept(session);
        return;
      } on Object {
        // expired/offline → try the cached profile below
      }
    }
    final cached = meta;
    if (cached?.userId != null && cached!.timezone != null) {
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
      return;
    }
    state = const SessionState(phase: AuthPhase.signedOut);
    bumpSessionRevision(ref);
  }

  Future<String?> login({
    required String username,
    required String password,
  }) async {
    final services = ref.read(servicesProvider);
    state = state.copyWith(busy: true, error: null);
    try {
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
  }) async {
    final services = ref.read(servicesProvider);
    state = state.copyWith(busy: true, error: null);
    try {
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

  /// Stores tokens + profile, resets local data when switching accounts,
  /// and kicks off clock sync + initial pull.
  Future<void> _accept(SessionData data) async {
    final services = ref.read(servicesProvider);
    final meta = await services.store.meta();
    final user = data.user;

    await services.tokenBox.writeRefreshToken(data.refreshToken);
    services.tokenBox.setAccessToken(data.accessToken);
    services.http.setAccessToken(data.accessToken);

    if (meta?.userId != null && meta!.userId != user.id) {
      await services.syncEngine.resetLocalData();
    }
    final profile = SessionProfile(
      userId: user.id,
      username: user.username,
      email: user.email,
      timezone: user.timezone,
    );
    await services.persistUser(profile);

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
