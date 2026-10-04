# __NAME__

| | |
|---|---|
| Upstream image | `__IMAGE__` |
| Public hostname | `https://__HOSTNAME__/mcp` (tunnel → `http://gateway:8080`) |
| Portal server ID | `__NAME__` |
| Token variable | `__TOKEN_VAR__` in `$MCP_SECRETS_DIR/gateway.env` |
| Secrets | `$MCP_SECRETS_DIR/__NAME__.env` |
| Egress | __EGRESS_NOTE__ |

## Tool allowlist

Fill in `tools.json` with the tools the portal should expose; everything else
stays hidden (`default_disabled: true`).

## Notes

- TODO: what this server can read/change, and why the allowlist is safe.
