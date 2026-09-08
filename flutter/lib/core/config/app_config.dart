/// Runtime configuration.
///
/// The API base URL points at the REST endpoint of the Course Planner
/// backend (`docs/openapi.yaml` servers: `/api/v1`). It can be overridden
/// per build with `--dart-define=API_BASE_URL=...` (e.g. pointing the app at
/// a Cloudflare tunnel / LAN address during development).
class AppConfig {
  AppConfig._();

  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080/api/v1',
  );

  /// How long an access token stays in memory before it is considered stale
  /// (server default is 15-30 minutes; we refresh opportunistically on 401).
  static const Duration accessTokenSkew = Duration(minutes: 2);
}
