import 'dart:convert';

import 'package:course_planner/presentation/settings/mcp_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// The snippets pasted into MCP clients must be valid and carry the right
/// transport (docs/mcp.md §13): streamable HTTP, `Authorization: Bearer …`.
void main() {
  const url = 'https://cp.example.com/api/v1/mcp';
  const token = 'cpmcp_AbCdEfGh123';

  test('mcpServers JSON is valid and uses http transport', () {
    final decoded = jsonDecode(McpConfigSnippets.mcpServersJson(url, token));
    final entry = (decoded as Map)['mcpServers'][McpConfigSnippets.serverName] as Map;
    expect(entry['type'], 'http', reason: 'must not be sse');
    expect(entry['url'], url);
    expect((entry['headers'] as Map)['Authorization'], 'Bearer $token');
  });

  test('VS Code variant uses the `servers` top-level key', () {
    final decoded = jsonDecode(McpConfigSnippets.vscodeServersJson(url, token));
    final map = decoded as Map;
    expect(map.containsKey('servers'), isTrue);
    expect(map.containsKey('mcpServers'), isFalse);
    expect((map['servers'][McpConfigSnippets.serverName] as Map)['type'], 'http');
  });

  test('header value is Bearer + token (single space)', () {
    expect(McpConfigSnippets.headerValue(token), 'Bearer cpmcp_AbCdEfGh123');
  });

  test('CLI commands pass the transport, url and header', () {
    final claude = McpConfigSnippets.claudeCodeCommand(url, token);
    expect(claude, startsWith('claude mcp add --transport http course-planner '));
    expect(claude, contains(url));
    expect(claude, contains('--header "Authorization: Bearer $token"'));

    final remote = McpConfigSnippets.mcpRemoteCommand(url, token);
    expect(remote, startsWith('npx mcp-remote $url'));
    expect(remote, contains('--header "Authorization: Bearer $token"'));
  });

  test('curl self-check posts tools/list with JSON content type', () {
    final curl = McpConfigSnippets.curlSelfCheck(url, token);
    expect(curl, contains(url));
    expect(curl, contains("'Authorization: Bearer $token'"));
    expect(curl, contains("'Content-Type: application/json'"));
    expect(curl, contains('"method":"tools/list"'));
  });
}
