#!/usr/bin/env bash
# One-time setup of a fresh Debian 13 VM for the MCP host stack.
# Run as root:  ./host/bootstrap-guest.sh <admin-user>
#
# Installs Docker Engine + Compose plugin from Docker's apt repository,
# unattended security upgrades, and a hardened Docker daemon default config.
# Creates /etc/mcp-host (0700, owned by <admin-user>) for secrets.
set -euo pipefail

admin=${1:?usage: bootstrap-guest.sh <admin-user>}
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
id "$admin" >/dev/null 2>&1 || { echo "no such user: $admin" >&2; exit 1; }
. /etc/os-release
[ "$ID" = debian ] || echo "WARN: tested on Debian 13 only (found $PRETTY_NAME)" >&2

export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q ca-certificates curl git openssl unattended-upgrades qemu-guest-agent

# Docker Engine from Docker's own repository (Debian's docker.io lags behind).
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $VERSION_CODENAME
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Daemon defaults. Compose sets these per service too; this covers anything
# started by hand. Existing config is left untouched.
if [ ! -s /etc/docker/daemon.json ]; then
	cat >/etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "no-new-privileges": true,
  "live-restore": true,
  "userland-proxy": false
}
EOF
	systemctl restart docker
fi

# Security updates for the guest OS (Docker CE updates come via its repo:
# add it to Origins-Pattern if you want those automatic too).
dpkg-reconfigure -f noninteractive unattended-upgrades
systemctl enable --now qemu-guest-agent unattended-upgrades

# Members of the docker group are effectively root. That is accepted here:
# the VM exists only for this stack and has a single admin.
usermod -aG docker "$admin"
install -d -m 700 -o "$admin" -g "$admin" /etc/mcp-host

docker version --format 'Docker {{.Server.Version}}'
docker compose version
echo "Done. Log out and back in as $admin (docker group), then: cd <repo> && ./mcp init"
