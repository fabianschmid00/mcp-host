# mcp-host

Self-hosted MCP servers on a home server, reachable from claude.ai (web and
mobile) and Claude Code through one Cloudflare MCP server portal. First
server: a GMX mailbox, **read + drafts only**. Second: Garmin Connect
(`servers/garmin`, all tools, see its README).

```
claude.ai / mobile / Claude Code
   │  OAuth (Cloudflare Access Managed OAuth, One-time PIN, only you)
   ▼
https://mcp.fabiserver.de/mcp            Cloudflare MCP server portal (tool allowlist)
   │  Authorization: Bearer <per-server token>
   ▼
https://mail-mcp.fabiserver.de/mcp       Cloudflare Tunnel public hostname
   │  outbound-only tunnel
   ▼
VM: cloudflared ─(ingress, internal)─ gateway (Caddy: token check, Host routing)
                                        └─(gmx-backend, internal)─ gmx (mcp-email-server) ─(gmx-egress)─ imap.gmx.net:993
```

- **No published ports.** Only cloudflared and the mail server have egress.
- **Every container** runs non-root with a read-only rootfs, `cap_drop: ALL`,
  `no-new-privileges`, resource limits and a healthcheck, and is pinned by digest.
- **The portal doesn't protect upstream hostnames.** The gateway enforces a
  per-server token on each one.
- **No sending.** The mail server can attach arbitrary local files, including
  its own credentials, so SMTP is not configured. Claude writes drafts and you
  send them from GMX. See [SECURITY.md](SECURITY.md).

## Getting started

Follow [docs/RUNBOOK-cloudflare.md](docs/RUNBOOK-cloudflare.md) top to bottom.
In short:

1. **Accounts:** GMX IMAP + 2FA + app password; Cloudflare Zero Trust with
   One-time PIN; no bot or WAF rules that challenge the two hostnames.
2. **VM:** create a Debian 13 VM in Proxmox, then run `host/bootstrap-guest.sh <user>`.
3. **Secrets:** run `./mcp init`, then fill in `/etc/mcp-host/gmx.env`.
4. **Tunnel:** create the tunnel `mcp-host`, put its token in
   `/etc/mcp-host/tunnel.env`, and add the hostname `mail-mcp` → `http://gateway:8080`.
5. **Start:** `./mcp up && ./mcp verify && ./mcp verify gmx --public`.
6. **Portal:** add the server `gmx` with the Custom headers from
   `./mcp token gmx`, create the portal on `mcp.fabiserver.de`, enable Managed
   OAuth and the redirect URIs, and apply the tool allowlist.
7. **claude.ai:** add the custom connector `https://mcp.fabiserver.de/mcp`
   and set per-tool permissions.

## Layout

```
compose.yaml              cloudflared + gateway, networks edge / ingress
gateway/                  Caddy (file capability stripped), Caddyfile, fail-closed entrypoint
servers/<name>/           compose.yaml (service + its networks), route.caddy, env.example, tools.json, README.md
templates/server/         what ./mcp add renders
secrets/*.env.example     templates for /etc/mcp-host/*.env
mcp, mcp.conf             helper script and its non-secret settings
host/bootstrap-guest.sh   Docker + unattended-upgrades on a fresh Debian VM
docs/                     runbook, verification evidence
```

Secrets never live in the repo. They are kept in `/etc/mcp-host`
(directory mode 700, files mode 600).

## `./mcp`

| Command | What it does |
|---|---|
| `init` | Creates `/etc/mcp-host`, copies env templates, generates missing tokens |
| `token <name> [--rotate]` | Prints the portal Custom headers JSON for a server |
| `add <name> --image … --port …` | Scaffolds a hardened server + route + token, prints the Cloudflare steps |
| `remove <name>` | Removes the container, files, token, secrets and networks, prints the Cloudflare cleanup |
| `check` / `up` / `down` / `ps` / `logs` / `restart` / `dc …` | Operate the stack (always includes every `servers/*/compose.yaml`) |
| `verify [name] [--public]` | Auth, `/mcp` vs `/mcp/`, unknown hosts, cross-server tokens; `--public` goes through Cloudflare and the portal |
| `inspect` | Hardening evidence for every container |
| `update` / `scan` | Digest drift check and trivy scan |

Use `./mcp dc …` rather than plain `docker compose`, so every server's
compose file is included.

## Maintenance

- **Updates:** Renovate PRs (once the app is installed), or `./mcp update`.
  Then `./mcp up && ./mcp verify`.
- **Backups:** a Proxmox backup of the VM. The only state is `/etc/mcp-host`.
- **Rotation, revocation, debugging:** see [SECURITY.md](SECURITY.md).
- **CI:** gitleaks, shellcheck, a stack test against the real pinned image,
  and a weekly trivy scan. For local secret scanning, run `pre-commit install`.
