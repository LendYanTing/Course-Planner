import '../core/util/json_utils.dart';

/// A long-lived MCP credential (`cpmcp_…`), as listed by `GET /mcp-tokens`
/// (docs/api.md §18). The secret is never part of this shape.
class McpToken {
  const McpToken({
    required this.id,
    required this.name,
    required this.tokenPrefix,
    required this.scopes,
    this.createdAt,
    this.lastUsedAt,
    this.expiresAt,
    this.revokedAt,
  });

  factory McpToken.fromJson(Map<String, dynamic> m) => McpToken(
        id: readString(m, 'id'),
        name: readString(m, 'name'),
        tokenPrefix: readString(m, 'tokenPrefix'),
        scopes: readStringList(m, 'scopes'),
        createdAt: parseUtc(readStringOrNull(m, 'createdAt')),
        lastUsedAt: parseUtc(readStringOrNull(m, 'lastUsedAt')),
        expiresAt: parseUtc(readStringOrNull(m, 'expiresAt')),
        revokedAt: parseUtc(readStringOrNull(m, 'revokedAt')),
      );

  final String id;
  final String name;
  final String tokenPrefix;
  final List<String> scopes;
  final DateTime? createdAt;
  final DateTime? lastUsedAt;
  final DateTime? expiresAt;
  final DateTime? revokedAt;

  bool get canWrite => scopes.contains('write');

  bool get revoked => revokedAt != null;

  /// Long-lived unless the server returned an expiry.
  bool get isLongLived => expiresAt == null;
}

/// A freshly minted MCP token — [token] is the plaintext secret and the server
/// only ever returns it in this one response (docs/mcp.md §10).
class McpTokenSecret {
  const McpTokenSecret({
    required this.id,
    required this.name,
    required this.token,
    required this.tokenPrefix,
    required this.scopes,
    this.createdAt,
    this.expiresAt,
  });

  factory McpTokenSecret.fromJson(Map<String, dynamic> m) => McpTokenSecret(
        id: readString(m, 'id'),
        name: readString(m, 'name'),
        token: readString(m, 'token'),
        tokenPrefix: readString(m, 'tokenPrefix'),
        scopes: readStringList(m, 'scopes'),
        createdAt: parseUtc(readStringOrNull(m, 'createdAt')),
        expiresAt: parseUtc(readStringOrNull(m, 'expiresAt')),
      );

  final String id;
  final String name;
  final String token;
  final String tokenPrefix;
  final List<String> scopes;
  final DateTime? createdAt;
  final DateTime? expiresAt;
}
