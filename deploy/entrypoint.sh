#!/bin/sh
# Picks the matching prebuilt binary so one image works on both architectures
# without relying on build args, which classic (non-BuildKit) builders never
# set — a missing TARGETARCH would silently produce a broken image.
set -e

case "$(uname -m)" in
  x86_64 | amd64) BIN=/app/bin/courseplanner-server-linux-amd64 ;;
  aarch64 | arm64) BIN=/app/bin/courseplanner-server-linux-arm64 ;;
  *)
    echo "courseplanner: unsupported architecture: $(uname -m)" >&2
    exit 1
    ;;
esac

exec "$BIN" "$@"
