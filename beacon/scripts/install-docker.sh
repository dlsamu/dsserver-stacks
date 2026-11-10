#!/bin/bash
# Beacon: Docker Engine + Compose from Docker's official Debian repository (arm64), like dsserver §3.
# Run from dsserver: ssh beacon 'sudo bash -s' < /srv/stacks/beacon/scripts/install-docker.sh
# Idempotent. daniel is NOT added to the docker group (use sudo docker).
set -euo pipefail
EXPECTED_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
KEY=/etc/apt/keyrings/docker.asc
fail() { echo "FAILED: $*"; exit 1; }
[ "$(hostname)" = beacon ] || fail "not beacon"
install -m 0755 -d /etc/apt/keyrings
if [ ! -e "$KEY" ]; then
    tmp=$(mktemp); curl -fsSL https://download.docker.com/linux/debian/gpg -o "$tmp"
    g=$(mktemp -d); fpr=$(GNUPGHOME=$g gpg --show-keys --with-colons "$tmp" | awk -F: '$1=="fpr"{print $10; exit}'); rm -rf "$g"
    [ "$fpr" = "$EXPECTED_FPR" ] || { rm -f "$tmp"; fail "Docker key fingerprint mismatch: $fpr"; }
    install -m 0644 "$tmp" "$KEY"; rm -f "$tmp"
fi
cat > /etc/apt/sources.list.d/docker.sources <<'S'
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: arm64
Signed-By: /etc/apt/keyrings/docker.asc
S
install -m 0755 -d /etc/docker
[ -e /etc/docker/daemon.json ] || printf '{\n  "log-driver": "local"\n}\n' > /etc/docker/daemon.json
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin >/dev/null
systemctl enable --now docker containerd >/dev/null
for p in docker-ce docker-compose-plugin; do apt-cache policy $p | awk -v p=$p '/Installed:/{i=$2} /\*\*\*/{getline; o=$2" "$3} END{print p, i, "<-", o}'; done
docker info --format 'logging={{.LoggingDriver}} storage={{.Driver}} cgroup={{.CgroupVersion}}'
