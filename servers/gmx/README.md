# gmx: GMX mailbox

| | |
|---|---|
| Upstream | `ghcr.io/wh1isper/mcp-email-server:1.11.0` ([source](https://github.com/Wh1isper/mcp-email-server)), pinned by index digest |
| Public hostname | `https://mail-mcp.fabiserver.de/mcp` (tunnel → `http://gateway:8080`) |
| Portal server ID | `gmx` |
| Token variable | `GMX_UPSTREAM_TOKEN` in `$MCP_SECRETS_DIR/gateway.env` |
| Secrets | `$MCP_SECRETS_DIR/gmx.env`: address and GMX app password |
| Egress | `imap.gmx.net:993` only (no SMTP configured) |

## Policy

| `ALLOWED_MUTATIONS` | `ALLOWED_RECIPIENTS` | Portal allowlist |
|---|---|---|
| `draft` | `*` | the 4 read tools + `save_draft` (`tools.json`) |

`MCP_EMAIL_SERVER_SMTP_HOST` is forced to `""`, so the server cannot send mail. Why that matters: `save_draft`/`send_email` accept arbitrary
**server-local file paths** as attachments (for example `/proc/self/environ`,
which contains the app password). With no SMTP, the worst case is such a file
landing in your own Drafts folder. Do not enable SMTP without first putting a
request filter in front that rejects `attachments` (see SECURITY.md).

## Notes

- Image facts (from the upstream Dockerfile at tag 1.11.0): `python:3.13-slim`
  base, venv at `/app/.venv` (world-readable), `tini` entrypoint, root by
  default. We run it as `10001:10001` with `HOME=/config` (tmpfs).
- Server is stateful (`mcp-session-id`, 2025 handshake). The portal falls
  back to the legacy `initialize` flow. Restarting `gmx` drops sessions.
- `POST /mcp/` on the server itself 307-redirects to `http://…/mcp`; the
  gateway rewrites `/mcp/` → `/mcp` internally so clients never see it.
- Drafts and Sent folder names are auto-discovered. If drafting fails, run
  `list_mailboxes` and set `MCP_EMAIL_SERVER_DRAFTS_MAILBOX` in compose.yaml.
