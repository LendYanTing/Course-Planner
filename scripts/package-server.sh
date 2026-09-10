#!/usr/bin/env bash
# Builds the deployable Linux bundle: dist/courseplanner-server-<version>-linux.tar.gz
#
#   ./scripts/package-server.sh
#   VERSION=1.2.0 ./scripts/package-server.sh      # override the version
#
# Contents (one top-level directory, so extracting never scatters files):
#
#   README.md              the deployment guide (docs/deploy.md)
#   VERSION
#   env.example            copy to .env, then scripts/gen-secrets.sh --write .env
#   docker-compose.yml     recommended path (PostgreSQL + backend)
#   Dockerfile             builds an image from the prebuilt binary
#   entrypoint.sh          picks the arch at container start
#   bin/                   statically linked linux/amd64 + linux/arm64 binaries
#   deploy/                systemd unit, Caddyfile, nginx.conf, install.sh
#   scripts/               gen-secrets.sh, backup-db.sh, smoke.sh
#   SHA256SUMS
#
# The binaries are static (CGO_ENABLED=0) with zoneinfo embedded, so the target
# needs neither a Go toolchain nor tzdata installed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

GO_BIN="${GO_BIN:-}"
if [ -z "$GO_BIN" ]; then
  if command -v go >/dev/null 2>&1; then
    GO_BIN=go
  elif [ -x "$REPO_ROOT/.tools/go/bin/go" ]; then
    GO_BIN="$REPO_ROOT/.tools/go/bin/go"
  else
    echo "no go toolchain found (set GO_BIN=/path/to/go)" >&2
    exit 1
  fi
fi

# The version the MCP server reports to clients is the meaningful server
# version; keep one source of truth rather than a VERSION file that can drift.
VERSION="${VERSION:-$(grep -oE 'serverVersion = "[^"]+"' server/internal/mcp/server.go \
  | head -1 | sed -E 's/.*"([^"]+)".*/\1/')}"
[ -n "$VERSION" ] || { echo "cannot determine version (set VERSION=x.y.z)" >&2; exit 1; }

NAME="courseplanner-server-${VERSION}-linux"
STAGE="$REPO_ROOT/.tools/dist/$NAME"
DIST="$REPO_ROOT/dist"

echo "==> packaging $NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE/bin" "$STAGE/deploy" "$STAGE/scripts" "$DIST"

# --- binaries ----------------------------------------------------------------
export GOCACHE="${GOCACHE:-$REPO_ROOT/.tools/gocache}"
export GOPATH="${GOPATH:-$REPO_ROOT/.tools/gopath}"
export GOFLAGS="${GOFLAGS:--mod=mod}"
export CGO_ENABLED=0

for arch in amd64 arm64; do
  echo "==> building linux/$arch"
  ( cd server && GOOS=linux GOARCH="$arch" "$GO_BIN" build \
      -trimpath -ldflags="-s -w" \
      -o "$STAGE/bin/courseplanner-server-linux-$arch" ./cmd/server )
done

# --- payload -----------------------------------------------------------------
# deploy/<file> maps to the bundle path in the third column.
install -m 0644 docs/deploy.md        "$STAGE/README.md"
install -m 0644 deploy/docker-compose.yml "$STAGE/docker-compose.yml"
install -m 0644 deploy/Dockerfile     "$STAGE/Dockerfile"
install -m 0755 deploy/entrypoint.sh  "$STAGE/entrypoint.sh"
install -m 0600 deploy/env.example    "$STAGE/env.example"

install -m 0644 deploy/courseplanner.service "$STAGE/deploy/courseplanner.service"
install -m 0644 deploy/Caddyfile      "$STAGE/deploy/Caddyfile"
install -m 0644 deploy/nginx.conf     "$STAGE/deploy/nginx.conf"
install -m 0755 deploy/install.sh     "$STAGE/deploy/install.sh"

install -m 0755 deploy/gen-secrets.sh "$STAGE/scripts/gen-secrets.sh"
install -m 0755 deploy/backup-db.sh   "$STAGE/scripts/backup-db.sh"
install -m 0755 deploy/smoke.sh       "$STAGE/scripts/smoke.sh"

# --- version & checksums -----------------------------------------------------
printf '%s\n' "$VERSION" > "$STAGE/VERSION"
printf 'built %s from %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" \
  >> "$STAGE/VERSION"

echo "==> checksums"
( cd "$STAGE" && find . -type f ! -name SHA256SUMS -printf '%P\n' 2>/dev/null | sort \
    | xargs -r sha256sum > SHA256SUMS )
if [ ! -s "$STAGE/SHA256SUMS" ]; then
  # find -printf is GNU-only; fall back to a portable listing.
  ( cd "$STAGE" && find . -type f ! -name SHA256SUMS | sed 's|^\./||' | LC_ALL=C sort \
      | xargs -r sha256sum > SHA256SUMS )
fi

# --- archive -----------------------------------------------------------------
# A Windows host has no unix permission bits — chmod is a silent no-op there for
# files without an extension — so the modes are stamped into the archive rather
# than trusted from the staging directory. Building the tar uncompressed first is
# what lets the two passes use different --mode values.
PLAIN="$DIST/$NAME.tar"
TARBALL="$DIST/$NAME.tar.gz"
echo "==> archiving $TARBALL"
rm -f "$PLAIN" "$TARBALL"

tar -cf "$PLAIN" --mode=0755 -C "$(dirname "$STAGE")" \
  "$NAME/bin" "$NAME/entrypoint.sh" "$NAME/deploy/install.sh" "$NAME/scripts"
tar -rf "$PLAIN" --mode=0644 -C "$(dirname "$STAGE")" \
  "$NAME/README.md" "$NAME/VERSION" "$NAME/env.example" \
  "$NAME/docker-compose.yml" "$NAME/Dockerfile" \
  "$NAME/deploy/Caddyfile" "$NAME/deploy/nginx.conf" "$NAME/deploy/courseplanner.service" \
  "$NAME/SHA256SUMS"
gzip -9 -c "$PLAIN" > "$TARBALL"
rm -f "$PLAIN"

# The archive is the deliverable, so verify what it actually recorded. The
# directory listing is the authoritative view and ignores the build host.
echo "==> verifying archive"
MODE_LIST="$(tar -tvzf "$TARBALL" | awk '{print $1, $NF}')"
BAD=0
for want in \
  "$NAME/bin/courseplanner-server-linux-amd64:-rwxr-xr-x" \
  "$NAME/bin/courseplanner-server-linux-arm64:-rwxr-xr-x" \
  "$NAME/entrypoint.sh:-rwxr-xr-x" \
  "$NAME/deploy/install.sh:-rwxr-xr-x" \
  "$NAME/scripts/gen-secrets.sh:-rwxr-xr-x" \
  "$NAME/scripts/backup-db.sh:-rwxr-xr-x" \
  "$NAME/scripts/smoke.sh:-rwxr-xr-x" \
  "$NAME/env.example:-rw-r--r--" \
  "$NAME/README.md:-rw-r--r--"
do
  file="${want%:*}"
  mode="${want##*:}"
  got="$(printf '%s\n' "$MODE_LIST" | awk -v f="$file" '$2 == f {print $1}')"
  if [ "$got" != "$mode" ]; then
    echo "!! $file is ${got:-missing}, expected $mode" >&2
    BAD=1
  fi
done
[ "$BAD" -eq 0 ] || { echo "refusing to ship a bundle with wrong permissions" >&2; exit 1; }
echo "    7 executables are 0755, documents are 0644"

echo
echo "bundle:  $TARBALL"
echo "size:    $(du -h "$TARBALL" | cut -f1)"
echo "sha256:  $(sha256sum "$TARBALL" | cut -d' ' -f1)"
echo
echo "upload and unpack with:"
echo "  scp $TARBALL you@server:/tmp/"
echo "  ssh you@server 'tar -xzf /tmp/$NAME.tar.gz && cd $NAME && cat README.md'"
