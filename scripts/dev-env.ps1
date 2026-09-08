# Source this file in a pwsh session to set up the Go toolchain:
#   . ./scripts/dev-env.ps1
# It uses the repo-local Go toolchain in .tools/ when present, so it works
# on machines where Go is not installed system-wide.
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
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
# This dev box reaches the internet through a local proxy (see system settings).
if (-not $env:HTTPS_PROXY) { $env:HTTPS_PROXY = "http://127.0.0.1:7890" }
if (-not $env:HTTP_PROXY) { $env:HTTP_PROXY = "http://127.0.0.1:7890" }
Write-Host "go: $(go version)"
