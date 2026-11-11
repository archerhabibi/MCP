# Changelog

## [1.0.0] - 2026-11-11

### Added
- `install-server-mcp.sh`: one-command installer for Ubuntu/Debian that sets up an
  authenticated MCP server (FastMCP, `mcp>=1.10,<2`) behind a dedicated Cloudflare Tunnel.
- Secret-path authentication (`https://host/<TOKEN>/mcp`), constant-time token comparison,
  loopback-only bind (`127.0.0.1:8008`), DNS-rebinding protection, no access log.
- Tools: `hello`, `get_system_info`, `run_command`, `list_files`, `read_file`,
  `write_file`, `manage_service`, `list_processes`, `get_network_info`, `docker_ps`.
- JSONL audit log at `/var/log/server-mcp/audit.jsonl`.
- `uninstall-server-mcp.sh` for clean removal.
- CI (ShellCheck) and automated release workflow with SHA-256 checksums.
