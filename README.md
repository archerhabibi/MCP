# Server MCP Manager

[![CI](https://github.com/archerhabibi/MCP/actions/workflows/ci.yml/badge.svg)](https://github.com/archerhabibi/MCP/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/archerhabibi/MCP)](https://github.com/archerhabibi/MCP/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**English** · [فارسی](#-فارسی)

A one-command installer that turns an Ubuntu/Debian server into an independently
authenticated **MCP (Model Context Protocol) server** you can connect to from Claude,
exposed securely through its own **Cloudflare Tunnel**. No open inbound ports.

> ⚠️ **This grants root-level remote administration.** Anyone with the connector URL has
> root on the server. Use one tunnel and one token per server, and never share the URL.

## One-line install

Run as a user with `sudo` on the target server:

```bash
sudo bash -c "$(curl -fsSL https://github.com/archerhabibi/MCP/releases/latest/download/install-server-mcp.sh)"
```

The installer is interactive, so it must be started this way (not `curl … | bash`).

You will be asked for:

1. **Public hostname** for this server, e.g. `srv1-mcp.example.com`
2. **Cloudflare Tunnel token** for this server
3. **MCP access token** – leave empty to auto-generate a 64-char one (min. 40 chars)

At the end it prints your connector URL:

```
https://<hostname>/<MCP_TOKEN>/mcp
```

Paste it into Claude → *Settings → Connectors → Add custom connector*, choose
**No sign-in** and leave headers empty.

### Cloudflare dashboard step

In your tunnel, add a **Public Hostname**:

| Field    | Value                    |
|----------|--------------------------|
| Hostname | your hostname            |
| Service  | `http://127.0.0.1:8008`  |

### Verify the download (optional)

```bash
curl -fsSLO https://github.com/archerhabibi/MCP/releases/latest/download/install-server-mcp.sh
curl -fsSLO https://github.com/archerhabibi/MCP/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
sudo bash install-server-mcp.sh
```

## Requirements

- Ubuntu or Debian with systemd, run as root
- A Cloudflare account with a Tunnel (token) and a hostname

## What gets installed

| Item | Location |
|------|----------|
| App + virtualenv | `/opt/server-mcp` |
| Secrets (0600) | `/etc/server-mcp/server.env`, `tunnel.env` |
| Audit log | `/var/log/server-mcp/audit.jsonl` |
| Services | `server-mcp`, `server-mcp-tunnel` (does not touch an existing `cloudflared.service`) |

## Security model

- Token is a secret first URL segment; wrong/missing token → plain `404`
- Constant-time token comparison, minimum token length 40
- Server binds to `127.0.0.1:8008` only; reachable solely through the tunnel
- DNS-rebinding protection (allowed hosts/origins pinned to your hostname)
- No HTTP access log (token never written to logs); every tool call is audited
- Pinned to `mcp>=1.10,<2`

## Tools

`hello` · `get_system_info` · `run_command` (root bash) · `list_files` · `read_file` ·
`write_file` · `manage_service` · `list_processes` · `get_network_info` · `docker_ps`

## Management

```bash
systemctl status server-mcp server-mcp-tunnel
journalctl -u server-mcp -f
sudo tail -f /var/log/server-mcp/audit.jsonl
sudo sed -n 's/^MCP_ACCESS_TOKEN=//p' /etc/server-mcp/server.env   # show token
```

**Update / rotate tokens:** re-run the installer; answer `n` to "Reuse" to enter new values.

## Uninstall

```bash
sudo bash -c "$(curl -fsSL https://github.com/archerhabibi/MCP/releases/latest/download/uninstall-server-mcp.sh)"
```

Then delete the tunnel/hostname in Cloudflare and consider the old token revoked.

---

## 🇮🇷 فارسی

نصب‌کننده‌ی تک‌دستوری که سرور اوبونتو/دبیان شما را به یک **MCP سرور** با احراز هویت مستقل
تبدیل می‌کند و از طریق **Cloudflare Tunnel** اختصاصی (بدون باز کردن پورت ورودی) به Claude وصل می‌شود.

> ⚠️ **این ابزار دسترسی root از راه دور می‌دهد.** هر کس آدرس کانکتور را داشته باشد روت سرور را دارد.
> برای هر سرور یک تونل و یک توکن جدا استفاده کنید و آدرس را هرگز منتشر نکنید.

### نصب تک‌خطی

روی سرور مقصد (با دسترسی `sudo`) اجرا کنید:

```bash
sudo bash -c "$(curl -fsSL https://github.com/archerhabibi/MCP/releases/latest/download/install-server-mcp.sh)"
```

اسکریپت تعاملی است؛ پس باید دقیقاً به همین شکل اجرا شود (نه `curl … | bash`).

مقادیر موردنیاز:

1. **هاست‌نیم عمومی** این سرور (مثلاً `srv1-mcp.example.com`)
2. **توکن Cloudflare Tunnel** همین سرور
3. **توکن MCP** – خالی بگذارید تا خودکار ساخته شود (حداقل ۴۰ کاراکتر)

در پایان آدرس کانکتور چاپ می‌شود:

```
https://<hostname>/<MCP_TOKEN>/mcp
```

آن را در Claude ← *Settings ← Connectors ← Add custom connector* وارد کنید، گزینه‌ی
**No sign-in** را بزنید و هدری وارد نکنید.

### تنظیم در داشبورد Cloudflare

در تونل، یک **Public Hostname** بسازید: هاست‌نیم شما ← سرویس `http://127.0.0.1:8008`

### به‌روزرسانی / تعویض توکن

اسکریپت را دوباره اجرا کنید و به سؤال «Reuse» پاسخ `n` بدهید.

### حذف

```bash
sudo bash -c "$(curl -fsSL https://github.com/archerhabibi/MCP/releases/latest/download/uninstall-server-mcp.sh)"
```

سپس تونل/هاست‌نیم را از Cloudflare حذف کنید و توکن قبلی را باطل‌شده بدانید.

## License

[MIT](LICENSE)
