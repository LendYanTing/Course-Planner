import 'dart:convert';

/// The client-side snippets shown by the "connect an Agent to MCP" page
/// (docs/mcp.md §13).
///
/// Pure string builders so the exported JSON/commands can be unit-tested: a
/// malformed snippet is the easiest thing to get wrong and the hardest to
/// notice by eye.
class McpConfigSnippets {
  McpConfigSnippets._();

  static const serverName = 'course-planner';

  static String headerValue(String token) => 'Bearer $token';

  static String _entryJson(String url, String token) =>
      const JsonEncoder.withIndent('  ').convert({
        serverName: {
          'type': 'http',
          'url': url,
          'headers': {'Authorization': headerValue(token)},
        },
      });

  /// Claude Desktop / project `.mcp.json` / Cursor: top-level `mcpServers`.
  static String mcpServersJson(String url, String token) =>
      const JsonEncoder.withIndent('  ').convert({
        'mcpServers': jsonDecode(_entryJson(url, token)),
      });

  /// VS Code / Copilot `.vscode/mcp.json`: the top-level key is `servers`.
  static String vscodeServersJson(String url, String token) =>
      const JsonEncoder.withIndent('  ').convert({
        'servers': jsonDecode(_entryJson(url, token)),
      });

  /// Claude Code CLI.
  static String claudeCodeCommand(String url, String token) =>
      'claude mcp add --transport http $serverName $url '
      '--header "Authorization: ${headerValue(token)}"';

  /// Bridge for clients that only speak stdio.
  static String mcpRemoteCommand(String url, String token) =>
      'npx mcp-remote $url --header "Authorization: ${headerValue(token)}"';

  /// Hand-run check; a healthy server answers with `result.tools`.
  static String curlSelfCheck(String url, String token) => 'curl -s $url \\\n'
      '  -H \'Authorization: ${headerValue(token)}\' \\\n'
      '  -H \'Content-Type: application/json\' \\\n'
      '  -d \'{"jsonrpc":"2.0","id":1,"method":"tools/list"}\'';
}
