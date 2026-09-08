import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Token holder (docs/security.md §2).
///
/// * Access token lives in memory only (never persisted).
/// * Refresh token lives in platform secure storage (DPAPI/Keychain/
///   Keystore), surviving restarts so the session can be resumed.
class TokenBox {
  TokenBox({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  static const _refreshKey = 'cp_refresh_token';

  final FlutterSecureStorage _storage;
  String? _accessToken;

  String? get accessToken => _accessToken;

  bool get hasAccessToken => _accessToken != null;

  void setAccessToken(String token) {
    _accessToken = token;
  }

  void clearAccessToken() {
    _accessToken = null;
  }

  Future<String?> readRefreshToken() => _storage.read(key: _refreshKey);

  Future<void> writeRefreshToken(String token) =>
      _storage.write(key: _refreshKey, value: token);

  Future<void> clearRefreshToken() => _storage.delete(key: _refreshKey);

  /// Clears everything (logout).
  Future<void> clearAll() async {
    clearAccessToken();
    await clearRefreshToken();
  }
}
