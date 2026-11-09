#!/bin/sh
# dsserver power management, Step 1 (approved). Run as root.
# Recreated 2026-11-09 from the reviewed original, which was lost when /tmp was cleared at reboot.
# The Plasma half of this change is per user (no root):
#   kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction 0
#   systemctl --user restart plasma-powerdevil.service
set -eu

install -d -m 0755 /etc/systemd/sleep.conf.d
cat > /etc/systemd/sleep.conf.d/90-dsserver-no-sleep.conf <<'EOF'
# dsserver: 24/7 Docker host — never suspend or hibernate.
# Revert: delete this file. See power-management notes in /srv/stacks/host (future).
[Sleep]
AllowSuspend=no
AllowHibernation=no
AllowHybridSleep=no
AllowSuspendThenHibernate=no
EOF
chmod 0644 /etc/systemd/sleep.conf.d/90-dsserver-no-sleep.conf

systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target

echo "Step 1 done."
