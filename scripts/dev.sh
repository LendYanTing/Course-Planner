#!/usr/bin/env bash
# Start the whole dev stack: postgres (docker compose) + Go server.
# Usage: scripts/dev.sh [server-extra-args...]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then
  set -a; source .env; set +a
fi

: "${DATABASE_URL:=postgres://courseplanner:courseplanner@localhost:5433/courseplanner?sslmode=disable}"
: "${JWT_SECRET:=dev-only-secret-change-me}"
: "${PORT:=8080}"

docker compose up -d postgres

export DATABASE_URL JWT_SECRET PORT COOKIE_SECURE="${COOKIE_SECURE:-false}"
echo "DATABASE_URL=$DATABASE_URL"
echo "listening :$PORT"
cd server
go run ./cmd/server "$@"
