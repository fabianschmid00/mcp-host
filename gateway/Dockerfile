# Auth gateway: upstream Caddy with the file capability stripped.
#
# The official image ships /usr/bin/caddy with cap_net_bind_service set as a
# file capability. Under cap_drop: [ALL] + no-new-privileges the kernel refuses
# to exec such a binary ("operation not permitted"). We only listen on :8080,
# so a plain copy (cp does not preserve xattrs) is all that is needed.
FROM caddy:2.11.6-alpine@sha256:c776e0c6413b544d0459665e54ec7b8b2a15000c0cbee8b254da0067b1d184ff

RUN cp /usr/bin/caddy /usr/bin/caddy.nocap \
 && mv /usr/bin/caddy.nocap /usr/bin/caddy \
 && caddy version

COPY --chmod=0755 entrypoint.sh /usr/local/bin/gateway-entrypoint
COPY --chmod=0644 Caddyfile /etc/caddy/Caddyfile

USER 65532:65532
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/gateway-entrypoint"]
