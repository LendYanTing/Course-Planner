#!/usr/bin/env bash
# Generates the two secrets that must not be reused from a development box:
# JWT_SECRET and the PostgreSQL password.
#
#   ./scripts/gen-secrets.sh                  # print them
#   ./scripts/gen-secrets.sh --write .env     # replace the values in place
#
# Values are hex/alphanumeric on purpose: the PostgreSQL password ends up inside
# a DATABASE_URL, where an "@", ":" or "/" would silently break parsing.
set -euo pipefail

TARGET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --write) TARGET="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# 32 random bytes as hex; no SIGPIPE-prone `tr | head` pipeline under pipefail.
RAW="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
JWT_SECRET="$RAW"
PG_PASSWORD="$(printf '%s' "$RAW" | cut -c1-32)"

if [ -z "$TARGET" ]; then
  echo "JWT_SECRET=$JWT_SECRET"
  echo "POSTGRES_PASSWORD=$PG_PASSWORD"
  echo
  echo "Write them with: $0 --write .env"
  exit 0
fi

if [ ! -f "$TARGET" ]; then
  echo "no such file: $TARGET (copy env.example to it first)" >&2
  exit 1
fi

# Only hex/alphanumeric values are ever substituted, so no escaping is needed.
sed -i.bak "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$TARGET"
sed -i.bak "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASSWORD}|" "$TARGET"
rm -f "$TARGET.bak"

grep -q '^JWT_SECRET=' "$TARGET" || printf 'JWT_SECRET=%s\n' "$JWT_SECRET" >> "$TARGET"
grep -q '^POSTGRES_PASSWORD=' "$TARGET" || printf 'POSTGRES_PASSWORD=%s\n' "$PG_PASSWORD" >> "$TARGET"

chmod 600 "$TARGET" 2>/dev/null || true
echo "wrote JWT_SECRET and POSTGRES_PASSWORD to $TARGET (mode 600)"
echo "keep a copy of POSTGRES_PASSWORD: the database is initialised with it on first start"
