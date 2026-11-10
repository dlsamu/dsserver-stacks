#!/bin/bash
# Beacon firewall: try (load + 5-minute automatic removal by PID 1) / confirm (install + enable) / status.
# Run on Beacon as root from /srv/beacon/firewall.
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
case ${1:-} in
  try)
    nft -c -f "$HERE/beacon-firewall.nft"
    systemctl stop beacon-fw-revert.timer 2>/dev/null || true; systemctl reset-failed beacon-fw-revert.service beacon-fw-revert.timer 2>/dev/null || true
    systemd-run --quiet --unit beacon-fw-revert --on-active=300 /usr/sbin/nft delete table inet beacon_fw
    nft -f "$HERE/beacon-firewall.nft"
    echo "loaded; automatic removal in 5 min unless 'confirm'" ;;
  confirm)
    install -m 0644 "$HERE/beacon-firewall.nft" /etc/beacon-firewall.nft
    install -m 0644 "$HERE/beacon-firewall.service" /etc/systemd/system/beacon-firewall.service
    systemctl daemon-reload; systemctl enable beacon-firewall.service >/dev/null 2>&1
    systemctl stop beacon-fw-revert.timer 2>/dev/null || true
    systemctl restart beacon-firewall.service
    echo "installed and enabled; revert timer cancelled" ;;
  status)
    systemctl is-enabled beacon-firewall.service 2>/dev/null || true; systemctl is-active beacon-fw-revert.timer 2>/dev/null || true
    nft list table inet beacon_fw 2>/dev/null | head -40 || echo "table not loaded" ;;
  *) echo "usage: $0 try|confirm|status"; exit 2 ;;
esac
