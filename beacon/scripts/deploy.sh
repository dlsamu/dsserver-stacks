#!/bin/bash
# Copy /srv/stacks/beacon to Beacon (/srv/beacon) and (re)start the hub. Run on dsserver as daniel.
# Idempotent; containers are only recreated when their compose definition changed.
# Not copied: images/ (OS image), and nothing secret lives in this directory.
set -euo pipefail
SRC=/srv/stacks/beacon/
rsync -a --delete --rsync-path="sudo rsync" --exclude images/ --exclude '*.log' \
      --exclude 'compose/beszel/hub.env' --chown=root:root --chmod=D755,F644 "$SRC" beacon:/srv/beacon/
ssh beacon 'sudo chmod 0755 /srv/beacon/agent/install-agent.sh /srv/beacon/firewall/apply.sh /srv/beacon/netwatch/install.sh /srv/beacon/scripts/*.sh
  sudo install -d -m 0700 -o 10001 -g 10001 /srv/appdata/beszel
  sudo docker compose -f /srv/beacon/compose/beszel/compose.yaml up -d --quiet-pull --remove-orphans
  sudo docker compose -f /srv/beacon/compose/beszel/compose.yaml ps --format "{{.Name}} {{.Image}} {{.Status}}"'
