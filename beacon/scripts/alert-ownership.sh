#!/bin/bash
# Transfer the existing Beszel alert rules between your dashboard account and the automation account,
# in place (same records and IDs). README "Automation (API)". Run on dsserver as daniel:
#   bash /srv/stacks/beacon/scripts/alert-ownership.sh check      read-only checks, changes nothing
#   bash /srv/stacks/beacon/scripts/alert-ownership.sh migrate    admin@beacon.lan -> automation@beacon.lan
#   bash /srv/stacks/beacon/scripts/alert-ownership.sh rollback   back to admin@beacon.lan (same IDs)
# Runs scripts/alert_owner.py on Beacon as root. migrate/rollback use a temporary PocketBase superuser
# that is always deleted again and verified gone. No secret is printed.
set -euo pipefail
case "${1:-}" in check|migrate|rollback) ;; *) sed -n '2,8p' "$0"; exit 2;; esac
cmp -s /srv/stacks/beacon/scripts/alert_owner.py <(ssh beacon 'sudo cat /srv/beacon/scripts/alert_owner.py') \
  || { echo "FAILED: Beacon's alert_owner.py differs from the repository (run scripts/deploy.sh)"; exit 1; }
ssh beacon "sudo python3 -I /srv/beacon/scripts/alert_owner.py $1"
