#!/bin/bash
# Update Beszel (hub + agents) to a pinned release. Run on dsserver as daniel:
#   bash /srv/stacks/beacon/scripts/update-beszel.sh 0.22.0      # read the release notes first
# 1. Re-pins the hub image digest and the agent tarball SHA-256s from Docker Hub / GitHub release
#    metadata, shows the diff and asks before continuing.
# 2. Backs up the hub data (scripts/backup-hub.sh), deploys the hub, updates Beacon's agent.
# 3. Prints the one sudo command for dsserver's agent (needs your password).
# Rollback: git checkout the previous commit of /srv/stacks/beacon, run deploy.sh, and if the data
# format changed restore the backup taken in step 2 (see README "Restore").
set -euo pipefail
V=${1:?usage: $0 <version, e.g. 0.22.0>}
B=/srv/stacks/beacon
IDX=$(curl -fsSL "https://hub.docker.com/v2/repositories/henrygd/beszel/tags/$V" | jq -r .digest)
[[ $IDX == sha256:* ]] || { echo "no hub image $V"; exit 1; }
REL=$(curl -fsSL "https://api.github.com/repos/henrygd/beszel/releases/tags/v$V")
A64=$(jq -r '.assets[] | select(.name=="beszel-agent_linux_arm64.tar.gz") | .digest' <<<"$REL" | sed 's/^sha256://')
X64=$(jq -r '.assets[] | select(.name=="beszel-agent_linux_amd64.tar.gz") | .digest' <<<"$REL" | sed 's/^sha256://')
[[ ${#A64} = 64 && ${#X64} = 64 ]] || { echo "agent checksums not found for v$V"; exit 1; }
sed -i -E "s#henrygd/beszel:[0-9.]+@sha256:[0-9a-f]{64}#henrygd/beszel:$V@$IDX#" $B/compose/beszel/compose.yaml
sed -i -E "s#^VERSION=.*#VERSION=$V#; s#^(  \[arm64\]=)[0-9a-f]{64}#\1$A64#; s#^(  \[amd64\]=)[0-9a-f]{64}#\1$X64#" $B/agent/install-agent.sh
git -C /srv/stacks diff --stat -- beacon; git -C /srv/stacks diff -U0 -- beacon/compose/beszel/compose.yaml beacon/agent/install-agent.sh | grep '^[-+][^-+]'
read -r -p "Deploy Beszel $V now? [y/N] " a; [ "$a" = y ] || { echo "not deployed (pins changed in the working tree; 'git -C /srv/stacks checkout beacon' to undo)"; exit 1; }
bash $B/scripts/backup-hub.sh
bash $B/scripts/deploy.sh
ssh beacon 'sudo bash /srv/beacon/agent/install-agent.sh /etc/beszel-agent/env --with-docker-proxy'
echo; echo "Beacon updated. dsserver agent (needs your sudo password):"
echo "  sudo bash /srv/stacks/beacon/agent/install-agent.sh /etc/beszel-agent/env --with-docker-proxy"
echo "Then commit: git -C /srv/stacks commit -am 'Beszel $V' && git -C /srv/stacks push"
