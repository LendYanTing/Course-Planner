#!/usr/bin/env bash
# Post-deploy smoke test. Uses only curl and POSIX text tools so it runs on a
# bare server with nothing installed.
#
#   ./scripts/smoke.sh                                    # against localhost:8080
#   ./scripts/smoke.sh https://cp.example.com             # liveness + contract
#   ./scripts/smoke.sh https://cp.example.com cpmcp_...   # + MCP tool listing
#
# Exit status is 0 only when every check passes.
set -uo pipefail

BASE="${1:-http://127.0.0.1:8080}"
TOKEN="${2:-${CP_TOKEN:-}}"
BASE="${BASE%/}"
case "$BASE" in
  */api/v1) API="$BASE" ;;
  *) API="$BASE/api/v1" ;;
esac

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required" >&2
  exit 1
fi

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
note() { printf '        %s\n' "$1"; }

echo "smoke: $BASE"
echo

# 1. liveness ----------------------------------------------------------------
BODY="$(curl -fsS -m 10 "$BASE/healthz" 2>/dev/null || true)"
case "$BODY" in
  *'"status":"ok"'*) ok "GET /healthz" ;;
  *) bad "GET /healthz"; note "got: ${BODY:-<no response>}" ;;
esac

# 2. contract (touches the real request path, unlike /healthz) -----------------
BODY="$(curl -fsS -m 10 "$API/meta/time" 2>/dev/null || true)"
case "$BODY" in
  *serverTimeUtc*) ok "GET $API/meta/time" ;;
  *) bad "GET $API/meta/time"; note "got: ${BODY:-<no response>}" ;;
esac

# 3. auth boundary: an anonymous read must be refused -------------------------
CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 "$API/todos")"
if [ "$CODE" = "401" ]; then
  ok "GET $API/todos is 401 without a token"
else
  bad "GET $API/todos is 401 without a token"
  note "got HTTP $CODE (a 200 here would mean unauthenticated data exposure)"
fi

# 4. MCP transport: POST-only, no SSE stream ---------------------------------
# Authenticated on purpose: an anonymous GET stops at the auth wall with 401,
# so the 405 can only be observed with a credential (that 401 is itself the
# correct answer, and check 3 already covers the auth wall).
if [ -n "$TOKEN" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Authorization: Bearer $TOKEN" "$API/mcp")"
  if [ "$CODE" = "405" ]; then
    ok "GET $API/mcp is 405 with a token (POST-only, no SSE stream)"
  else
    bad "GET $API/mcp is 405 with a token"
    note "got HTTP $CODE — expected 405; a client configured for sse will fail"
  fi
fi

# 5. MCP tool surface (needs a token) -----------------------------------------
if [ -n "$TOKEN" ]; then
  BODY="$(curl -fsS -m 20 -X POST "$API/mcp" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $TOKEN" \
    -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' 2>/dev/null || true)"
  if printf '%s' "$BODY" | grep -q '"tools"'; then
    COUNT="$(printf '%s' "$BODY" | grep -o '"inputSchema"' | wc -l | tr -d ' ')"
    ok "POST $API/mcp tools/list ($COUNT tools)"
    if [ "$COUNT" -ge 24 ]; then
      ok "tool count is >= 24"
    else
      bad "tool count is >= 24"
      note "got $COUNT — the registry looks incomplete"
    fi
  else
    bad "POST $API/mcp tools/list"
    note "got: ${BODY:-<no response>} (401 means the token is wrong or revoked)"
  fi
else
  note "no token given: skipping the MCP checks"
  note "pass one as the 2nd argument, or set CP_TOKEN"
fi

echo
echo "passed $PASS, failed $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
