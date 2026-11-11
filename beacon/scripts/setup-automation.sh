#!/bin/bash
# ONE-TIME: create the Beszel automation account (README "Automation (API)"). Run on dsserver as daniel:
#   bash /srv/stacks/beacon/scripts/setup-automation.sh
# Runs scripts/bootstrap_automation.py on Beacon as root (via your existing `ssh beacon` access).
# It creates ONLY automation@beacon.lan and that account's own notification settings, using a
# temporary PocketBase superuser that is deleted again (success or failure) and verified gone.
# Existing alerts, your account, notification settings, systems, network checks and history are
# snapshotted before and compared after. No secret is printed. Nothing is deployed or restarted.
set -euo pipefail
[ $# = 0 ] || { echo "usage: $0   (no options)"; exit 2; }
ssh beacon 'sudo docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" beszel-hub' | grep -qx 'SHARE_ALL_SYSTEMS=true' \
  || { echo "FAILED: hub is not running with SHARE_ALL_SYSTEMS=true (run scripts/deploy.sh first)"; exit 1; }
[ "$(ssh beacon 'sudo docker inspect -f "{{.State.Health.Status}}" beszel-hub')" = healthy ] || { echo "FAILED: hub not healthy"; exit 1; }
cmp -s /srv/stacks/beacon/scripts/bootstrap_automation.py <(ssh beacon 'sudo cat /srv/beacon/scripts/bootstrap_automation.py') \
  || { echo "FAILED: Beacon's copy of bootstrap_automation.py differs from the repository (run scripts/deploy.sh)"; exit 1; }
echo "ok    hub healthy, SHARE_ALL_SYSTEMS=true, bootstrap script on Beacon = repository copy"
ssh beacon 'sudo python3 -I /srv/beacon/scripts/bootstrap_automation.py'
echo; echo "Next: tell Claude 'bootstrap done'."
