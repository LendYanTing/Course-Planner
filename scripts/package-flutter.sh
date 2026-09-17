#!/usr/bin/env bash
# Builds every artifact for one release into dist/.
#
# Android ships one APK per ABI rather than a fat one. Each build compiles its
# ABI name in (`--dart-define=APP_ABI=…`) so the in-app update check downloads
# the file that matches the device instead of guessing.
#
#   dist/course-planner-<ver>-arm64-v8a.apk     most phones
#   dist/course-planner-<ver>-armeabi-v7a.apk   32-bit ARM phones
#   dist/course-planner-<ver>-x86_64.apk        emulators / x86 tablets
#   dist/course-planner-<ver>-windows-x64.zip   desktop
#
# Usage:  scripts/package-flutter.sh [--skip-windows]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLUTTER_BIN="${FLUTTER_BIN:-$ROOT/.tools/flutter/bin/flutter}"
DIST="$ROOT/dist"
VERSION="$(sed -n 's/^version: *\([0-9][^+]*\).*/\1/p' "$ROOT/flutter/pubspec.yaml" | head -1)"
NAME="course-planner-$VERSION"

export PUB_CACHE="${PUB_CACHE:-$ROOT/.tools/pub-cache}"
mkdir -p "$DIST"

flutter() { "$FLUTTER_BIN" "$@"; }

# --- Android: one APK per ABI, each knowing which ABI it is ------------------
build_apk() { # <abi> <target-platform>
  local abi="$1" platform="$2" out="$DIST/$NAME-$1.apk"
  echo "==> android $abi"
  ( cd "$ROOT/flutter" && flutter build apk --release --no-pub \
      --target-platform "$platform" \
      --dart-define="APP_ABI=$abi" )
  cp "$ROOT/flutter/build/app/outputs/flutter-apk/app-release.apk" "$out"
  echo "    $out"
}

build_apk arm64-v8a   android-arm64
build_apk armeabi-v7a android-arm
build_apk x86_64      android-x64

# --- Windows -----------------------------------------------------------------
if [[ "${1:-}" != "--skip-windows" ]]; then
  echo "==> windows x64"
  ( cd "$ROOT/flutter" && flutter build windows --release --no-pub )
  win_dir="$ROOT/flutter/build/windows/x64/runner/Release"
  out_zip="$(cygpath -w "$DIST/$NAME-windows-x64.zip")"
  # No `zip` in a stock Git Bash; PowerShell is always there on Windows.
  powershell -NoProfile -Command     "Compress-Archive -Force -Path '$(cygpath -w "$win_dir")\*' -DestinationPath '$out_zip'"
  echo "    $DIST/$NAME-windows-x64.zip"
fi

echo
echo "artifacts in dist/:"
ls -la "$DIST" | tail -n +2
