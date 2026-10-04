# Verification

Status legend: **done** (evidence below), **CI** (checked on every PR by
`.github/workflows/ci.yml`), **pending: user** (needs your accounts or the VM).

## Where the evidence comes from

The development sandbox could not download layers from ghcr.io (manifests
only), so local tests used a **stand-in image**: `python:3.13-slim` with
`mcp-email-server==1.11.0` from PyPI installed into `/app/.venv`, matching
the upstream Dockerfile at tag `1.11.0` (same base, venv path and entrypoint,
minus `tini`). CI on GitHub runs the same checks against the **real pinned
image**. Repeat the "on the VM" column once there.

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

Local (stand-in gmx image, hence the expected "not pinned" warning):

```
CONTAINER              USER         RO_FS  CAP_DROP  SECURITY_OPT             PORTS  SOCK  PRIV   IMAGE
mcp-host-gateway-1     65532:65532  true   ALL       no-new-privileges:true   0      no    false  mcp-host/gateway:local
mcp-host-gmx-1         10001:10001  true   ALL       no-new-privileges:true   0      no    false  local/mcp-email-server:standin
```

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
| No published ports, non-root, read-only rootfs, caps dropped, no-new-privileges, no docker.sock | done (gateway, gmx), CI; cloudflared pending: user |
| Images pinned by digest | done; `./mcp check` enforces it |

## Scans

| Check | Status | Result |
|---|---|---|
| gitleaks (history + working tree) | done, CI | no leaks found |
| trivy `caddy:2.11.6-alpine` | done | 0 HIGH/CRITICAL |
| trivy `cloudflared:2026.9.3` | done | 0 CRITICAL; 2 HIGH (`libssl3t64` CVE-2026-75804, OpenSSL QUIC DoS, fixed in `3.5.7-1~deb13u3`); accepted until the next cloudflared release (Renovate) |
| trivy `mcp-email-server:1.11.0` | CI | could not pull layers in the sandbox |

## Scaffolding

| Check | Status | Evidence |
|---|---|---|
| `./mcp add test` → hardened scaffold | done, CI | compose/route/env/tools/README generated, token created, Cloudflare steps printed; after filling the TODOs, `./mcp verify test` passed all checks |
| `./mcp remove test` → fully cleaned up | done, CI | container, `test-backend` network, `servers/test`, token line and `test.env` gone; gateway recreated without the network |

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
