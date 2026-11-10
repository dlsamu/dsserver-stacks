#!/bin/bash
# dsserver A2: native host-health heartbeat to Healthchecks.io (systemd timer, HTTPS, strict timeouts).
# Record: host/docs/host-config.md §10. Design: docs/monitoring-architecture.md. Independent of Docker.
#
# Usage (as root, in Konsole - NOT through the chat's "!" prefix; each step stops on the first failed check):
#   sudo bash 08-health-heartbeat.sh preflight     read-only checks
#   sudo bash 08-health-heartbeat.sh install       install script + units (timer NOT enabled), local report
#   sudo bash 08-health-heartbeat.sh set-url       paste the private ping URL (hidden input, never displayed)
#   sudo bash 08-health-heartbeat.sh enable        send one ping, then enable the 5-minute timer
#   sudo bash 08-health-heartbeat.sh test-fail     raise the test flag and ping  -> expect a "down" email
#   sudo bash 08-health-heartbeat.sh test-recover  clear the test flag and ping  -> expect an "up" email
#   sudo bash 08-health-heartbeat.sh test-silence  stop the timer (no pings)     -> "down" email after ~15 min
#   sudo bash 08-health-heartbeat.sh test-resume   start the timer again + ping  -> "up" email
#   sudo bash 08-health-heartbeat.sh status        read-only: timer, last runs, local report
#   sudo bash 08-health-heartbeat.sh rollback      remove everything this script installed, incl. the URL file
# The tests touch only this heartbeat: no other service is stopped, started or changed.
# Writes nothing inside the repository.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../.." && pwd)
SRC_BIN=$REPO/host/bin/dsserver-health
SRC_SVC=$REPO/host/files/etc/systemd/system/dsserver-health.service
SRC_TMR=$REPO/host/files/etc/systemd/system/dsserver-health.timer
DST_BIN=/usr/local/sbin/dsserver-health
DST_SVC=/etc/systemd/system/dsserver-health.service
DST_TMR=/etc/systemd/system/dsserver-health.timer
CONF_DIR=/etc/dsserver-health
CONF=$CONF_DIR/ping-url
FLAG=/run/dsserver-health-test-fail
URL_RE='^https://hc-ping\.com/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }
[ "$(id -u)" = 0 ] || fail "run with sudo"
CMD=${1:-}; [ $# -eq 1 ] || CMD=""

same_or_absent() { [ ! -e "$2" ] || cmp -s "$1" "$2" || fail "$2 exists and differs from the repository copy"; }
need_installed() { for f in "$DST_BIN" "$DST_SVC" "$DST_TMR"; do [ -f "$f" ] || fail "$f missing - run 'install' first"; done; }
need_url() { [ -f "$CONF" ] && [ "$(stat -c '%U:%G %a' "$CONF")" = "root:root 600" ] || fail "$CONF missing or not root 0600 - run 'set-url' first"; }

# Run the service once and show what it logged (the log never contains the URL).
ping_once() {
    local expect=$1 since
    since=$(date '+%Y-%m-%d %H:%M:%S')
    systemctl start dsserver-health.service || true
    local res; res=$(systemctl show -p Result --value dsserver-health.service)
    local log; log=$(journalctl -u dsserver-health.service --since "$since" -o cat --no-pager)
    echo "$log" | sed 's/^/  | /'
    [ "$res" = success ] || fail "the ping was not delivered (result: $res)"
    [[ $log == *"sent: status=$expect"* ]] || fail "expected 'sent: status=$expect' in the log"
    ok "ping delivered with status=$expect"
}

preflight() {
    step "Preflight (read-only)"
    for c in curl smartctl systemctl journalctl; do command -v "$c" >/dev/null || fail "$c not found"; done
    ok "curl, smartctl, systemctl present"
    for f in "$SRC_BIN" "$SRC_SVC" "$SRC_TMR"; do [ -f "$f" ] || fail "repository file missing: $f"; done
    same_or_absent "$SRC_BIN" "$DST_BIN"; same_or_absent "$SRC_SVC" "$DST_SVC"; same_or_absent "$SRC_TMR" "$DST_TMR"
    ok "no conflicting installed files"
    if [ -x /usr/local/sbin/dsserver-reboot-needed ]; then ok "dsserver-reboot-needed present (A1)"
    else echo "note  dsserver-reboot-needed missing: reboot info will be omitted until A1 is installed"; fi
    for s in update-stamp upgrade-stamp; do
        [ -f "/var/lib/apt/periodic/$s" ] || echo "note  /var/lib/apt/periodic/$s missing: the first pings will report updates_stale until A1 has run once ('07 ... run-now')"
    done
    echo; echo "08 PREFLIGHT PASSED (nothing changed)"
}

install_all() {
    preflight
    step "Install script and units (timer stays disabled)"
    [ -e "$DST_BIN" ] || install -m 0755 -o root -g root "$SRC_BIN" "$DST_BIN"
    [ -e "$DST_SVC" ] || install -m 0644 -o root -g root "$SRC_SVC" "$DST_SVC"
    [ -e "$DST_TMR" ] || install -m 0644 -o root -g root "$SRC_TMR" "$DST_TMR"
    [ -d "$CONF_DIR" ] || install -d -m 0700 -o root -g root "$CONF_DIR"
    [ "$(stat -c '%U:%G %a' "$CONF_DIR")" = "root:root 700" ] || fail "$CONF_DIR must be root:root 0700"
    systemctl daemon-reload
    systemd-analyze verify "$DST_SVC" "$DST_TMR" || fail "systemd-analyze verify reported problems"
    ok "installed and verified; timer state: $(systemctl is-enabled dsserver-health.timer 2>/dev/null || true)"
    step "Local report (no network)"
    "$DST_BIN" --dry-run || true
    echo; echo "08 INSTALL PASSED. Next: create the check on healthchecks.io, then 'set-url'."
}

set_url() {
    [ -t 0 ] || fail "set-url needs an interactive terminal (Konsole)"
    [ -d "$CONF_DIR" ] || fail "$CONF_DIR missing - run 'install' first"
    if [ -e "$CONF" ]; then
        read -r -p "A ping URL is already stored. Replace it? [y/N] " a; [ "$a" = y ] || fail "kept the existing URL"
    fi
    echo "Paste the ping URL from healthchecks.io (https://hc-ping.com/<uuid>). Input is hidden."
    local u; read -r -s -p "Ping URL: " u; echo
    u=${u%$'\r'}
    [[ $u =~ $URL_RE ]] || { unset u; fail "that is not an https://hc-ping.com/<uuid> URL (nothing stored)"; }
    local tmp; tmp=$(umask 077; mktemp "$CONF_DIR/.ping-url.XXXXXX")
    printf '%s\n' "$u" >"$tmp"; unset u
    chmod 0600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$CONF"
    [ "$(stat -c '%U:%G %a' "$CONF")" = "root:root 600" ] || fail "$CONF permissions"
    ok "stored in $CONF (root 0600, $(stat -c %s "$CONF") bytes). It is not displayed."
}

enable_timer() {
    need_installed; need_url
    step "First ping (state as it is now)"
    local st=ok; "$DST_BIN" --report >/dev/null 2>&1 || st=fail
    ping_once "$st"
    [ "$st" = ok ] || echo "note  the host currently reports a problem; see 'status'. The check will show down until it clears."
    step "Enable the timer"
    systemctl enable --now dsserver-health.timer
    systemctl list-timers dsserver-health.timer --no-pager
    echo; echo "08 ENABLE PASSED. Healthchecks.io should now show the check as up (if status was ok)."
}

test_fail() {
    need_installed; need_url
    step "Test failure: raise the flag (touches nothing else)"
    install -m 0644 -o root -g root /dev/null "$FLAG"
    ping_once fail
    echo "Expect a \"down\" email for this check within a minute or two. Then run: test-recover"
}

test_recover() {
    need_installed; need_url
    step "Test recovery: clear the flag"
    rm -f -- "$FLAG"
    ping_once ok
    echo "Expect an \"up\" email. If the status is not ok, see 'status' for the real problem."
}

test_silence() {
    need_installed
    step "Test a missed heartbeat: stop the timer (the service itself is not touched)"
    systemctl stop dsserver-health.timer
    echo "No pings will be sent now. After period + grace (5 + 10 min) Healthchecks sends a \"down\" email."
    echo "Then run: test-resume   (the timer is still enabled, so a reboot would also resume it)"
}

test_resume() {
    need_installed; need_url
    step "Resume the heartbeat"
    systemctl start dsserver-health.timer
    local st=ok; "$DST_BIN" --report >/dev/null 2>&1 || st=fail
    ping_once "$st"
    echo "Expect an \"up\" email (if status is ok)."
}

status() {
    step "Timer"; systemctl list-timers dsserver-health.timer --no-pager || true
    echo "enabled: $(systemctl is-enabled dsserver-health.timer 2>/dev/null || true)"
    echo "test flag: $([ -e "$FLAG" ] && echo PRESENT || echo absent)"
    echo "ping URL file: $([ -f "$CONF" ] && stat -c '%U:%G %a' "$CONF" || echo missing)"
    step "Last runs"; journalctl -u dsserver-health.service -n 12 -o short-iso --no-pager || true
    step "Local report"
    if [ -x "$DST_BIN" ]; then "$DST_BIN" --dry-run || true; else echo "$DST_BIN not installed"; fi
}

rollback() {
    step "Rollback: remove only what this script installed"
    systemctl disable --now dsserver-health.timer 2>/dev/null || true
    systemctl stop dsserver-health.service 2>/dev/null || true
    rm -f -- "$DST_TMR" "$DST_SVC" "$DST_BIN" "$FLAG"
    if [ -d "$CONF_DIR" ]; then rm -f -- "$CONF" "$CONF_DIR"/.ping-url.*; rmdir -- "$CONF_DIR"; fi
    systemctl daemon-reload
    systemctl reset-failed dsserver-health.service 2>/dev/null || true
    for f in "$DST_TMR" "$DST_SVC" "$DST_BIN" "$CONF_DIR" "$FLAG"; do [ ! -e "$f" ] || fail "$f still present"; done
    echo; echo "08 ROLLBACK DONE. Also delete (or pause) the check on healthchecks.io, or it will report down."
}

case $CMD in
    preflight) preflight ;;
    install) install_all ;;
    set-url) set_url ;;
    enable) enable_timer ;;
    test-fail) test_fail ;;
    test-recover) test_recover ;;
    test-silence) test_silence ;;
    test-resume) test_resume ;;
    status) status ;;
    rollback) rollback ;;
    *) echo "usage: sudo bash $0 preflight|install|set-url|enable|test-fail|test-recover|test-silence|test-resume|status|rollback" >&2; exit 2 ;;
esac
