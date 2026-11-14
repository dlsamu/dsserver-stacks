#!/bin/bash
# Copy /srv/stacks/backup to Beacon (/srv/hostbackup, root-owned) and run one step there. Run on dsserver as daniel.
#   bash backup/deploy-beacon.sh preflight|install-restic|init|units-install|backup|check|fullcheck|prune|drill|test|status|snapshots|mount-test
# Jobs (backup..drill) are started through their systemd unit, like the timers do.
set -euo pipefail
CMD=${1:?usage: $0 preflight|install-restic|init|units-install|backup|check|fullcheck|prune|drill|test|status|snapshots|mount-test}
rsync -a --delete --rsync-path="sudo rsync" --exclude __pycache__/ --exclude '*.md' \
      --chown=root:root --chmod=D755,F644 /srv/stacks/backup/ beacon:/srv/hostbackup/
P=/srv/hostbackup
case $CMD in
  install-restic) ssh beacon 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends restic cifs-utils >/dev/null && restic version' ;;
  units-install)  ssh beacon "sudo python3 -I $P/install-units.py $P/hostbackup.py" ;;
  test)           ssh beacon "sudo python3 -I $P/tests/test_hostbackup.py" ;;
  backup|check|fullcheck|prune|drill)
    ssh beacon "u=hostbackup@$CMD.service; s=\$(date '+%F %T'); sudo systemctl reset-failed \$u 2>/dev/null; sudo systemctl start \$u;
      while systemctl is-active -q \$u || [ \"\$(systemctl is-active \$u)\" = activating ]; do sleep 5; done
      journalctl -u \$u --since \"\$s\" --no-pager -o cat | grep -vE '^(Started|Starting|Finished|hostbackup@)'; r=\$(systemctl show -p Result --value \$u); echo \"unit result: \$r\"; [ \"\$r\" = success ]" ;;
  *) ssh beacon "sudo python3 -I $P/hostbackup.py $CMD" ;;
esac
