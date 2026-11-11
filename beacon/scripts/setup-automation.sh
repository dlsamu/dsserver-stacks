#!/bin/bash
# ONE-TIME: create the Beszel automation account (README "Automation (API)"). Run on dsserver as daniel:
#   bash /srv/stacks/beacon/scripts/setup-automation.sh --migrate-alerts
# Runs scripts/bootstrap_automation.py on Beacon as root. It uses a temporary PocketBase superuser
# that exists only for the few seconds this takes and is deleted again (also on errors).
# --migrate-alerts moves the existing alert rules to the automation account (identical copies are
# made and checked first), so `bz` can change them; without it they stay on your account.
# Your personal account is not used, read or changed. No secret is printed.
set -euo pipefail
case "${1:-}" in --migrate-alerts|"") ;; *) echo "usage: $0 [--migrate-alerts]"; exit 2;; esac
bash /srv/stacks/beacon/scripts/deploy.sh >/dev/null
ssh beacon 'sudo docker inspect -f "{{range .Config.Env}}{{println .}}{{end}}" beszel-hub' | grep -qx 'SHARE_ALL_SYSTEMS=true' \
  || { echo "FAILED: hub is not running with SHARE_ALL_SYSTEMS=true"; exit 1; }
echo "ok    hub deployed with SHARE_ALL_SYSTEMS=true"
for i in $(seq 1 30); do [ "$(ssh beacon 'sudo docker inspect -f "{{.State.Health.Status}}" beszel-hub')" = healthy ] && break; sleep 2; done
ssh -t beacon "sudo python3 -I /srv/beacon/scripts/bootstrap_automation.py ${1:-}"
echo; echo "Next: tell Claude 'bootstrap done'. Check anytime: bash /srv/stacks/beacon/scripts/bz systems"
