#!/bin/bash
# Consistent copy of the Beszel hub data (settings, users, systems, alerts, tokens, 30-day metrics).
# Stops the hub for a few seconds, archives /srv/appdata/beszel on Beacon, restarts it, and copies
# the archive to dsserver ~/beacon-backups/ (0600; contains the hub's private key and token hashes).
set -euo pipefail
D=~/beacon-backups; install -d -m 0700 "$D"
N=beszel-hub-$(date +%Y%m%d-%H%M%S).tar.gz
ssh beacon "sudo docker stop beszel-hub >/dev/null && sudo tar -C /srv/appdata -czf /root/$N beszel; rc=\$?; sudo docker start beszel-hub >/dev/null; exit \$rc"
ssh beacon "sudo cat /root/$N && sudo rm -f /root/$N" > "$D/$N"; chmod 600 "$D/$N"
LIST=$(tar -tzf "$D/$N")   # captured first: never pipe into grep -q under pipefail (SIGPIPE)
grep -qx 'beszel/data.db' <<<"$LIST" || { echo "backup looks wrong: $D/$N"; exit 1; }
ls -1t "$D"/beszel-hub-*.tar.gz | tail -n +11 | xargs -r rm -f    # keep the newest 10
echo "backup: $D/$N ($(du -h "$D/$N" | cut -f1))"
