import 'dart:io';

/// Host (VM) tests need a loadable sqlite3. sqlite3 3.x auto-loads
/// `sqlite3.dll` from PATH on Windows — the test runner must therefore be
/// launched with the repo's `.tools/sqlite3` directory prepended to PATH
/// (see flutter/README.md dev commands). This helper only sanity-checks that.
void configureHostSqlite() {
  if (!Platform.isWindows) return;
  final candidates = <String>[
    '${Directory.current.parent.path}${Platform.pathSeparator}.tools'
        '${Platform.pathSeparator}sqlite3${Platform.pathSeparator}sqlite3.dll',
    '${Directory.current.path}${Platform.pathSeparator}sqlite3.dll',
    'sqlite3.dll',
  ];
  final dll = candidates.firstWhere((p) => File(p).existsSync(), orElse: () => '');
  assert(dll.isNotEmpty, 'sqlite3.dll not found; prepend .tools\\sqlite3 to PATH');
}
