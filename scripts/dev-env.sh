#!/usr/bin/env bash
# Source this file to set up every toolchain this repo needs:
#   source scripts/dev-env.sh
#
# Bash mirror of scripts/dev-env.ps1 — keep the two in step. Everything lives
# inside the repo (.tools/) and every cache stays there too, so the project is
# self-contained. Nothing is written to your user environment.
#
# Deliberately no `set -euo pipefail`: this file is sourced into the caller's
# shell, and those flags would leak into it.

_repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# --- Flutter / Dart ---------------------------------------------------------
# The pinned SDK (flutter/README.md). Placed ahead of any system Flutter so that
# `flutter` and `dart` mean this repo's version.
if [ -x "$_repo_root/.tools/flutter/bin/flutter" ]; then
  export FLUTTER_ROOT="$_repo_root/.tools/flutter"
  export PATH="$FLUTTER_ROOT/bin:$PATH"
fi
# Load-bearing, not tidiness: pub must resolve into the repo-local cache. With
# the default cache on another drive the Android release build dies in Kotlin's
# incremental compiler ("this and base files have different roots").
export PUB_CACHE="$_repo_root/.tools/pub-cache"
# Host VM tests load sqlite3.dll from PATH (sqlite3 3.x auto-loader).
if [ -d "$_repo_root/.tools/sqlite3" ]; then
  export PATH="$_repo_root/.tools/sqlite3:$PATH"
fi
# NOTE: no HTTP_PROXY/HTTPS_PROXY here on purpose. This box egresses through the
# Clash TUN adapter ("Meta Tunnel"), which takes over the default route, so
# per-tool proxy variables are unnecessary — and a stale one sends otherwise
# working requests into a dead port.

# --- Go --------------------------------------------------------------------
if [ -x "$_repo_root/.tools/go/bin/go" ]; then
  export GOROOT="$_repo_root/.tools/go"
  export PATH="$GOROOT/bin:$PATH"
fi
# Keep all Go caches inside the repo (sandbox-friendly, self-contained).
export GOPATH="$_repo_root/.tools/gopath"
export GOCACHE="$_repo_root/.tools/gocache"
export GOMODCACHE="$GOPATH/pkg/mod"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=mod

echo "flutter:  $(command -v flutter || echo '<not found>')"
echo "go:       $(command -v go || echo '<not found>')"
echo "pub:      $PUB_CACHE"