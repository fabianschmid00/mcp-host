# garmin-alina: Alina's Garmin Connect account

Second instance of [`servers/garmin`](../garmin/README.md): same image, same
hardening, same 153 tools. Everything account-specific is separate:

| | |
|---|---|
| Public hostname | `https://garmin-alina-mcp.fabiserver.de/mcp` (tunnel → `http://gateway:8080`) |
| Portal server ID | `garmin-alina` (tools appear as `garmin-alina_<tool>`) |
| Token variable | `GARMIN_ALINA_UPSTREAM_TOKEN` in `$MCP_SECRETS_DIR/gateway.env` |
| Secrets | Alina's OAuth tokens on the `garmin-alina-data` volume. `garmin-alina.env` stays empty. |
| Egress | own `garmin-alina-egress` network |
| Access | your claude.ai only (portal policy `Only Fabian`), with Alina's consent |

## One-time login (Alina types her own password)

```bash
./mcp up
./mcp dc run --rm -it --entrypoint garmin-mcp-auth garmin-alina
./mcp restart garmin-alina
./mcp verify garmin-alina
```

**Revoke:** Alina changes her Garmin password (invalidates the tokens), and/or
`./mcp remove garmin-alina` (also deletes the token volume).

Tools, risks, and security overrides: see `servers/garmin/README.md`. In
claude.ai set the same write/delete tools to **Ask** (`tools.json` → `ask`).
