/// Runtime configuration.
///
/// The API base URL points at the REST endpoint of the Course Planner
/// backend (`docs/openapi.yaml` servers: `/api/v1`). It can be set per build
/// with `--dart-define=API_BASE_URL=...` and is overridden at runtime by the
/// user (login screen / settings) so one install can talk to several servers.
class AppConfig {
  AppConfig._();

  /// Compile-time default / fallback server.
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080/api/v1',
  );

  /// How long an access token stays in memory before it is considered stale
  /// (server default is 15-30 minutes; we refresh opportunistically on 401).
  static const Duration accessTokenSkew = Duration(minutes: 2);

  /// Normalizes a user-entered server address into an API base URL:
  /// * trims, adds a scheme when missing (`host:8080` → `http://host:8080`),
  /// * drops trailing slashes,
  /// * appends the `/api/v1` prefix when only a host (no path) was given.
  ///
  /// A URL that already carries a path (e.g. `https://x.trycloudflare.com/api/v1`
  /// or a reverse-proxied prefix) is kept as-is.
  static String normalizeBaseUrl(String raw) {
    var s = raw.trim();
    if (s.isEmpty) return apiBaseUrl;
    if (!RegExp(r'^https?://', caseSensitive: false).hasMatch(s)) {
      s = 'http://$s';
    }
    while (s.endsWith('/')) {
      s = s.substring(0, s.length - 1);
    }
    final uri = Uri.tryParse(s);
    if (uri == null) return s;
    if (uri.path.isEmpty || uri.path == '/') {
      return '$s/api/v1';
    }
    return s;
  }

  /// Secure-storage key suffix for refresh tokens of [baseUrl]. Returns null
  /// for the compile-time default server so existing sessions keep their
  /// legacy (unsuffixed) key and stay logged in across the upgrade.
  static String? tokenServerKey(String baseUrl) {
    if (baseUrl == apiBaseUrl) return null;
    return baseUrl.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
  }
}
