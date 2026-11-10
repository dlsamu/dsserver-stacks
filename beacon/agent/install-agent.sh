#!/bin/bash
# Install or update the native Beszel agent (and optionally the Docker socket proxy) on this host.
# Run as root:  bash install-agent.sh <env-file> [--with-docker-proxy]
#   <env-file>: HUB_URL, TOKEN, KEY (hub public key), optional SYSTEM_NAME and DOCKER_HOST.
#               Installed as /etc/beszel-agent/env (root 0600). Contains the agent token: never in Git.
# Idempotent. Verifies the release tarball against the pinned SHA-256. Never uses the upstream
# install script or .deb (both add the agent user to the docker group).
set -euo pipefail
VERSION=0.21.1
declare -A SHA=(
  [amd64]=3b6ee592632ec03b9a43312e99a40203a7b3d83fe40dd0c25acda1eb915ea7c0
  [arm64]=a6ea544976b9a74398ac88d5da5bb96813d9a2e353a37bbfdb6a903fa8ba1838
)
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ok()   { echo "ok    $*"; }
fail() { echo "FAILED: $*"; exit 1; }
[ "$(id -u)" = 0 ] || fail "run as root"
ENVSRC=${1:-}; PROXY=${2:-}
[ -n "$ENVSRC" ] && [ -s "$ENVSRC" ] || fail "usage: $0 <env-file> [--with-docker-proxy]"
ARCH=$(dpkg --print-architecture); [ -n "${SHA[$ARCH]:-}" ] || fail "unsupported arch $ARCH"
for k in HUB_URL TOKEN KEY; do grep -q "^$k=." "$ENVSRC" || fail "$ENVSRC lacks $k"; done

# user
getent group beszel >/dev/null || addgroup --quiet --system beszel
getent passwd beszel >/dev/null || adduser --quiet --system --ingroup beszel --no-create-home --home /nonexistent --shell /usr/sbin/nologin --gecos "Beszel agent" beszel
for g in docker disk sudo adm; do id -nG beszel | tr ' ' '\n' | grep -qx $g && fail "beszel is in group $g; refusing"; done
ok "user beszel (groups: $(id -nG beszel))"

# binary
cur=$(/usr/local/bin/beszel-agent -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
if [ "$cur" != "$VERSION" ]; then
  t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
  curl -fsSL -o "$t/a.tgz" "https://github.com/henrygd/beszel/releases/download/v$VERSION/beszel-agent_linux_${ARCH}.tar.gz"
  [ "$(sha256sum "$t/a.tgz" | cut -d' ' -f1)" = "${SHA[$ARCH]}" ] || fail "agent tarball checksum mismatch"
  tar -xzf "$t/a.tgz" -C "$t" beszel-agent
  install -m 0755 -o root -g root "$t/beszel-agent" /usr/local/bin/beszel-agent.new
  mv -f /usr/local/bin/beszel-agent.new /usr/local/bin/beszel-agent
fi
ok "binary $(/usr/local/bin/beszel-agent -v 2>&1 | head -1)"

# config + unit
install -d -m 0755 /etc/beszel-agent
[ "$(readlink -f "$ENVSRC")" = /etc/beszel-agent/env ] || install -m 0600 -o root -g root "$ENVSRC" /etc/beszel-agent/env
install -m 0644 "$HERE/beszel-agent.service" /etc/systemd/system/beszel-agent.service
echo 'd /run/beszel-docker 0750 64001 beszel -' > /etc/tmpfiles.d/beszel-docker.conf
systemd-tmpfiles --create /etc/tmpfiles.d/beszel-docker.conf

# docker proxy (optional)
if [ "$PROXY" = --with-docker-proxy ]; then
  gid=$(getent group docker | cut -d: -f3); [ -n "$gid" ] || fail "no docker group"
  DOCKER_GID=$gid docker compose -f "$HERE/../compose/socket-proxy/compose.yaml" up -d --quiet-pull
  for i in $(seq 1 20); do [ -S /run/beszel-docker/docker.sock ] && break; sleep 1; done
  [ -S /run/beszel-docker/docker.sock ] || fail "proxy socket missing"
  ok "socket proxy up"
fi

systemctl daemon-reload
systemctl enable beszel-agent >/dev/null 2>&1
systemctl restart beszel-agent
sleep 3
[ "$(systemctl is-active beszel-agent)" = active ] || { journalctl -u beszel-agent -n 20 --no-pager; fail "agent not active"; }
ok "beszel-agent active; listening sockets: $(ss -tlnpH | grep -c beszel-agent || true) (expect 0)"
