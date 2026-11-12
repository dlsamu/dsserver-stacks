#!/bin/bash
# dsserver: narrowly scoped passwordless sudo for approved, scripted admin operations.
# Record: host/docs/host-config.md §11.
#
# Why: routine approved operations (e.g. A1) can then be run by daniel's non-interactive tools
# without a password, WITHOUT giving daniel general passwordless root.
#
# How it stays narrow:
#   1. The allowed scripts are copied from the reviewed COMMIT (git objects, not the working
#      tree) into a root-owned snapshot: /usr/local/lib/dsserver-admin (root:root, not writable by
#      daniel). Editing the repository therefore changes nothing until you run 'install' again.
#   2. /etc/sudoers.d/dsserver-delegated allows ONLY the exact command lines listed in COMMANDS below
#      (script path + one fixed argument). No wildcards, no shells, no editors, no systemctl.
#   3. The file is syntax-checked with visudo before it is put in place; sudo's env_reset still applies.
#
# Usage (as root, in Konsole):
#   sudo bash 09-delegated-sudo.sh show       read-only: print the snapshot plan and the sudoers rule
#   sudo bash 09-delegated-sudo.sh install <commit>
#                                             (re)create the snapshot and the sudoers rule; <commit> is the
#                                             FULL 40-character hash you reviewed. Refuses unless HEAD equals
#                                             it and the working tree is clean; files are read from that
#                                             commit object (not from HEAD or the working tree).
#   sudo bash 09-delegated-sudo.sh remove     delete the sudoers rule and the snapshot
#
# Afterwards daniel runs, e.g.:  sudo -n /usr/local/lib/dsserver-admin/host/scripts/07-unattended-upgrades.sh verify
set -euo pipefail

REPO=/srv/stacks
OWNER=daniel
SNAP=/usr/local/lib/dsserver-admin
RULE=/etc/sudoers.d/dsserver-delegated

# Files copied into the snapshot (repository paths). Executables get 0755, the rest 0644.
FILES=(
    host/scripts/07-unattended-upgrades.sh
    host/files/etc/apt/apt.conf.d/52dsserver-unattended-upgrades
    host/bin/dsserver-reboot-needed
    host/scripts/08-health-heartbeat.sh
    host/bin/dsserver-health
    host/files/etc/systemd/system/dsserver-health.service
    host/files/etc/systemd/system/dsserver-health.timer
    host/scripts/10-firewall.sh
    host/files/etc/dsserver-firewall.nft
    host/files/etc/systemd/system/dsserver-firewall.service
    host/scripts/13-beszel-agent.sh
    beacon/agent/install-agent.sh
    beacon/agent/beszel-agent.service
    beacon/compose/socket-proxy/compose.yaml
    host/scripts/14-https-proxy.sh
    proxy/compose.yaml
    proxy/Caddyfile
    beacon/compose/caddy/Dockerfile
    host/scripts/15-stockpulse.sh
    stockpulse/SOURCE
    stockpulse/Dockerfile
    stockpulse/compose.yaml
    stockpulse/systemd/stockpulse-job@.service
    stockpulse/systemd/stockpulse-us.timer
    stockpulse/systemd/stockpulse-intl.timer
    stockpulse/systemd/stockpulse-ath.timer
    stockpulse/systemd/stockpulse-backup.service
    stockpulse/systemd/stockpulse-backup.timer
    stockpulse/systemd/stockpulse-check.service
    stockpulse/systemd/stockpulse-check.timer
    stockpulse/check.py
)
EXEC_FILES=" host/scripts/07-unattended-upgrades.sh host/bin/dsserver-reboot-needed host/scripts/08-health-heartbeat.sh host/bin/dsserver-health host/scripts/10-firewall.sh host/scripts/13-beszel-agent.sh host/scripts/14-https-proxy.sh host/scripts/15-stockpulse.sh "

# Exact command lines daniel may run as root without a password.
# A1: everything except 'rollback' (rollback stays a manual, deliberate step).
COMMANDS=(
    "host/scripts/07-unattended-upgrades.sh preflight"
    "host/scripts/07-unattended-upgrades.sh install"
    "host/scripts/07-unattended-upgrades.sh verify"
    "host/scripts/07-unattended-upgrades.sh status"
    "host/scripts/07-unattended-upgrades.sh hold"
    "host/scripts/07-unattended-upgrades.sh release"
    "host/scripts/07-unattended-upgrades.sh run-now"
# A2: not 'set-url' (needs your terminal for the hidden URL) and not 'rollback'.
    "host/scripts/08-health-heartbeat.sh preflight"
    "host/scripts/08-health-heartbeat.sh install"
    "host/scripts/08-health-heartbeat.sh update"
    "host/scripts/08-health-heartbeat.sh enable"
    "host/scripts/08-health-heartbeat.sh status"
    "host/scripts/08-health-heartbeat.sh test-fail"
    "host/scripts/08-health-heartbeat.sh test-recover"
    "host/scripts/08-health-heartbeat.sh test-silence"
    "host/scripts/08-health-heartbeat.sh test-resume"
# A3: not 'revert' or 'rollback' (turning the firewall off stays with you; the automatic revert covers tests).
    "host/scripts/10-firewall.sh preflight"
    "host/scripts/10-firewall.sh selftest-revert"
    "host/scripts/10-firewall.sh try"
    "host/scripts/10-firewall.sh confirm"
    "host/scripts/10-firewall.sh verify"
    "host/scripts/10-firewall.sh status"
    "host/scripts/10-firewall.sh docker-test-start"
    "host/scripts/10-firewall.sh docker-test-allow"
    "host/scripts/10-firewall.sh docker-test-stop"
# O1/O2 Beszel agent + Docker socket proxy: fixed arguments only; no removal.
    "host/scripts/13-beszel-agent.sh preflight"
    "host/scripts/13-beszel-agent.sh install"
    "host/scripts/13-beszel-agent.sh verify"
    "host/scripts/13-beszel-agent.sh log-scan"
    "host/scripts/13-beszel-agent.sh status"
    "host/scripts/13-beszel-agent.sh test-recovery"
    # HTTPS proxy (Caddy, proxy/): fixed arguments; the Caddyfile comes from the reviewed snapshot.
    "host/scripts/14-https-proxy.sh preflight"
    "host/scripts/14-https-proxy.sh token-install"
    "host/scripts/14-https-proxy.sh token-check"
    "host/scripts/14-https-proxy.sh dns-ensure"
    "host/scripts/14-https-proxy.sh build"
    "host/scripts/14-https-proxy.sh up"
    "host/scripts/14-https-proxy.sh verify"
    "host/scripts/14-https-proxy.sh status"
    "host/scripts/14-https-proxy.sh down"
    # StockPulse (stockpulse/): 'job' and 'timers-enable' are production actions, used only after approval.
    "host/scripts/15-stockpulse.sh preflight"
    "host/scripts/15-stockpulse.sh build"
    "host/scripts/15-stockpulse.sh import"
    "host/scripts/15-stockpulse.sh up"
    "host/scripts/15-stockpulse.sh verify"
    "host/scripts/15-stockpulse.sh status"
    "host/scripts/15-stockpulse.sh test-reset"
    "host/scripts/15-stockpulse.sh run-test us"
    "host/scripts/15-stockpulse.sh run-test intl"
    "host/scripts/15-stockpulse.sh run-test ath"
    "host/scripts/15-stockpulse.sh push-test"
    "host/scripts/15-stockpulse.sh job us"
    "host/scripts/15-stockpulse.sh job intl"
    "host/scripts/15-stockpulse.sh job ath"
    "host/scripts/15-stockpulse.sh backup"
    "host/scripts/15-stockpulse.sh check"
    "host/scripts/15-stockpulse.sh test-recovery"
    "host/scripts/15-stockpulse.sh check-test-fail"
    "host/scripts/15-stockpulse.sh check-test-clear"
    "host/scripts/15-stockpulse.sh check-enable"
    "host/scripts/15-stockpulse.sh check-now"
    "host/scripts/15-stockpulse.sh test-build"
    "host/scripts/15-stockpulse.sh test-run us"
    "host/scripts/15-stockpulse.sh test-run intl"
    "host/scripts/15-stockpulse.sh test-run ath"
    "host/scripts/15-stockpulse.sh test-clean"
    "host/scripts/15-stockpulse.sh units-install"
    "host/scripts/15-stockpulse.sh backup-enable"
    "host/scripts/15-stockpulse.sh timer-enable us"
    "host/scripts/15-stockpulse.sh timer-enable intl"
    "host/scripts/15-stockpulse.sh timer-enable ath"
    "host/scripts/15-stockpulse.sh timer-disable us"
    "host/scripts/15-stockpulse.sh timer-disable intl"
    "host/scripts/15-stockpulse.sh timer-disable ath"
    "host/scripts/15-stockpulse.sh timers-enable"
    "host/scripts/15-stockpulse.sh timers-disable"
    "host/scripts/15-stockpulse.sh down"
)

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
ok()   { echo "ok    $*"; }
[ "$(id -u)" = 0 ] || fail "run with sudo"
CMD=${1:-}; ARG=${2:-}
case "$CMD:$#" in show:1|remove:1|install:2) ;; *) CMD="" ;; esac

# git runs as the repository owner (never as root), with that user's HOME.
git_as_owner() { runuser -u "$OWNER" -- env HOME="/home/$OWNER" git --no-replace-objects -C "$REPO" "$@"; }

rule_text() {
    local commit=$1 c first=1
    echo "# Managed by $REPO/host/scripts/09-delegated-sudo.sh - do not edit by hand."
    echo "# Snapshot of commit $commit in $SNAP (root-owned). Exact command lines only."
    printf 'Cmnd_Alias DSSERVER_DELEGATED = '
    for c in "${COMMANDS[@]}"; do
        [ $first = 1 ] || printf ', \\\n    '
        printf '%s' "$SNAP/$c"; first=0
    done
    echo
    echo "$OWNER ALL=(root) NOPASSWD: DSSERVER_DELEGATED"
}

show() {
    local commit; commit=$(git_as_owner rev-parse --short HEAD)
    echo "Snapshot source: $REPO at commit $commit (committed content only)"
    for f in "${FILES[@]}"; do echo "  $f -> $SNAP/$f"; done
    echo; echo "Sudoers rule ($RULE):"; rule_text "$commit" | sed 's/^/  /'
}

install_all() {
    command -v visudo >/dev/null || fail "visudo not found"
    local full; full=$(git_as_owner rev-parse HEAD)
    [[ $ARG =~ ^[0-9a-f]{40}$ ]] || fail "give the full 40-character commit hash you reviewed (nothing changed)"
    [ "$full" = "$ARG" ] || fail "HEAD is $full, not the reviewed commit $ARG (nothing changed)"
    local commit=$full
    local dirty; dirty=$(git_as_owner status --porcelain --untracked-files=all)
    [ -z "$dirty" ] || fail "working tree is not clean (nothing changed):
$dirty"
    ok "HEAD = reviewed commit $full, working tree clean"

    # Build the snapshot next to the final location, then swap it in.
    local tmp; tmp=$(mktemp -d "$SNAP.new.XXXXXX"); chmod 0755 "$tmp"
    trap 'rm -rf -- "$tmp"' EXIT
    local f mode
    for f in "${FILES[@]}"; do
        mode=0644; [[ $EXEC_FILES == *" $f "* ]] && mode=0755
        install -d -m 0755 -o root -g root "$tmp/$(dirname "$f")"
        git_as_owner show "$full:$f" >"$tmp/$f" || fail "$f not in commit $full"
        chown root:root "$tmp/$f"; chmod "$mode" "$tmp/$f"
    done
    rm -rf -- "$SNAP"; mv "$tmp" "$SNAP"; trap - EXIT
    [ "$(stat -c '%U %a' "$SNAP")" = "root 755" ] || fail "$SNAP ownership"
    local bad; bad=$(find "$SNAP" \( ! -user root -o ! -group root -o -perm /022 -o -type l \) -print)
    [ -z "$bad" ] || fail "$SNAP has entries that are links, not root:root, or group/world-writable: $bad"
    ok "snapshot of $commit in $SNAP:"
    (cd "$SNAP" && sha256sum "${FILES[@]}" | sed 's/^/      /')

    local rt; rt=$(mktemp)
    rule_text "$commit" >"$rt"
    visudo -cqf "$rt" || { rm -f "$rt"; fail "generated sudoers rule failed visudo check (nothing installed)"; }
    install -m 0440 -o root -g root "$rt" "$RULE"; rm -f "$rt"
    visudo -cq || { rm -f "$RULE"; fail "full sudoers check failed - rule removed again"; }
    ok "installed $RULE (visudo OK)"
    echo; echo "Allowed for $OWNER without password:"
    sudo -l -U "$OWNER" | sed 's/^/  /'
    echo; echo "09 INSTALL PASSED. Re-run 'install' after committing changes to the snapshot files."
}

remove() {
    rm -f -- "$RULE"; rm -rf -- "$SNAP"
    visudo -cq || fail "sudoers check failed after removal - inspect /etc/sudoers.d"
    [ ! -e "$RULE" ] && [ ! -e "$SNAP" ] || fail "something is still present"
    echo "09 REMOVE DONE: no delegated passwordless commands remain."
}

case $CMD in
    show) show ;;
    install) install_all ;;
    remove) remove ;;
    *) echo "usage: sudo bash $0 show | install <reviewed-commit> | remove" >&2; exit 2 ;;
esac
