import '../../domain/mcp_token.dart';
import 'api_response.dart';
import 'http_client.dart';

/// Long-lived MCP credential management (docs/api.md §18).
///
/// These endpoints only accept a **session access token** — an MCP token can
/// never mint or revoke another MCP token. The plaintext secret comes back
/// exactly once, from [create].
class McpApi {
  McpApi(this._http);

  final ApiHttp _http;

  /// GET /mcp-tokens — never returns secrets.
  Future<List<McpToken>> list() async {
    final res = await _http.get('/mcp-tokens');
    return unwrapDataList(res)
        .whereType<Map>()
        .map((e) => McpToken.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  /// POST /mcp-tokens — mints a token and returns its one-time plaintext.
  ///
  /// [scopes] defaults to read+write server-side; pass `['read']` for a
  /// read-only credential. [expiresInDays] of 0 (or omitting it) means the
  /// token never expires.
  Future<McpTokenSecret> create({
    required String name,
    List<String> scopes = const ['read', 'write'],
    int expiresInDays = 0,
  }) async {
    final res = await _http.post('/mcp-tokens', body: {
      'name': name,
      'scopes': scopes,
      'expiresInDays': expiresInDays,
    });
    return McpTokenSecret.fromJson(unwrapDataObject(res));
  }

  /// DELETE /mcp-tokens/{tokenId} — revokes immediately.
  Future<void> revoke(String tokenId) async {
    await _http.delete('/mcp-tokens/$tokenId');
  }
}
