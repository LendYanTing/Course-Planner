# Source this file in a pwsh session to set up every toolchain this repo needs:
#   . ./scripts/dev-env.ps1
#
# Everything lives inside the repo (.tools/) and every cache stays there too, so
# the project is self-contained: it works on a machine where Flutter/Go are not
# installed system-wide, and it does not care which versions are on PATH.
# Nothing is written to the user or machine environment — source it per session,
# or point your editor's workspace settings at it.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)

# --- Flutter / Dart ---------------------------------------------------------
# The pinned SDK (flutter/README.md). Placed ahead of any system Flutter so that
# `flutter` and `dart` mean this repo's version.
$flutterDir = Join-Path $repoRoot ".tools\flutter"
if (Test-Path (Join-Path $flutterDir "bin\flutter.bat")) {
  $env:FLUTTER_ROOT = $flutterDir
  $env:PATH = "$flutterDir\bin;$env:PATH"
}
# Load-bearing, not tidiness: pub must resolve into the repo-local cache. With
# the default cache on another drive the Android release build dies in Kotlin's
# incremental compiler ("this and base files have different roots").
$env:PUB_CACHE = Join-Path $repoRoot ".tools\pub-cache"
# Host VM tests load sqlite3.dll from PATH (sqlite3 3.x auto-loader).
$sqliteDir = Join-Path $repoRoot ".tools\sqlite3"
if (Test-Path $sqliteDir) { $env:PATH = "$sqliteDir;$env:PATH" }
# NOTE: no HTTP_PROXY/HTTPS_PROXY here on purpose. This box egresses through the
# Clash TUN adapter ("Meta Tunnel"), which takes over the default route, so
# per-tool proxy variables are unnecessary — and a stale one (the old
# 127.0.0.1:7890) sends otherwise-working requests into a dead port.

# --- Go --------------------------------------------------------------------
$goDir = Join-Path $repoRoot ".tools\go"
if (Test-Path (Join-Path $goDir "bin\go.exe")) {
  $env:GOROOT = $goDir
  $env:PATH = "$goDir\bin;$env:PATH"
}
# Keep all Go caches inside the repo (sandbox-friendly, self-contained).
$env:GOPATH = Join-Path $repoRoot ".tools\gopath"
$env:GOCACHE = Join-Path $repoRoot ".tools\gocache"
$env:GOMODCACHE = Join-Path $env:GOPATH "pkg\mod"
$env:GOTOOLCHAIN = "local"
$env:GOFLAGS = "-mod=mod"

Write-Host "flutter:  $(flutter --version 2>$null | Select-Object -First 1)"
Write-Host "go:       $(go version)"
Write-Host "pub:      $env:PUB_CACHE"
