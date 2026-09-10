import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token holder (docs/security.md §2).
///
/// * Access token lives in memory only (never persisted).
/// * Refresh token lives in platform secure storage (DPAPI/Keychain/
///   Keystore), surviving restarts so the session can be resumed.
///
/// Refresh tokens are **scoped per server** ([serverKey]) so switching between
/// servers never reuses another server's credentials. A null [serverKey] keeps
/// the legacy unsuffixed key, which is what the compile-time default server
/// uses (so existing sessions survive the multi-server upgrade).
class TokenBox {
  TokenBox({FlutterSecureStorage? storage, this.serverKey})
      : _storage = storage ?? const FlutterSecureStorage();

  static const _baseKey = 'cp_refresh_token';

  final FlutterSecureStorage _storage;

  /// Scope for the refresh token; see [AppConfig.tokenServerKey].
  String? serverKey;

  String? _accessToken;

  String? get accessToken => _accessToken;

  bool get hasAccessToken => _accessToken != null;

  void setAccessToken(String token) {
    _accessToken = token;
  }

  void clearAccessToken() {
    _accessToken = null;
  }

  static String _keyFor(String? key) =>
      (key == null || key.isEmpty) ? _baseKey : '$_baseKey@$key';

  Future<String?> readRefreshToken() =>
      _storage.read(key: _keyFor(serverKey));

  /// Reads the token belonging to an explicit server scope (used by the
  /// backup exporter, which walks every known server).
  Future<String?> readRefreshTokenFor(String? key) =>
      _storage.read(key: _keyFor(key));

  Future<void> writeRefreshToken(String token, {String? forServerKey}) =>
      _storage.write(key: _keyFor(forServerKey ?? serverKey), value: token);

  Future<void> clearRefreshToken() =>
      _storage.delete(key: _keyFor(serverKey));

  /// Clears everything (logout).
  Future<void> clearAll() async {
    clearAccessToken();
    await clearRefreshToken();
  }
}
