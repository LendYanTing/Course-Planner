import '../../domain/user.dart';
import 'api_response.dart';
import 'http_client.dart';

/// Auth + profile + meta endpoints (docs/api.md §3-4).
///
/// register/login/refresh return the user object flattened together with the
/// token trio inside the standard `{data: ...}` envelope (server
/// auth.writeSession).
class AuthApi {
  AuthApi(this._http);

  final ApiHttp _http;

  Future<SessionData> register({
    required String username,
    String? email,
    required String password,
    required String timezone,
  }) async {
    final res = await _http.post('/auth/register', body: {
      'username': username,
      if (email != null && email.isNotEmpty) 'email': email,
      'password': password,
      'timezone': timezone,
    });
    return SessionData.fromJson(unwrapDataObject(res));
  }

  Future<SessionData> login({
    required String username,
    required String password,
  }) async {
    final res = await _http.post('/auth/login', body: {
      'username': username,
      'password': password,
    });
    return SessionData.fromJson(unwrapDataObject(res));
  }

  Future<SessionData> refresh(String refreshToken) async {
    final res = await _http.post('/auth/refresh', body: {
      'refreshToken': refreshToken,
    });
    return SessionData.fromJson(unwrapDataObject(res));
  }

  /// Revokes the refresh token on the server. Pass the stored refresh token.
  Future<void> logout(String refreshToken) async {
    await _http.post('/auth/logout', body: {'refreshToken': refreshToken});
  }

  Future<User> me() async {
    final res = await _http.get('/me');
    return User.fromJson(unwrapDataObject(res));
  }

  /// GET /meta/time — authoritative server clock (UTC instant).
  Future<DateTime> serverTime() async {
    final res = await _http.get('/meta/time');
    final data = unwrapDataObject(res);
    final raw = data['serverTimeUtc'];
    final parsed = raw is String ? DateTime.tryParse(raw) : null;
    if (parsed == null) {
      throw const FormatException('serverTimeUtc missing or invalid');
    }
    return parsed.toUtc();
  }
}
