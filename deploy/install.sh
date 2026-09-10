#!/usr/bin/env bash
# Bare-metal installer for the Course Planner backend (docs/deploy.md §5).
# Idempotent: re-running upgrades the binary and leaves an existing
# server.env untouched.
#
#   sudo ./deploy/install.sh
#   sudo ./deploy/install.sh --database-url 'postgres://user:pw@127.0.0.1:5432/courseplanner?sslmode=disable'
#
# Run it from the root of the extracted release directory.
set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_ROOT=/opt/courseplanner
CONFIG_DIR=/etc/courseplanner
ENV_FILE="$CONFIG_DIR/server.env"
SERVICE=courseplanner
DATABASE_URL_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --database-url) DATABASE_URL_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "must run as root (use sudo)" >&2
  exit 1
fi

case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

BINARY="$BUNDLE_DIR/bin/courseplanner-server-linux-$ARCH"
if [ ! -f "$BINARY" ]; then
  echo "missing $BINARY — run this from the extracted release directory" >&2
  exit 1
fi

echo "==> architecture: $ARCH"
echo "==> installing to $INSTALL_ROOT"

# --- user & directories -------------------------------------------------------
if ! id -u "$SERVICE" >/dev/null 2>&1; then
  echo "==> creating system user $SERVICE"
  useradd --system --home-dir "$INSTALL_ROOT" --shell /usr/sbin/nologin "$SERVICE" 2>/dev/null \
    || adduser --system --home "$INSTALL_ROOT" --shell /sbin/nologin "$SERVICE"
fi
install -d -m 0755 "$INSTALL_ROOT" "$INSTALL_ROOT/bin" /var/lib/courseplanner
install -m 0755 "$BINARY" "$INSTALL_ROOT/bin/courseplanner-server"
chown -R "$SERVICE:$SERVICE" /var/lib/courseplanner

# --- configuration ------------------------------------------------------------
install -d -m 0750 "$CONFIG_DIR"
if [ -f "$ENV_FILE" ]; then
  echo "==> keeping existing $ENV_FILE"
else
  echo "==> writing $ENV_FILE"
  install -m 0600 "$BUNDLE_DIR/env.example" "$ENV_FILE"
  JWT_SECRET="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  PG_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n' | cut -c1-32)"
  sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_SECRET}|" "$ENV_FILE"
  sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PASSWORD}|" "$ENV_FILE"
  if [ -n "$DATABASE_URL_OVERRIDE" ]; then
    printf 'DATABASE_URL=%s\n' "$DATABASE_URL_OVERRIDE" >> "$ENV_FILE"
  else
    printf '# DATABASE_URL=postgres://courseplanner:PASSWORD@127.0.0.1:5432/courseplanner?sslmode=disable\n' >> "$ENV_FILE"
  fi
  chown root:"$SERVICE" "$ENV_FILE"
fi

if ! grep -q '^DATABASE_URL=' "$ENV_FILE"; then
  echo
  echo "!! $ENV_FILE has no active DATABASE_URL."
  echo "   Fill it in (and create the database/user) before starting, e.g.:"
  echo "     sudo -u postgres psql -c \"CREATE USER courseplanner WITH PASSWORD '<pw>';\""
  echo "     sudo -u postgres psql -c \"CREATE DATABASE courseplanner OWNER courseplanner;\""
  echo "     sudo editor $ENV_FILE"
  echo
fi

# --- systemd ------------------------------------------------------------------
echo "==> installing systemd unit"
install -m 0644 "$BUNDLE_DIR/deploy/$SERVICE.service" "/etc/systemd/system/$SERVICE.service"
systemctl daemon-reload
systemctl enable "$SERVICE"
if grep -q '^DATABASE_URL=' "$ENV_FILE"; then
  systemctl restart "$SERVICE"
  sleep 1
  systemctl is-active --quiet "$SERVICE" \
    && echo "==> $SERVICE is running" \
    || { echo "!! $SERVICE failed to start:" >&2; journalctl -u "$SERVICE" -n 30 --no-pager >&2; exit 1; }
else
  echo "==> not starting yet: configure DATABASE_URL first, then:"
  echo "     sudo systemctl start $SERVICE"
fi

cat <<EOF

Next steps
  1. put a TLS edge in front of 127.0.0.1:8080 (deploy/Caddyfile or deploy/nginx.conf)
  2. curl https://<your-domain>/healthz
  3. register the first account (timezone is locked forever):
     curl -sX POST https://<your-domain>/api/v1/auth/register \\
       -H 'Content-Type: application/json' \\
       -d '{"username":"alice","password":"<strong>","timezone":"Asia/Shanghai"}'
  4. open https://<your-domain>/mcp/connect to mint an MCP token
  logs: journalctl -u $SERVICE -f
EOF
