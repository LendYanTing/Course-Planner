#!/usr/bin/env bash
# Backs up the Course Planner database with pg_dump, gzipped, into backups/.
#
#   ./scripts/backup-db.sh                 # docker compose stack (default)
#   ./scripts/backup-db.sh --local         # bare metal: uses DATABASE_URL
#   ./scripts/backup-db.sh --keep 30       # keep the newest 30 dumps (default 14)
#
# Restore (docker):
#   gunzip -c backups/courseplanner-<stamp>.sql.gz \
#     | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
set -euo pipefail

MODE=docker
KEEP=14
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/backups"

while [ $# -gt 0 ]; do
  case "$1" in
    --local) MODE=local; shift ;;
    --docker) MODE=docker; shift ;;
    --keep) KEEP="${2:-14}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$OUT_DIR/courseplanner-$STAMP.sql.gz"

if [ "$MODE" = docker ]; then
  if [ ! -f .env ]; then
    echo "no .env here; run from the release root or use --local" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  set -a; . ./.env; set +a
  : "${POSTGRES_USER:?POSTGRES_USER missing from .env}"
  : "${POSTGRES_DB:?POSTGRES_DB missing from .env}"
  echo "==> pg_dump via docker compose (db=$POSTGRES_DB)"
  docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists \
    | gzip -9 > "$DEST"
else
  ENV_FILE="${ENV_FILE:-/etc/courseplanner/server.env}"
  if [ -z "${DATABASE_URL:-}" ] && [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    set -a; . "$ENV_FILE"; set +a
  fi
  : "${DATABASE_URL:?set DATABASE_URL or point ENV_FILE at /etc/courseplanner/server.env}"
  echo "==> pg_dump via local pg_dump"
  pg_dump --dbname="$DATABASE_URL" --clean --if-exists | gzip -9 > "$DEST"
fi

SIZE="$(du -h "$DEST" | cut -f1)"
echo "==> wrote $DEST ($SIZE)"

if [ "$KEEP" -gt 0 ]; then
  # Delete all but the newest $KEEP dumps.
  ls -1t "$OUT_DIR"/courseplanner-*.sql.gz 2>/dev/null | tail -n +$((KEEP + 1)) | while read -r old; do
    echo "==> pruning $old"
    rm -f "$old"
  done
fi

echo "==> copy this file off the server; a backup on the same disk is not a backup"
