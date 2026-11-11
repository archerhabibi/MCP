# Security Policy

Server MCP Manager gives **root-level remote administration** to whoever holds the
connector URL. Treat the URL (`https://<host>/<TOKEN>/mcp`) like a root password.

- Use a separate Cloudflare Tunnel and a separate MCP token per server.
- Never paste the URL into chats, tickets or screenshots you do not control.
- If a token may be exposed: re-run the installer, answer `n` to reuse, and enter a new token.
- Review `/var/log/server-mcp/audit.jsonl` regularly.

## Reporting a vulnerability
Please open a private security advisory on GitHub
(Security → Advisories → Report a vulnerability) instead of a public issue.
