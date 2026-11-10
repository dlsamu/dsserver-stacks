#!/bin/bash
# Enable Beszel's built-in outbound heartbeat to Healthchecks.io (detects Beacon or the hub dying).
# 1. In Healthchecks.io create check "beacon": period 5 min, grace 10 min (the hub pings every 60 s).
# 2. On dsserver:  umask 077; nano ~/.beacon-ping-url.tmp   (paste the ping URL, save)
# 3. Run on dsserver:  bash /srv/stacks/beacon/scripts/set-heartbeat.sh
# Writes HEARTBEAT_URL into /srv/beacon/compose/beszel/hub.env on Beacon (root 0600, never in Git),
# recreates the hub, and deletes the temporary file. The URL is never printed.
set -euo pipefail
F=~/.beacon-ping-url.tmp
[ -s "$F" ] || { echo "missing $F"; exit 1; }
URL=$(tr -d '[:space:]' < "$F")
[[ $URL =~ ^https://hc-ping\.com/[A-Za-z0-9/_-]+$ ]] || { echo "not a hc-ping.com URL"; exit 1; }
printf 'HEARTBEAT_URL=%s\nHEARTBEAT_INTERVAL=60\nHEARTBEAT_METHOD=POST\n' "$URL" | \
  ssh beacon 'sudo sh -c "umask 077; cat > /srv/beacon/compose/beszel/hub.env" &&
              sudo docker compose -f /srv/beacon/compose/beszel/compose.yaml up -d --quiet-pull 2>&1 | grep -v Pseudo; sleep 15;
              sudo docker logs --since 2m beszel-hub 2>&1 | grep -i heartbeat | sed -E "s#hc-ping.com/[^ \"]+#hc-ping.com/<hidden>#g"'
rm -f "$F"
echo "done: check that the 'beacon' check in Healthchecks.io turns green within a minute"
