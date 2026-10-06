# Runbook: from nothing to a working claude.ai connector

Every step that touches an account (GMX, Cloudflare, Proxmox, claude.ai) is
manual. Do them in order; each ends with **Verify**. Dashboard labels are
from Cloudflare's docs as of October 2026 and may be worded slightly
differently in your dashboard.

| Name | Value |
|---|---|
| MCP host VM | Debian 13, 2 vCPU, 2 GiB RAM, 16 GiB disk |
| Tunnel | `mcp-host` (new, dashboard-managed; **not** the HA add-on tunnel) |
| Upstream hostname | `mail-mcp.fabiserver.de` → `http://gateway:8080` |
| Upstream URL in portal | `https://mail-mcp.fabiserver.de/mcp` (exact, no trailing slash) |
| Portal | `https://mcp.fabiserver.de/mcp` |
| Server ID | `gmx` (no underscores) |

---

## Part A: accounts

### A1. GMX

1. Webmail → E-Mail-Einstellungen → POP3/IMAP Abruf → **POP3 und IMAP Zugriff erlauben**.
2. Enable 2FA (needs the web version, the GMX app and a TOTP app).
3. Mein Account → Sicherheit → Anwendungsspezifische Passwörter → create `mcp-homelab`.
   Keep it in your password manager only until step B3.

**Verify:** the app password is listed; IMAP access is on.

### A2. Cloudflare Zero Trust

1. Zero Trust → Settings: note your team name; plan is **Free** (setup may ask
   for a payment method even on Free).
2. Settings → Authentication → Login methods: **One-time PIN** is enabled.
   Use it as the only identity provider for the MCP apps.

**Verify:** you can see the team name and One-time PIN under login methods.

### A3. Zone `fabiserver.de` security settings

claude.ai connects from Anthropic's egress range `160.79.104.0/21` (US).
Anything that challenges it breaks the connector *before* a login screen.

1. Security → Bots: **Bot Fight Mode**. On the Free plan it cannot be skipped
   per hostname. If it is on, it will likely block claude.ai; turn it off
   (this affects the whole zone, including HA/Nextcloud; decide consciously).
2. Security → Bots: **Block AI bots** and **AI Labyrinth** off, or scoped so they
   do not apply to `mcp.` and `mail-mcp.`.
3. Security → WAF → Custom rules: no geo/country rule may block or challenge
   the US for these hosts. If you have such rules, add a rule **before** them:
   - Expression: `(http.host in {"mcp.fabiserver.de" "mail-mcp.fabiserver.de"})`
   - Action: **Skip** → all remaining custom rules (and rate limiting rules).
4. DNS: no existing records for `mcp` or `mail-mcp`.

**Verify:** none of the above can challenge the two hostnames.

---

## Part B: the VM

### B1. Proxmox

1. Create VM `mcp-host`: Debian 13 netinst/cloud image, q35, VirtIO SCSI +
   VirtIO net, 2 vCPU (type `host`), 2048 MiB RAM (ballooning min 1024),
   16 GiB disk, **QEMU guest agent** on, NIC **Firewall** checkbox on.
2. VM → Firewall → Options: **Firewall: Yes**, Input policy **DROP**,
   Output policy **ACCEPT**. Rules (top to bottom):
   - IN ACCEPT tcp dport 22 from `<your admin PC IP>`
   - OUT ACCEPT udp+tcp dport 53 to `<your router IP>`
   - OUT ACCEPT udp dport 67 to `<your router IP>` (DHCP renewals; skip if the VM has a static IP)
   - OUT DROP to `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`
     (the VM must not reach HA, Nextcloud or anything else on the LAN)

   Enable the firewall at Datacenter level too if it is not already.
3. Datacenter → Backup: add a job for this VM (weekly is plenty; it holds no
   data besides secrets). Snapshot before every upgrade.

**Verify:** from the VM, `curl -sI https://cloudflare.com` works and
`ping <HA IP>` does not.

### B2. Bootstrap the guest

As root in the VM:

```bash
apt-get update && apt-get install -y git
git clone https://github.com/fabianschmid00/mcp-host.git /opt/mcp-host   # private repo: use a read-only deploy key
/opt/mcp-host/host/bootstrap-guest.sh <your-user>
chown -R <your-user>: /opt/mcp-host
```

Log out and back in as `<your-user>`.

**Verify:** `docker compose version` works without sudo; `/etc/mcp-host` is `drwx------ <your-user>`.

### B3. Secrets

```bash
cd /opt/mcp-host
./mcp init                       # creates /etc/mcp-host/{tunnel,gateway,gmx}.env, generates the gmx token
$EDITOR /etc/mcp-host/gmx.env    # address, user name, full name, GMX app password
```

**Verify:** `ls -l /etc/mcp-host` shows `-rw-------` on every file.

---

## Part C: tunnel and stack (Milestone 1: read-only)

### C1. Create the tunnel

1. Zero Trust → Networks → Tunnels → **Create a tunnel** → Cloudflared →
   name `mcp-host` → environment **Docker**.
2. Copy only the token (the long string after `--token`) into
   `/etc/mcp-host/tunnel.env` as `TUNNEL_TOKEN=…`. Do not run the shown command.
3. **Public hostname** → Add:
   - Subdomain `mail-mcp`, domain `fabiserver.de`, path empty
   - Service **HTTP**, URL `gateway:8080`

**Verify:** DNS now has a `mail-mcp` CNAME to `<tunnel-id>.cfargotunnel.com`.

### C2. Start

```bash
./mcp check
./mcp up
./mcp ps        # cloudflared, gateway, gmx all "healthy"
```

**Verify:** the tunnel shows **Healthy** in the dashboard.

### C3. Upstream checks (without the portal)

```bash
./mcp verify gmx            # inside the gateway: 401 without/wrong token, initialize OK on /mcp and /mcp/
./mcp verify gmx --public   # the same through Cloudflare (portal check fails until Part D: expected)
```

If `--public` returns 403 instead of 401, a Cloudflare security feature is
challenging the request: go back to A3.

---

## Part D: MCP server portal

### D1. Add the MCP server

Zero Trust → AI controls → MCP servers → **Add an MCP server**:

| Field | Value |
|---|---|
| Name | GMX mail |
| Server ID | `gmx` |
| HTTP URL | `https://mail-mcp.fabiserver.de/mcp` (immutable after saving; no trailing slash) |
| Authentication | **Custom headers**: the JSON printed by `./mcp token gmx` |
| Access policy | Allow → Emails → `schmidfabianlucas@gmx.de` |

`./mcp token gmx` prints `{"Authorization": "Bearer …"}`. Paste it, then clear your scrollback.

**Verify:** server status becomes **Ready** (use **Sync capabilities** if it
sits in a pending state). If it errors, `./mcp logs gateway`: a 401 there
means the header does not match the token.

### D2. Create the portal

AI controls → MCP server portals → **Add**:

- Hostname `mcp.fabiserver.de` (the dashboard creates the CNAME to
  `gateway.agents.cloudflare.com`)
- Add server `gmx`
- Access policy: Allow → Emails → `schmidfabianlucas@gmx.de`, login method One-time PIN

### D3. Managed OAuth on the portal's Access application

Access controls → Applications → the portal's auto-created app → **Advanced settings**:

- **Managed OAuth**: on
- **Allowed redirect URIs**:
  - `https://claude.ai/api/mcp/auth_callback`
  - `https://claude.com/api/mcp/auth_callback`
- **Allow localhost and loopback clients**: on (Claude Code)
- Access token lifetime **10 minutes**; grant session duration **14 days**

### D4. Tool allowlist

Portal → server `gmx` → tools. Disable everything, then enable only the
`allow` list in `servers/gmx/tools.json`:

`list_available_accounts`, `list_emails_metadata`, `get_emails_content`, `list_mailboxes`, `save_draft`

Prefer the API's allowlist mode (`default_disabled: true` + `updated_tools`)
so tools added by future upstream versions start hidden. The exact endpoint
is not in this repo's notes; until then use the dashboard toggles and
re-check the list after every mail-server upgrade.

**Verify:** after **Sync capabilities**, only those 4 tools are enabled.

### D5. Portal check

```bash
./mcp verify gmx --public
```

Expect the portal to return **401** with a `WWW-Authenticate` header
containing `resource_metadata=…/.well-known/oauth-protected-resource…`.

---

## Part E: clients

### E1. claude.ai (web)

1. Settings → Connectors → **Add custom connector** → URL `https://mcp.fabiserver.de/mcp`.
2. **Connect** → Cloudflare login → One-time PIN to your email.
3. Customize → Connectors → the connector: read tools → **Allow**.
4. New chat: "List my 5 newest emails (subjects only)."

**Verify:** tool list shows only `gmx_*` tools from D4; the inbox listing works.

**If you get "Authorization with the MCP server failed"** (or "Couldn't register
with …'s sign-in service"), stop and collect:
- the `ofid_…` reference shown by claude.ai
- `curl -si -X POST https://mcp.fabiserver.de/mcp | grep -i www-authenticate`
- the redirect URIs from D3 (exact, both present)
- whether Bot Fight Mode / AI bot blocking / WAF events show requests from `160.79.104.0/21`
  (Security → Events)

Then report back; do not work around it.

### E2. Mobile

The connector syncs from your account. Open the Claude app, start a chat, ask for the newest emails.

### E3. Claude Code (optional)

```bash
claude mcp add --transport http home https://mcp.fabiserver.de/mcp
# then inside Claude Code: /mcp → home → Authenticate
```

### E4. Restart resilience

`./mcp restart gmx`, then ask claude.ai for the inbox again. The server keeps
sessions in memory; the portal must re-initialize. Note the result in
docs/VERIFICATION.md.

---

## Part F: Milestone 2 (drafts)

1. In `servers/gmx/compose.yaml` set:
   ```yaml
   MCP_EMAIL_SERVER_ALLOWED_MUTATIONS: "draft"
   MCP_EMAIL_SERVER_ACCOUNT_ALLOWED_MUTATIONS: "draft"
   MCP_EMAIL_SERVER_ALLOWED_RECIPIENTS: "*"
   ```
   Leave `MCP_EMAIL_SERVER_SMTP_HOST: ""`. Commit, then `./mcp up`.
2. Portal → `gmx` → enable `save_draft` → **Sync capabilities**.
3. claude.ai → connector → `save_draft` → **Allow** (or Ask).
4. Ask Claude to draft a short mail to yourself.

**Verify:** the draft appears in GMX's Drafts (Entwürfe) folder; claude.ai's
tool list contains no `send_email`, `forward_email`, `delete_emails` or any
other tool from the `never` list. If drafting fails with a mailbox error, run
`list_mailboxes` and set `MCP_EMAIL_SERVER_DRAFTS_MAILBOX` to the exact name.

---

## Adding another server

```bash
./mcp add <name> --image <repo>:<tag>@sha256:<digest> --port <port> [--hostname <host>] [--egress]
```

It scaffolds `servers/<name>/`, generates the token and prints the steps,
which mirror C1.3 (public hostname), D1 (server, Custom headers), D2 (attach
to the existing portal) and D4 (allowlist). claude.ai needs nothing new: the
same connector shows the new `<name>_*` tools after the portal syncs.

Removing: `./mcp remove <name>` prints the matching Cloudflare cleanup.

## Optional: edge-enforced second layer on upstream hostnames

Not required; test it separately. Cloudflare Access application on
`mail-mcp.fabiserver.de` with a **Service Auth** policy and a service token;
add `CF-Access-Client-Id` / `CF-Access-Client-Secret` to the portal server's
Custom headers next to `Authorization`. Direct requests without the service
token are then rejected at the edge. Unknown: whether this coexists cleanly
with the portal's own Access app for the server. If the server stops being
**Ready**, remove the app again. The gateway already strips both headers.
