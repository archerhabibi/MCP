#!/usr/bin/env bash
# Server MCP Manager installer for Ubuntu/Debian (fixed: mcp<2 pin, loopback bind, transport_security in constructor)
# Installs an independently authenticated MCP server and a dedicated Cloudflare Tunnel service.
set -Eeuo pipefail
umask 077

APP_DIR="/opt/server-mcp"
ETC_DIR="/etc/server-mcp"
LOG_DIR="/var/log/server-mcp"
SERVICE_NAME="server-mcp"
TUNNEL_SERVICE_NAME="server-mcp-tunnel"
PYTHON_BIN="/usr/bin/python3"
BIND_HOST="127.0.0.1"
BIND_PORT="8008"

log() { printf '\n[server-mcp] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || die "Run this installer as root: sudo bash install-server-mcp.sh"
[[ -r /etc/os-release ]] || die "Cannot identify operating system."
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *) die "Supported operating systems: Ubuntu and Debian. Detected: ${ID:-unknown}" ;;
esac

command -v systemctl >/dev/null 2>&1 || die "systemd is required."
command -v apt-get >/dev/null 2>&1 || die "apt-get is required."

echo "=== Server MCP Manager installer ==="
echo "This installs a root-level remote administration MCP server."
echo "Use a separate Cloudflare Tunnel and a separate MCP token for each server."
echo

HOSTNAME_IN=""
TUNNEL_TOKEN=""
MCP_TOKEN=""
REUSE=0

if [[ -r "$ETC_DIR/server.env" && -r "$ETC_DIR/tunnel.env" ]]; then
  read -r -p "Existing installation found. Reuse hostname and tokens? [Y/n]: " reuse_answer
  if [[ ! "$reuse_answer" =~ ^[Nn]$ ]]; then
    HOSTNAME_IN="$(sed -n 's/^MCP_PUBLIC_HOSTNAME=//p' "$ETC_DIR/server.env")"
    MCP_TOKEN="$(sed -n 's/^MCP_ACCESS_TOKEN=//p' "$ETC_DIR/server.env")"
    TUNNEL_TOKEN="$(sed -n 's/^TUNNEL_TOKEN=//p' "$ETC_DIR/tunnel.env")"
    [[ -n "$HOSTNAME_IN" && -n "$MCP_TOKEN" && -n "$TUNNEL_TOKEN" ]] || die "Existing env files are incomplete. Re-run and answer 'n'."
    REUSE=1
  fi
fi

if [[ "$REUSE" -eq 0 ]]; then
  read -r -p "Public hostname for THIS server (example: srv1-mcp.example.com): " HOSTNAME_IN
  [[ "$HOSTNAME_IN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid hostname."
  [[ "$HOSTNAME_IN" == *.* ]] || die "Enter a fully qualified hostname."

  read -r -s -p "Cloudflare Tunnel token for THIS server: " TUNNEL_TOKEN
  echo
  [[ -n "$TUNNEL_TOKEN" ]] || die "Cloudflare Tunnel token is required."

  read -r -s -p "MCP access token (leave empty to generate one, or paste one, min 40 chars): " MCP_TOKEN
  echo
  if [[ -z "$MCP_TOKEN" ]]; then
    MCP_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
  fi
  [[ ${#MCP_TOKEN} -ge 40 ]] || die "MCP token must be at least 40 characters."

  if systemctl is-active --quiet cloudflared.service; then
    echo
    echo "A cloudflared.service is already active."
    echo "This installer will NOT replace or stop it."
    read -r -p "Continue and install a separate server-mcp-tunnel.service? [y/N]: " answer
    [[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled. Resolve the existing tunnel setup first."
  fi
fi

log "Installing system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y python3 python3-venv python3-pip curl ca-certificates gnupg openssl

if ! command -v cloudflared >/dev/null 2>&1; then
  log "Installing cloudflared from Cloudflare's package repository..."
  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
    -o /usr/share/keyrings/cloudflare-main.gpg
  chmod 0644 /usr/share/keyrings/cloudflare-main.gpg
  printf '%s\n' \
    "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main" \
    > /etc/apt/sources.list.d/cloudflared.list
  apt-get update -y
  apt-get install -y cloudflared
else
  log "cloudflared already installed, skipping."
fi

log "Creating application directories..."
install -d -m 0750 "$APP_DIR" "$ETC_DIR"
install -d -m 0750 "$LOG_DIR"

log "Creating Python virtual environment..."
"$PYTHON_BIN" -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install --upgrade pip
# IMPORTANT: mcp 2.x removed FastMCP, so pin to the 1.x series.
"$APP_DIR/venv/bin/pip" install --upgrade "mcp>=1.10,<2" uvicorn psutil

log "Writing MCP server..."
cat > "$APP_DIR/server.py" <<'PYCODE'
import os
import sys
import json
import time
import hmac
import hashlib
import logging
import subprocess
import platform
from pathlib import Path
from datetime import datetime, timezone

import psutil
import uvicorn
from mcp.server.fastmcp import FastMCP
from mcp.server.transport_security import TransportSecuritySettings

TOKEN = os.environ.get("MCP_ACCESS_TOKEN", "")
PORT = int(os.environ.get("MCP_PORT", "8008"))
HOST = os.environ.get("MCP_BIND_HOST", "127.0.0.1")
PUBLIC_HOSTNAME = os.environ.get("MCP_PUBLIC_HOSTNAME", "").strip()
AUDIT_FILE = Path("/var/log/server-mcp/audit.jsonl")

if len(TOKEN) < 40:
    raise RuntimeError("MCP_ACCESS_TOKEN must be at least 40 characters")
if not PUBLIC_HOSTNAME:
    raise RuntimeError("MCP_PUBLIC_HOSTNAME is required")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
logger = logging.getLogger("server-mcp")

def audit(event: str, details: dict):
    record = {
        "time": datetime.now(timezone.utc).isoformat(),
        "event": event,
        "details": details,
    }
    try:
        AUDIT_FILE.parent.mkdir(parents=True, exist_ok=True)
        with AUDIT_FILE.open("a", encoding="utf-8") as f:
            f.write(json.dumps(record, ensure_ascii=False, default=str) + "\n")
    except Exception as exc:
        logger.error("Audit write failed: %s", exc)

class SecretPathMiddleware:
    """The access token is the first URL path segment: https://host/<TOKEN>/mcp
    Requests without the correct first segment get a plain 404. The token is
    stripped before the request reaches the MCP app, which serves /mcp."""
    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            return await self.app(scope, receive, send)
        path = scope.get("path", "") or ""
        stripped = path[1:] if path.startswith("/") else path
        first, sep, rest = stripped.partition("/")
        if hmac.compare_digest(first.encode(), TOKEN.encode()):
            new_path = "/" + rest
            scope = dict(scope)
            scope["path"] = new_path
            scope["raw_path"] = new_path.encode()
            return await self.app(scope, receive, send)
        body = b"Not Found"
        await send({
            "type": "http.response.start",
            "status": 404,
            "headers": [
                (b"content-type", b"text/plain"),
                (b"content-length", str(len(body)).encode()),
            ],
        })
        await send({"type": "http.response.body", "body": body})
        audit("auth_rejected", {"client": (scope.get("client") or [None])[0]})

# In mcp 1.x, transport security is passed to the FastMCP constructor.
security = TransportSecuritySettings(
    enable_dns_rebinding_protection=True,
    allowed_hosts=[
        PUBLIC_HOSTNAME,
        PUBLIC_HOSTNAME + ":*",
        "127.0.0.1:*",
        "localhost:*",
    ],
    allowed_origins=[
        "https://" + PUBLIC_HOSTNAME,
        "http://127.0.0.1:*",
        "http://localhost:*",
    ],
)

mcp = FastMCP("Independent Server Manager", transport_security=security)

@mcp.tool()
def hello() -> str:
    """Check that this server's MCP endpoint is working."""
    return "Server MCP Manager is online."

@mcp.tool()
def get_system_info() -> dict:
    """Return hostname, OS, uptime, CPU, memory, disk and load information."""
    boot = psutil.boot_time()
    disk = psutil.disk_usage("/")
    vm = psutil.virtual_memory()
    info = {
        "hostname": platform.node(),
        "os": platform.platform(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "python": sys.version.split()[0],
        "uptime_seconds": int(time.time() - boot),
        "cpu_count": psutil.cpu_count(),
        "cpu_percent": psutil.cpu_percent(interval=0.5),
        "memory": {
            "total_bytes": vm.total,
            "available_bytes": vm.available,
            "percent_used": vm.percent,
        },
        "root_disk": {
            "total_bytes": disk.total,
            "used_bytes": disk.used,
            "free_bytes": disk.free,
            "percent_used": disk.percent,
        },
        "load_average": os.getloadavg() if hasattr(os, "getloadavg") else None,
    }
    audit("system_info", {"hostname": info["hostname"]})
    return info

@mcp.tool()
def run_command(command: str, timeout_seconds: int = 300) -> dict:
    """
    Run an arbitrary Bash command as root on THIS server.
    This is full administrative access. Never expose the MCP token.
    Timeout is limited to 1..3600 seconds.
    """
    if not command or not command.strip():
        raise ValueError("Command cannot be empty")
    timeout_seconds = max(1, min(int(timeout_seconds), 3600))
    started = time.time()
    try:
        result = subprocess.run(
            ["/bin/bash", "-lc", command],
            capture_output=True,
            text=True,
            timeout=timeout_seconds,
            cwd="/",
            env=os.environ.copy(),
        )
        output = {
            "return_code": result.returncode,
            "stdout": result.stdout[-50000:],
            "stderr": result.stderr[-20000:],
            "duration_seconds": round(time.time() - started, 3),
            "timed_out": False,
        }
        audit("run_command", {
            "command_sha256": hashlib.sha256(command.encode()).hexdigest(),
            "command_preview": command[:300],
            "return_code": result.returncode,
            "duration_seconds": output["duration_seconds"],
        })
        return output
    except subprocess.TimeoutExpired as exc:
        audit("run_command_timeout", {
            "command_sha256": hashlib.sha256(command.encode()).hexdigest(),
            "command_preview": command[:300],
            "timeout_seconds": timeout_seconds,
        })
        return {
            "return_code": -1,
            "stdout": (exc.stdout or "")[-50000:] if isinstance(exc.stdout, str) else "",
            "stderr": (exc.stderr or "")[-20000:] if isinstance(exc.stderr, str) else "",
            "duration_seconds": round(time.time() - started, 3),
            "timed_out": True,
        }

@mcp.tool()
def list_files(path: str = "/") -> list:
    """List files and directories at an absolute or relative server path."""
    target = Path(path).expanduser()
    if not target.is_absolute():
        target = Path("/") / target
    entries = []
    for item in sorted(target.iterdir(), key=lambda p: p.name.lower()):
        try:
            st = item.lstat()
            entries.append({
                "name": item.name,
                "path": str(item),
                "type": "symlink" if item.is_symlink() else ("directory" if item.is_dir() else "file"),
                "size_bytes": st.st_size,
                "permissions": oct(st.st_mode & 0o777),
                "modified": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
            })
        except OSError as exc:
            entries.append({"name": item.name, "error": str(exc)})
    audit("list_files", {"path": str(target)})
    return entries

@mcp.tool()
def read_file(path: str, max_bytes: int = 1000000) -> str:
    """Read a UTF-8 text file. max_bytes is capped at 5 MB."""
    target = Path(path).expanduser()
    if not target.is_absolute():
        target = Path("/") / target
    limit = max(1, min(int(max_bytes), 5_000_000))
    with target.open("rb") as f:
        data = f.read(limit)
    audit("read_file", {"path": str(target), "bytes_returned": len(data)})
    return data.decode("utf-8", errors="replace")

@mcp.tool()
def write_file(path: str, content: str, mode: str = "0644") -> dict:
    """Create or overwrite a UTF-8 text file. Parent directories are created."""
    target = Path(path).expanduser()
    if not target.is_absolute():
        target = Path("/") / target
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content, encoding="utf-8")
    try:
        permissions = int(mode, 8)
    except ValueError:
        permissions = 0o644
    permissions &= 0o777
    target.chmod(permissions)
    audit("write_file", {"path": str(target), "bytes": len(content.encode("utf-8")), "mode": oct(permissions)})
    return {"ok": True, "path": str(target), "bytes_written": len(content.encode("utf-8")), "mode": oct(permissions)}

@mcp.tool()
def manage_service(service_name: str, action: str) -> dict:
    """Manage a systemd service. Actions: status, start, stop, restart, enable, disable."""
    allowed = {"status", "start", "stop", "restart", "enable", "disable"}
    if action not in allowed:
        raise ValueError(f"Action must be one of: {', '.join(sorted(allowed))}")
    if not service_name or any(c not in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.@:-" for c in service_name):
        raise ValueError("Invalid service name")
    args = ["systemctl", action, service_name]
    result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    audit("manage_service", {"service": service_name, "action": action, "return_code": result.returncode})
    return {"return_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}

@mcp.tool()
def list_processes(limit: int = 50) -> list:
    """List running processes, sorted by memory use."""
    limit = max(1, min(int(limit), 200))
    procs = []
    for p in psutil.process_iter(["pid", "name", "username", "cpu_percent", "memory_percent", "status"]):
        try:
            procs.append(p.info)
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            pass
    procs.sort(key=lambda x: x.get("memory_percent") or 0, reverse=True)
    audit("list_processes", {"limit": limit})
    return procs[:limit]

@mcp.tool()
def get_network_info() -> dict:
    """Return listening TCP/UDP sockets and network interface addresses."""
    interfaces = {}
    for name, addresses in psutil.net_if_addrs().items():
        interfaces[name] = [
            {"family": str(a.family), "address": a.address, "netmask": a.netmask}
            for a in addresses
        ]
    sockets = []
    for c in psutil.net_connections(kind="inet"):
        if c.status == psutil.CONN_LISTEN or c.type == 2:
            sockets.append({
                "family": str(c.family),
                "type": str(c.type),
                "local_address": f"{c.laddr.ip}:{c.laddr.port}" if c.laddr else None,
                "status": c.status,
                "pid": c.pid,
            })
    audit("network_info", {})
    return {"interfaces": interfaces, "sockets": sockets[:500]}

@mcp.tool()
def docker_ps(all_containers: bool = True) -> dict:
    """Show Docker containers. Docker CLI must be installed on the server."""
    args = ["docker", "ps", "--no-trunc"]
    if all_containers:
        args.append("-a")
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    except FileNotFoundError:
        return {"return_code": 127, "stdout": "", "stderr": "docker CLI is not installed"}
    audit("docker_ps", {"all": all_containers, "return_code": result.returncode})
    return {"return_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}

if __name__ == "__main__":
    app = SecretPathMiddleware(mcp.streamable_http_app())
    # access_log=False so the secret URL path is never written to the logs
    uvicorn.run(app, host=HOST, port=PORT, log_level="info", lifespan="on", access_log=False)
PYCODE
chmod 0750 "$APP_DIR/server.py"

log "Writing protected environment file..."
cat > "$ETC_DIR/server.env" <<EOF
MCP_ACCESS_TOKEN=$MCP_TOKEN
MCP_PUBLIC_HOSTNAME=$HOSTNAME_IN
MCP_PORT=$BIND_PORT
MCP_BIND_HOST=$BIND_HOST
EOF
chmod 0600 "$ETC_DIR/server.env"

log "Writing systemd service for MCP..."
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Independent Server MCP Manager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
EnvironmentFile=${ETC_DIR}/server.env
WorkingDirectory=${APP_DIR}
ExecStart=${APP_DIR}/venv/bin/python ${APP_DIR}/server.py
Restart=always
RestartSec=5
KillSignal=SIGINT
TimeoutStopSec=30
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

log "Writing protected Cloudflare Tunnel token and service..."
cat > "$ETC_DIR/tunnel.env" <<EOF
TUNNEL_TOKEN=$TUNNEL_TOKEN
EOF
chmod 0600 "$ETC_DIR/tunnel.env"

cat > "/etc/systemd/system/${TUNNEL_SERVICE_NAME}.service" <<EOF
[Unit]
Description=Cloudflare Tunnel for Server MCP Manager
After=network-online.target ${SERVICE_NAME}.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=${ETC_DIR}/tunnel.env
ExecStart=/usr/bin/cloudflared tunnel --no-autoupdate run --token \${TUNNEL_TOKEN}
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "$SERVICE_NAME" "$TUNNEL_SERVICE_NAME"
systemctl restart "$SERVICE_NAME"
systemctl restart "$TUNNEL_SERVICE_NAME"

log "Waiting for the MCP service to come up..."
STATUS=""
STATUS_TOKEN=""
for _ in 1 2 3 4 5 6 7 8 9 10; do
  STATUS="$(curl -s -o /dev/null -w '%{http_code}' "http://${BIND_HOST}:${BIND_PORT}/mcp" || true)"
  [[ "$STATUS" == "404" ]] && break
  sleep 2
done
STATUS_TOKEN="$(curl -s -o /dev/null -w '%{http_code}' "http://${BIND_HOST}:${BIND_PORT}/${MCP_TOKEN}/mcp" || true)"

echo
echo "=============================================================="
if [[ "$STATUS" == "404" && "$STATUS_TOKEN" != "404" && "$STATUS_TOKEN" != "000" ]]; then
  echo "Installation completed. Local check OK (no token = 404, with token = ${STATUS_TOKEN})."
else
  echo "WARNING: local check: without token='${STATUS:-none}' (want 404), with token='${STATUS_TOKEN:-none}' (want not 404)."
  echo "Inspect:  journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
fi
echo "=============================================================="
echo "Connector URL (paste into Claude, choose 'No sign-in', no headers):"
echo "  https://${HOSTNAME_IN}/${MCP_TOKEN}/mcp"
echo "MCP service:    systemctl status ${SERVICE_NAME}"
echo "Tunnel service: systemctl status ${TUNNEL_SERVICE_NAME}"
echo "MCP logs:       journalctl -u ${SERVICE_NAME} -f"
echo "Tunnel logs:    journalctl -u ${TUNNEL_SERVICE_NAME} -f"
echo "Audit log:      ${LOG_DIR}/audit.jsonl"
echo
echo "MCP authentication: the token is part of the URL path (no headers needed)."
echo "  Anyone who has the full URL has root access. Never share it."
echo "  Token file: ${ETC_DIR}/server.env"
echo "  Read token only on this server with:"
echo "    sudo sed -n 's/^MCP_ACCESS_TOKEN=//p' ${ETC_DIR}/server.env"
echo
echo "IMPORTANT Cloudflare dashboard step:"
echo "  In this tunnel, the Public Hostname route must be:"
echo "    Hostname: ${HOSTNAME_IN}"
echo "    Service:  http://${BIND_HOST}:${BIND_PORT}"
echo "  (change it from http://172.17.0.1:8008 if you used the old script)"
echo "  The tunnel token should belong only to this server."
echo
echo "The MCP endpoint is bound only to ${BIND_HOST}; do NOT change it to 0.0.0.0."
echo "Keep both token files private. Rotate tokens immediately if exposed."
echo "=============================================================="
