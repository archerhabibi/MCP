#!/usr/bin/env bash
# Server MCP Manager uninstaller for Ubuntu/Debian.
# Removes the MCP service, its dedicated Cloudflare Tunnel service and all files.
# It does NOT touch any other cloudflared.service or the cloudflared package.
set -Eeuo pipefail

APP_DIR="/opt/server-mcp"
ETC_DIR="/etc/server-mcp"
LOG_DIR="/var/log/server-mcp"
SERVICE_NAME="server-mcp"
TUNNEL_SERVICE_NAME="server-mcp-tunnel"

[[ "${EUID}" -eq 0 ]] || { echo "[ERROR] Run as root: sudo bash uninstall-server-mcp.sh" >&2; exit 1; }

echo "This will remove Server MCP Manager (services, ${APP_DIR}, ${ETC_DIR})."
read -r -p "Continue? [y/N]: " answer
[[ "$answer" =~ ^[Yy]$ ]] || { echo "Cancelled."; exit 0; }

for svc in "$SERVICE_NAME" "$TUNNEL_SERVICE_NAME"; do
  systemctl disable --now "$svc" 2>/dev/null || true
  rm -f "/etc/systemd/system/${svc}.service"
done
systemctl daemon-reload

rm -rf "$APP_DIR" "$ETC_DIR"

read -r -p "Also delete the audit log in ${LOG_DIR}? [y/N]: " logs
if [[ "$logs" =~ ^[Yy]$ ]]; then
  rm -rf "$LOG_DIR"
fi

echo "Done. Remember to delete the tunnel/hostname in the Cloudflare dashboard"
echo "and treat the old MCP token as revoked."
