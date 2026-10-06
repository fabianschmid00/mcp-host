#!/bin/sh
# Fail closed: every route must go through mcp_route with a well-formed token.
set -eu

routes_dir=/etc/caddy/servers
status=0

for route in "$routes_dir"/*/route.caddy; do
	[ -e "$route" ] || continue
	if ! grep -Eq '^[[:space:]]*import mcp_route \{\$[A-Z0-9_]+_UPSTREAM_TOKEN\} ' "$route"; then
		echo "gateway: $route does not import mcp_route with an *_UPSTREAM_TOKEN" >&2
		status=1
		continue
	fi
	for var in $(grep -o '{\$[A-Z0-9_]*_UPSTREAM_TOKEN}' "$route" | tr -d '{}$' | sort -u); do
		value=""
		eval "value=\${$var:-}"
		if ! printf '%s' "$value" | grep -Eq '^[0-9a-f]{64}$'; then
			echo "gateway: $var is missing or not a 64-char hex token" >&2
			status=1
		fi
	done
done

[ "$status" -eq 0 ] || exit 1
exec caddy run --config /etc/caddy/Caddyfile --adapter caddyfile
