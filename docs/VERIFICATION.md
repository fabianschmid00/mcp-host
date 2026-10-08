# Verification

Status legend: **done** (evidence below), **CI** (checked on every PR by
`.github/workflows/ci.yml`), **pending: user** (needs your accounts or the VM).

## Where the evidence comes from

The first round of local tests (2026-10-04) used a **stand-in image**
(`python:3.13-slim` + `mcp-email-server==1.11.0` from PyPI in `/app/.venv`)
because the sandbox could not download ghcr.io layers. On 2026-10-06 the
**real pinned image** was pulled and `./mcp check`, `./mcp verify` and
`./mcp inspect` were re-run against it, all passing (below). CI runs the same
checks against the real image on every PR. Repeat the "on the VM" section once there.

## Milestone 1: read-only feasibility

| Check | Status | Evidence |
|---|---|---|
| `1.11.0` tag exists, pinned by index digest | done | `ghcr.io/wh1isper/mcp-email-server:1.11.0@sha256:f3b5a295…bad8c` (amd64 `sha256:70404d11…`); upstream git tag `1.11.0` = commit `4da9684` |
| Unauthenticated → 401 | done, CI | `./mcp verify`: no token 401, wrong token 401, `/mcp/` without token 401 |
| With token → `initialize` succeeds | done, CI | 200 + `protocolVersion` in body on `/mcp` |
| `/mcp` and `/mcp/` both work, no redirect | done, CI | both 200 via gateway. Upstream alone answers `/mcp/` with **307 → `http://…/mcp`**, hence the internal rewrite |
| Other server's token rejected | done, CI | with a second server (`test`), each token got 401 on the other host |
| Full MCP session through the gateway | done | initialize (via `/mcp/`) → session id → `notifications/initialized` 202 → `tools/list` 19 tools → `list_available_accounts` `can_send:false` → `DELETE` 200 |
| Gateway fails closed | done, CI | empty token, short token, and a route without `mcp_route`: container exits 1 with a message |
| Tokens never logged | done | `docker logs` of gateway and gmx contain 0 occurrences of the token after the full session |
| Tunnel connected, hostname routes to gateway | pending: user | runbook C1-C3; `./mcp verify gmx --public` |
| Portal server status **Ready** | pending: user | runbook D1 |
| Portal `POST /mcp` → 401 with `WWW-Authenticate … resource_metadata` | pending: user | `./mcp verify gmx --public` |
| claude.ai web: connects, lists tools, lists inbox | pending: user | runbook E1 |
| Mobile app; Claude Code | pending: user | runbook E2, E3 |
| Session recovery after `./mcp restart gmx` | pending: user | runbook E4 |

## Milestone 2: drafts

| Check | Status | Evidence |
|---|---|---|
| With `draft` + recipients `*`: `send_email` refused | done | `Mutation class 'send' is not allowed for this account` (call included `attachments: ["/proc/self/environ"]`) |
| `delete_emails` refused | done | `Mutation class 'delete' is not allowed for this account` |
| No SMTP at all | done | `MCP_EMAIL_SERVER_SMTP_HOST=` in container env; `list_available_accounts` → `can_send: false` |
| Draft appears in GMX Drafts | pending: user | runbook F4 |
| Hidden tools absent in claude.ai | pending: user | runbook D4, F4 |
| Test mail to yourself | not applicable | sending is disabled by design (SECURITY.md) |

## Container hardening (`./mcp inspect`)

Local, real pinned gmx image (2026-10-06):

```
CONTAINER              USER         RO_FS  CAP_DROP  SECURITY_OPT             PORTS  SOCK  PRIV   IMAGE
mcp-host-gateway-1     65532:65532  true   ALL       no-new-privileges:true   0      no    false  mcp-host/gateway:local
mcp-host-gmx-1         10001:10001  true   ALL       no-new-privileges:true   0      no    false  ghcr.io/wh1isper/mcp-email-server:1.11.0@sha256:f3b5a29595432324af997881b7e3cf16f3baf799da054014a099c5d371fbad8c
==> all containers hardened
```

The image itself declares no user (root) and `ENTRYPOINT ["tini", "--",
"mcp-email-server"]`; compose overrides the user to `10001:10001`, and both
containers reach **healthy** with a read-only rootfs.

```
$ docker exec mcp-host-gmx-1 sh -c 'id; touch /x'
uid=10001 gid=10001 groups=10001
touch: cannot touch '/x': Read-only file system
$ docker exec mcp-host-gateway-1 sh -c 'id; touch /x'
uid=65532 gid=65532 groups=65532
touch: /x: Read-only file system
```

Networks: `ingress` internal, `gmx-backend` internal, `gmx-egress` not
internal (bridge `mcp-gmx-egress`, only `gmx` attached). Gateway is on
`ingress` + `gmx-backend` only, so it has **no egress**. From `ingress`,
`gmx:9557` is unreachable.

cloudflared: verified separately that `cloudflared 2026.9.3` runs with
`--read-only --cap-drop ALL --security-opt no-new-privileges:true` as
`65532:65532`. Full run needs the tunnel token: pending: user (`./mcp inspect` on the VM).

Upstream Caddy cannot exec under `cap_drop: ALL` + `no-new-privileges`
(`exec /usr/bin/caddy: operation not permitted`, file capability
`cap_net_bind_service`). `gateway/Dockerfile` copies the binary without it.

| Check | Status |
|---|---|
| No published ports, non-root, read-only rootfs, caps dropped, no-new-privileges, no docker.sock | done (gateway, real gmx image), CI; cloudflared pending: user |
| Images pinned by digest | done; `./mcp check` enforces it |

## Scans

| Check | Status | Result |
|---|---|---|
| gitleaks (history + working tree) | done, CI | no leaks found |
| trivy `caddy:2.11.6-alpine` | done | 0 HIGH/CRITICAL |
| trivy `cloudflared:2026.9.3` | done | 0 CRITICAL; 2 HIGH (`libssl3t64` CVE-2026-75804, OpenSSL QUIC DoS, fixed in `3.5.7-1~deb13u3`); accepted until the next cloudflared release (Renovate) |
| trivy `mcp-email-server:1.11.0` | done, CI | 2 fixable CRITICAL + 10 HIGH (local scan of the real image matches CI). Both CRITICALs **accepted until 2026-11-30** in `.trivyignore.yaml`; runtime evidence below |

### CVE reachability in `mcp-email-server:1.11.0` (real image, 2026-10-06)

Method: the real server ran in the real image (`--user 10001:10001
--read-only --cap-drop ALL --network none`), a full MCP session was driven
against it with the stdlib HTTP client (initialize, `tools/list`,
`list_available_accounts`, `list_mailboxes`, `list_emails_metadata`,
`save_draft` with `draft` allowed; the IMAP calls fail on DNS as expected), and
`sys.modules` was read afterwards. Then the image's site-packages were grepped
for callers.

| Package (version → fix) | Findings | Loaded at runtime? | Verdict |
|---|---|---|---|
| PyJWT 2.13.0 → 2.14.0 | CRITICAL CVE-2026-102268, 5 HIGH | `jwt`: **no** | Not reachable: only imported by `mcp/client/auth/extensions/client_credentials.py` (MCP client OAuth) |
| anyio 4.11.0 → 4.14.2 | CRITICAL CVE-2026-63374 (TLS) | `anyio.streams.tls`: imported, never used | Not reachable: its only users are `httpcore` (**not loaded**; no outbound HTTP) and anyio's own `connect_tcp(tls=…)`, which nothing calls. IMAP uses asyncio `create_connection(ssl=ssl.create_default_context(...))`; every `start_tls` in the app/aiosmtplib is asyncio's `loop.start_tls`, not anyio |
| urllib3 2.7.0, msgpack 1.1.2 | HIGH | **no** | Vendored inside the base image's system pip (`/usr/local/lib/python3.13/site-packages/pip/_vendor/`); only runs when someone invokes `pip` |
| setuptools 70.3.0 | HIGH | **no** (`setuptools`, `pkg_resources`) | Base-image packaging tooling; not imported by the server |
| libpcre2-8-0 (Debian) | HIGH | n/a | OS library from `python:3.13-slim`; fixed in `10.46-1~deb13u3`, arrives with the next upstream image build |

When the exception expires or Renovate bumps the image: re-run `./mcp scan`;
if PyJWT ≥ 2.14.0 and anyio ≥ 4.14.2 are in, delete both entries from
`.trivyignore.yaml`.

## Scaffolding

| Check | Status | Evidence |
|---|---|---|
| `./mcp add test` → hardened scaffold | done, CI | compose/route/env/tools/README generated, token created, Cloudflare steps printed; after filling the TODOs, `./mcp verify test` passed all checks |
| `./mcp remove test` → fully cleaned up | done, CI | container, `test-backend` network, `servers/test`, token line and `test.env` gone; gateway recreated without the network |

## Garmin (`servers/garmin`, 2026-10-06, local build)

| Check | Status | Evidence |
|---|---|---|
| Image builds from pinned commit `cfc5d79` + `uv.lock --frozen` + hash-pinned overrides | done, CI | 299 MB; `h11 0.16.0`, `httpcore 1.0.9`, `urllib3 2.8.0`, `garminconnect 0.3.2`, `mcp 1.28.1` |
| Gateway checks (401/initialize/`/mcp/`/404, cross-server tokens) | done, CI | `./mcp verify`: both servers pass; gmx token → 401 on garmin host and vice versa |
| Full MCP session | done | `tools/list` → **153** tools; before login a tool call returns "Garmin login failed. Run 'garmin-mcp-auth'…" (no crash) |
| Hardening | done, CI | `./mcp inspect`: `10001:10001`, read-only rootfs, caps ALL dropped, no-new-privileges, no ports |
| Token volume | done | `/data` is `drwx------ 10001`, writable via `./mcp dc run`; `/etc` read-only |
| trivy, CRITICAL gate | done, CI | passes after the h11 override (was CVE-2025-43859, reachable via uvicorn); remaining HIGHs documented in `servers/garmin/README.md` |
| Garmin login (`garmin-mcp-auth`) and real data in claude.ai | pending: user | `servers/garmin/README.md` |

## garmin-alina (second Garmin account, 2026-10-08, local)

| Check | Status | Evidence |
|---|---|---|
| Gateway checks incl. cross-server tokens | done, CI | `./mcp verify`: all 3 servers pass; Alina's token → 401 on `garmin` and `gmx`, and theirs → 401 on `garmin-alina` |
| Isolation | done | own volume `garmin-alina-data` → `/data`; own networks `garmin-alina-backend` (internal) + `garmin-alina-egress` |
| Hardening | done, CI | `./mcp inspect`: 10001, read-only, caps dropped, no-new-privileges, no ports |
| `./mcp remove garmin` keeps her tokens | done | after removal only `mcp-host_garmin-alina-data` remained (prefix-match bug fixed) |
| Her login + data in claude.ai | pending: user | `servers/garmin-alina/README.md` |

## On the VM (fill in)

| Check | Result |
|---|---|
| `./mcp check` | |
| `./mcp ps` all healthy | |
| `./mcp verify` | |
| `./mcp verify gmx --public` | |
| `./mcp inspect` (incl. cloudflared, real gmx image) | |
| `./mcp scan` | |
| claude.ai web / mobile / Claude Code | |
| `ofid_` reference if the connector fails | |
