# garmin: Garmin Connect

| | |
|---|---|
| Upstream | [taxuspt/garmin_mcp](https://github.com/taxuspt/garmin_mcp), commit pinned in `Dockerfile` (no releases or image upstream; Renovate tracks `main`) |
| Image | `mcp-host/garmin:local`, built from source: `python:3.13-slim` + upstream `uv.lock` (`--frozen`) + `requirements-overrides.txt` |
| Public hostname | `https://garmin-mcp.fabiserver.de/mcp` (tunnel → `http://gateway:8080`) |
| Portal server ID | `garmin` |
| Token variable | `GARMIN_UPSTREAM_TOKEN` in `$MCP_SECRETS_DIR/gateway.env` |
| Secrets | **OAuth tokens on the `garmin-data` volume** (`/data/tokens`). `garmin.env` stays empty. |
| Egress | own `garmin-egress` network (Garmin Connect over HTTPS) |
| Tools | **all 153** (owner's choice), including writes and deletes |

## One-time login

The Garmin password is typed once into the auth CLI and never stored. Only the
resulting OAuth tokens are kept (valid about 6 months):

```bash
./mcp up                                                   # builds the image
./mcp dc run --rm -it --entrypoint garmin-mcp-auth garmin  # email + password (+ MFA code if enabled)
./mcp restart garmin                                       # server picks up the tokens
./mcp dc run --rm -it --entrypoint garmin-mcp-auth garmin --verify
```

Re-run the auth command with `--force-reauth` when tool calls start failing
with "Garmin login failed".

**Revoke:** change your Garmin password (this invalidates the tokens), then
`./mcp dc down` the server and remove the volume
(`docker volume rm mcp-host_garmin-data`), or `./mcp remove garmin`.

## Tools and risk

All tools are exposed, so Claude can also **delete** courses, workouts, food
logs and weigh-ins, change heart-rate zones, and schedule or upload workouts.
Prompt injection is much less likely than with email (the data is mostly your
own), but set these to **Ask** in claude.ai (listed in `tools.json` → `ask`):

`delete_course`, `delete_custom_food`, `delete_food_log`, `delete_weigh_ins`,
`delete_workout`, `delete_workouts`, `set_heart_rate_zones`,
`set_nutrition_daily_settings`, `upload_course`, `download_activity_file`,
`download_course_gpx`, `set_fit_download_dir`

File tools only reach the container's own filesystem: everything is read-only
except `/tmp` (tmpfs, downloads land in `/tmp/downloads`) and `/data` (tokens).
A download pointed at `/data` could at worst overwrite the token files, which
means re-running the login.

## Security overrides

`requirements-overrides.txt` bumps packages from upstream's lockfile:

| Package | Lockfile → image | Why |
|---|---|---|
| h11 | 0.14.0 → 0.16.0 | CVE-2025-43859 (CRITICAL, request smuggling in uvicorn's parser) |
| httpcore | 1.0.7 → 1.0.9 | needed for h11 ≥ 0.16 |
| urllib3 | 2.7.0 → 2.8.0 | CVE-2026-97687/97689 (HIGH), Garmin API transport |

Not overridden, documented: garminconnect 0.3.2 CVE-2026-54447 (HIGH, token
files created world-readable under a permissive umask). Not applicable here:
`/data` is `0700`, owned by UID 10001, and garmin_mcp tightens the token file
modes after writing. PyJWT 2.13.0 (HIGH) is only used by MCP client-auth code.
