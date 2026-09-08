import '../data/api/auth_api.dart';
import '../data/api/data_api.dart';
import '../data/api/http_client.dart';
import '../data/api/import_api.dart';
import '../data/api/sync_api.dart';
import '../data/auth/token_box.dart';
import '../data/db/app_database.dart';
import '../data/local/sync_store.dart';
import '../data/repo/entity_repo.dart';
import '../sync/clock.dart';
import '../sync/sync_engine.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Injected app services (built in main() and overridden into the scope).
final servicesProvider = Provider<AppServices>((ref) {
  throw StateError('servicesProvider must be overridden with AppServices');
});

/// Coalesces the refresh callback wiring (avoids a constructor cycle between
/// [ApiHttp] and the session service).
class RefreshCoordinator {
  RefreshCallback? callback;

  Future<bool> invoke() async {
    final cb = callback;
    if (cb == null) return false;
    return cb();
  }
}

/// The application service graph. Built once in `main()` and exposed through
/// [servicesProvider]; UI code never constructs API/DB objects itself.
class AppServices {
  AppServices({
    required this.db,
    required this.store,
    required this.repo,
    required this.tokenBox,
    required this.http,
    required this.authApi,
    required this.syncApi,
    required this.dataApi,
    required this.importApi,
    required this.clock,
    required this.syncEngine,
    required this.refreshCoordinator,
  });

  static Future<AppServices> create() async {
    final db = AppDatabase();
    final store = SyncStore(db);
    final tokenBox = TokenBox();
    final coordinator = RefreshCoordinator();

    final http = ApiHttp.create(onRefresh: () => coordinator.invoke());
    final authApi = AuthApi(http);
    final syncApi = SyncApi(http);
    final dataApi = DataApi(http);
    final importApi = ImportApi(http);
    final repo = EntityRepo(db, store);
    final clock = ServerClock();
    final syncEngine = SyncEngine(db: db, store: store, api: syncApi);

    final services = AppServices(
      db: db,
      store: store,
      repo: repo,
      tokenBox: tokenBox,
      http: http,
      authApi: authApi,
      syncApi: syncApi,
      dataApi: dataApi,
      importApi: importApi,
      clock: clock,
      syncEngine: syncEngine,
      refreshCoordinator: coordinator,
    );
    coordinator.callback = () => services.refreshAccessToken();
    return services;
  }

  final AppDatabase db;
  final SyncStore store;
  final EntityRepo repo;
  final TokenBox tokenBox;
  final ApiHttp http;
  final AuthApi authApi;
  final SyncApi syncApi;
  final DataApi dataApi;
  final ImportApi importApi;
  final ServerClock clock;
  final SyncEngine syncEngine;
  final RefreshCoordinator refreshCoordinator;

  /// Background 401 handling: rotate the refresh token and update the
  /// in-memory access token. Returns false when there is nothing to refresh.
  Future<bool> refreshAccessToken() async {
    final refresh = await tokenBox.readRefreshToken();
    if (refresh == null || refresh.isEmpty) return false;
    try {
      final session = await authApi.refresh(refresh);
      await tokenBox.writeRefreshToken(session.refreshToken);
      tokenBox.setAccessToken(session.accessToken);
      http.setAccessToken(session.accessToken);
      final profile = SessionProfile(
        userId: session.user.id,
        username: session.user.username,
        email: session.user.email,
        timezone: session.user.timezone,
      );
      await _persistProfile(profile);
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> persistUser(SessionProfile profile) => _persistProfile(profile);

  Future<void> _persistProfile(SessionProfile profile) async {
    final meta = await store.meta();
    await store.saveMeta((meta ?? const AppMetaSnapshot()).copyWith(
      userId: profile.userId,
      username: profile.username,
      email: profile.email,
      timezone: profile.timezone,
    ));
  }
}

/// Lightweight profile for persistence, decoupled from the API session.
class SessionProfile {
  const SessionProfile({
    required this.userId,
    required this.username,
    required this.timezone,
    this.email,
  });

  final String userId;
  final String username;
  final String timezone;
  final String? email;
}
