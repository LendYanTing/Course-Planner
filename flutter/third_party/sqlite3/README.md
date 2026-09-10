# Vendored SQLite amalgamation

`sqlite3.c` / `sqlite3.h` — SQLite **3.53.4** (amalgamation
`sqlite-amalgamation-3530400.zip`).

## Why this is here

The `sqlite3` Dart package builds its native library through a Dart build hook
(`hook/build.dart`). By default that hook downloads a **prebuilt** `libsqlite3.so`
from the package's GitHub releases. In an environment without access to
github.com the build fails:

```
This failed (attempted to download
 https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-3.5.2/libsqlite3.arm64.android.so)
```

The hook also supports compiling from source, which needs no download. We point
it at this vendored amalgamation via `hooks.user_defines` in
`flutter/pubspec.yaml`:

```yaml
hooks:
  user_defines:
    sqlite3:
      source: source
      path: third_party/sqlite3/sqlite3.c
```

`native_toolchain_c` compiles it per ABI with the Android NDK, so the resulting
APK is self-contained (no dependency on the platform's `libsqlite3.so`, which is
not part of the public NDK API).

## Updating

```bash
# pick the current amalgamation from https://sqlite.org/download.html
curl -LO https://sqlite.org/YYYY/sqlite-amalgamation-NNNNNNN.zip
unzip -o sqlite-amalgamation-NNNNNNN.zip
cp sqlite-amalgamation-NNNNNNN/sqlite3.c sqlite-amalgamation-NNNNNNN/sqlite3.h \
   flutter/third_party/sqlite3/
```

Then bump the version note above. Keep `sqlite3.c` and `sqlite3.h` from the same
amalgamation release — the hook adds the file's directory to the include path.

## Alternatives

* Reachable network: drop the `hooks.user_defines` block and let the hook
  download the prebuilt binary (smaller, prebuilt, no NDK compile per ABI).
* `source: system`: `dlopen`s the platform's `libsqlite3.so`. Builds instantly
  but relies on a non-NDK platform library, so it is not recommended for release.
