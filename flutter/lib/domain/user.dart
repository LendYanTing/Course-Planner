/// Authenticated user profile (docs/api.md §3.6, server user.DTO).
class User {
  const User({
    required this.id,
    required this.username,
    required this.timezone,
    this.email,
    this.createdAt,
    this.updatedAt,
  });

  factory User.fromJson(Map<String, dynamic> m) => User(
        id: (m['id'] ?? '') as String,
        username: (m['username'] ?? '') as String,
        timezone: (m['timezone'] ?? 'UTC') as String,
        email: m['email'] as String?,
        createdAt: _parse(m['createdAt']),
        updatedAt: _parse(m['updatedAt']),
      );

  final String id;
  final String username;
  final String timezone;
  final String? email;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  static DateTime? _parse(Object? v) {
    if (v is String) return DateTime.tryParse(v)?.toUtc();
    return null;
  }
}

/// Response payload of /auth/login, /auth/register and /auth/refresh:
/// the user object flattened together with the token trio.
class SessionData {
  const SessionData({
    required this.user,
    required this.accessToken,
    required this.expiresIn,
    required this.refreshToken,
  });

  factory SessionData.fromJson(Map<String, dynamic> data) => SessionData(
        user: User.fromJson(data),
        accessToken: (data['accessToken'] ?? '') as String,
        expiresIn: (data['expiresIn'] as num?)?.toInt() ?? 0,
        refreshToken: (data['refreshToken'] ?? '') as String,
      );

  final User user;
  final String accessToken;
  final int expiresIn;
  final String refreshToken;
}
