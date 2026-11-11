#!/bin/bash
# netwatch on Beacon (root): install/update the units and enable the timer. Idempotent.
#   sudo bash /srv/beacon/netwatch/install.sh            install + enable + first collection
#   sudo bash /srv/beacon/netwatch/install.sh remove     disable + remove units (history in /srv/appdata/netwatch kept)
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
if [ "${1:-}" = remove ]; then
    systemctl disable --now netwatch-collect.timer 2>/dev/null || true
    rm -f /etc/systemd/system/netwatch-collect.service /etc/systemd/system/netwatch-collect.timer
    systemctl daemon-reload; echo "netwatch units removed (history kept in /srv/appdata/netwatch)"; exit 0
fi
install -d -m 0700 -o root -g root /srv/appdata/netwatch
install -m 0644 "$HERE/netwatch-collect.service" "$HERE/netwatch-collect.timer" /etc/systemd/system/
systemd-analyze verify /etc/systemd/system/netwatch-collect.service /etc/systemd/system/netwatch-collect.timer
systemctl daemon-reload
systemctl start netwatch-collect.service
for _ in $(seq 60); do case $(systemctl show -p ActiveState --value netwatch-collect.service) in active|activating) sleep 1 ;; *) break ;; esac; done
systemctl show -p Result --value netwatch-collect.service | grep -qx success || { journalctl -u netwatch-collect -n 5 --no-pager; exit 1; }
systemctl enable --now netwatch-collect.timer >/dev/null 2>&1
echo "netwatch installed: timer $(systemctl is-enabled netwatch-collect.timer)"; systemctl list-timers netwatch-collect.timer --no-pager | sed -n 2p
