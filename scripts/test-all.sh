#!/usr/bin/env bash
# Run the full server test suite: vet + unit tests + integration tests.
# Integration tests require a PostgreSQL reachable via TEST_DATABASE_URL
# (schema is wiped and re-migrated on each run).
# Usage: TEST_DATABASE_URL=postgres://... scripts/test-all.sh
set -euo pipefail
cd "$(dirname "$0")/../server"

echo "==> go vet ./..."
go vet ./...

echo "==> unit tests ./internal/..."
go test ./internal/... -count=1

echo "==> integration tests ./tests/..."
: "${TEST_DATABASE_URL:=postgres://courseplanner:courseplanner@localhost:5433/courseplanner_test?sslmode=disable}"
export TEST_DATABASE_URL
go test ./tests/ -count=1 -v

echo "==> all tests green"
