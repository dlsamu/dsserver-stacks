#!/bin/bash
# dsserver A3: host firewall (nftables table inet dsserver_fw) with a 10-minute automatic revert.
# Record: host/docs/host-config.md §12. Application access: docs/network-access.md.
#
# Usage (as root; each step stops on the first failed check):
#   preflight          read-only: ruleset syntax, interface/LAN, nftables.service off, current state
#   selftest-revert    prove the revert works without the calling session: load an EMPTY table
#                      (no chains, no effect on traffic), schedule its removal in 60 s, exit.
#                      Check with 'status' after a minute.
#   try                load the repository ruleset and schedule an automatic revert in 10 minutes
#                      (a systemd timer in PID 1: survives the end of this session, ssh drops, etc.)
#   confirm            cancel the revert, install the ruleset + unit, enable it at boot, then verify
#   verify             read-only: unit, files, loaded table, Docker's tables, nftables.service off
#   status             read-only: tables, revert timer, unit, recent drop log lines
#   docker-test-start  temporary container "dsserver-fwtest" publishing 18080 (busybox httpd),
#                      then container outbound / container->host checks
#   docker-test-allow  add 18080 to the LAN scope at RUNTIME only (gone on reload/revert/reboot)
#   docker-test-stop   remove the container, the runtime element and the test image
#   revert             (manual) run the pending revert now
#   rollback           (manual) disable and remove the firewall completely
# Writes nothing inside the repository.
set -euo pipefail

HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
REPO=$(cd "$HERE/../.." && pwd)
SRC_RULES=$REPO/host/files/etc/dsserver-firewall.nft
SRC_UNIT=$REPO/host/files/etc/systemd/system/dsserver-firewall.service
DST_RULES=/etc/dsserver-firewall.nft
DST_UNIT=/etc/systemd/system/dsserver-firewall.service
NFT=/usr/sbin/nft
TABLE="inet dsserver_fw"
STATE=/run/dsserver-firewall
ROLLBACK=$STATE/rollback.nft
REVERT_UNIT=dsserver-fw-revert
REVERT_SECONDS=600
IFACE=eno1
HOST_ADDR=192.168.68.115/24
LAN=192.168.68.0/24
TEST_NAME=dsserver-fwtest
TEST_IMAGE=busybox:1.37.0
TEST_PORT=18080

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }
info() { echo "info  $*"; }
[ "$(id -u)" = 0 ] || fail "run with sudo"
CMD=${1:-}; [ $# -eq 1 ] || CMD=""

table_loaded() { $NFT list table $TABLE >/dev/null 2>&1; }
revert_pending() { [ "$(systemctl is-active "$REVERT_UNIT.timer" 2>/dev/null || true)" = active ]; }
docker_up() { [ "$(systemctl is-active docker.service 2>/dev/null || true)" = active ]; }

# Load a ruleset and schedule its undo. The undo is a transient systemd timer owned by PID 1, so it
# fires even if this script, sudo, the terminal or the ssh connection dies.
load_with_revert() {
    local rules=$1 seconds=$2
    revert_pending && fail "a revert is already pending ($REVERT_UNIT.timer); run 'confirm' or 'revert' first"
    systemctl reset-failed "$REVERT_UNIT.service" "$REVERT_UNIT.timer" 2>/dev/null || true
    install -d -m 0700 "$STATE"
    { echo "table $TABLE"; echo "delete table $TABLE"
      if table_loaded; then $NFT list table $TABLE; fi; } >"$ROLLBACK"
    $NFT -c -f "$ROLLBACK" || fail "could not build a valid rollback file"
    # Schedule FIRST, then load: there is no moment with new rules and no pending revert.
    systemd-run --quiet --unit="$REVERT_UNIT" --description="dsserver firewall automatic revert" \
        --on-active="${seconds}s" --timer-property=AccuracySec=1s \
        "$NFT" -f "$ROLLBACK"
    revert_pending || fail "revert timer did not start (nothing loaded)"
    if ! $NFT -f "$rules"; then
        systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
        fail "loading $rules failed (nothing changed; revert cancelled)"
    fi
    ok "loaded; automatic revert at $(date -d "+${seconds} seconds" '+%H:%M:%S') ($REVERT_UNIT.timer)"
}

preflight() {
    step "Preflight (read-only)"
    [ -x "$NFT" ] || fail "$NFT not found"
    for f in "$SRC_RULES" "$SRC_UNIT"; do [ -f "$f" ] || fail "missing $f"; done
    $NFT -c -f "$SRC_RULES" || fail "ruleset syntax check failed"
    ok "ruleset syntax OK ($SRC_RULES)"
    local addrs; addrs=$(ip -o -4 addr show dev "$IFACE" 2>/dev/null | awk '{print $4}')
    [[ " $addrs " == *" $HOST_ADDR "* ]] || fail "$IFACE does not have $HOST_ADDR (has: ${addrs:-nothing}); the ruleset assumes it"
    ok "$IFACE has $HOST_ADDR (LAN $LAN)"
    if [ "$(systemctl is-enabled nftables.service 2>/dev/null || true)" = enabled ] || \
       [ "$(systemctl is-active nftables.service 2>/dev/null || true)" = active ]; then
        fail "nftables.service is enabled or active; its /etc/nftables.conf flushes ALL rules incl. Docker's"
    fi
    ok "nftables.service disabled and inactive"
    local ssh_peers; ssh_peers=$(ss -Htn state established '( sport = :22 )' | awk '{print $4}' | sed 's/:[0-9]*$//' | sort -u | tr '\n' ' ')
    info "established ssh sessions from: ${ssh_peers:-none}"
    info "our table loaded: $(table_loaded && echo yes || echo no); revert pending: $(revert_pending && echo yes || echo no); unit enabled: $(systemctl is-enabled dsserver-firewall.service 2>/dev/null || echo no)"
    info "docker: $(systemctl is-active docker.service 2>/dev/null || true); firewall backend: $(grep -o '"firewall-backend"[^,}]*' /etc/docker/daemon.json 2>/dev/null || echo default)"
    echo; echo "10 PREFLIGHT PASSED (nothing changed)"
}

selftest_revert() {
    step "Self-test of the automatic revert (empty table, no effect on traffic)"
    revert_pending && fail "a revert is already pending"
    $NFT list table inet dsserver_fw_selftest >/dev/null 2>&1 && fail "selftest table already exists"
    systemctl reset-failed dsserver-fw-selftest.service dsserver-fw-selftest.timer 2>/dev/null || true
    $NFT add table inet dsserver_fw_selftest
    systemd-run --quiet --unit=dsserver-fw-selftest --description="dsserver firewall revert self-test" \
        --on-active=60s --timer-property=AccuracySec=1s "$NFT" delete table inet dsserver_fw_selftest
    ok "empty table inet dsserver_fw_selftest loaded; removal scheduled at $(date -d '+60 seconds' '+%H:%M:%S')"
    echo "This command now exits: the removal must happen without it. Check after a minute with 'status'"
    echo "(expect: 'selftest table: absent', 'self-test revert: success')."
}

try_rules() {
    preflight
    step "Load the ruleset with a ${REVERT_SECONDS}s automatic revert"
    load_with_revert "$SRC_RULES" "$REVERT_SECONDS"
    sha256sum "$SRC_RULES" | awk '{print $1}' >"$STATE/tried.sha256"
    echo
    echo "Now test NEW connections from other machines (existing sessions prove nothing)."
    echo "If nothing is confirmed, the previous state returns automatically at the time above."
    echo "Then: 'confirm' (keep and enable at boot) or 'revert' (undo now)."
}

confirm() {
    step "Confirm"
    revert_pending || fail "no pending revert: run 'try' first (or the 10 minutes have passed)"
    table_loaded || fail "our table is not loaded"
    [ "$(sha256sum "$SRC_RULES" | awk '{print $1}')" = "$(cat "$STATE/tried.sha256" 2>/dev/null)" ] || \
        fail "the ruleset differs from the one loaded by 'try'; run 'revert' and 'try' again"
    systemctl stop "$REVERT_UNIT.timer"
    ok "automatic revert cancelled"
    install -m 0644 -o root -g root "$SRC_RULES" "$DST_RULES"
    install -m 0644 -o root -g root "$SRC_UNIT" "$DST_UNIT"
    systemctl daemon-reload
    systemctl enable dsserver-firewall.service
    systemctl restart dsserver-firewall.service   # reloads the same file atomically; unit becomes active
    ok "installed $DST_RULES and $DST_UNIT; enabled at boot"
    verify
}

verify() {
    step "Verify (read-only)"
    cmp -s "$SRC_RULES" "$DST_RULES" || fail "$DST_RULES missing or differs from the repository"
    cmp -s "$SRC_UNIT" "$DST_UNIT" || fail "$DST_UNIT missing or differs from the repository"
    [ "$(stat -c '%a %U:%G' "$DST_RULES")" = "644 root:root" ] || fail "$DST_RULES owner/mode"
    [ "$(systemctl is-enabled dsserver-firewall.service)" = enabled ] || fail "unit not enabled"
    [ "$(systemctl is-active dsserver-firewall.service)" = active ] || fail "unit not active"
    table_loaded || fail "table $TABLE not loaded"
    revert_pending && fail "a revert is still pending"
    ok "unit enabled+active, files match the repository, table loaded, no revert pending"
    [ "$(systemctl is-enabled nftables.service 2>/dev/null || true)" != enabled ] || fail "nftables.service is enabled"
    ok "nftables.service not enabled"
    if docker_up; then
        local t; t=$($NFT list tables)
        for x in "ip filter" "ip nat"; do [[ $t == *"table $x"* ]] || fail "Docker table '$x' missing"; done
        ok "Docker's tables present (ip filter, ip nat)"
    else info "docker not running: Docker table check skipped"; fi
    local p; p=$($NFT list chain $TABLE input | grep -c 'policy drop' || true)
    [ "$p" = 1 ] || fail "input policy is not drop"
    ok "input policy drop"
    echo; echo "10 VERIFY PASSED $(date -Is)"
}

status() {
    step "Status (read-only)"
    echo "tables: $($NFT list tables | sed 's/^table //' | tr '\n' ',' | sed 's/,$//')"
    echo "our table loaded: $(table_loaded && echo yes || echo no)"
    echo "unit: enabled=$(systemctl is-enabled dsserver-firewall.service 2>/dev/null || echo no) active=$(systemctl is-active dsserver-firewall.service 2>/dev/null || true)"
    if revert_pending; then echo "automatic revert: PENDING"; systemctl list-timers "$REVERT_UNIT.timer" --no-pager | sed -n 2p
    else echo "automatic revert: none pending"; fi
    echo "selftest table: $($NFT list table inet dsserver_fw_selftest >/dev/null 2>&1 && echo PRESENT || echo absent)"
    step "Last runs of the revert units (journal)"
    journalctl -u "$REVERT_UNIT.service" -u dsserver-fw-selftest.service --since -1d -n 6 -o short-iso --no-pager 2>/dev/null || true
    echo "test container: $(docker_up && docker ps --filter "name=^${TEST_NAME}$" --format '{{.Status}}' 2>/dev/null | grep . || echo none)"
    step "Recent drops (last hour)"
    journalctl -k --since -1h -g 'dsserver-fw' -o short-iso --no-pager 2>/dev/null | tail -n 10 || true
}

ct_check() { # ct_check <description> <command...>   (runs inside the test container)
    local d=$1; shift
    if docker exec "$TEST_NAME" "$@" >/dev/null 2>&1; then echo "  reachable  $d"; else echo "  BLOCKED    $d"; fi
}

docker_test_checks() {
    step "Checks from inside the container (firewall loaded: $(table_loaded && echo yes || echo no))"
    ct_check "container -> DNS (nslookup deb.debian.org)"      nslookup deb.debian.org
    ct_check "container -> internet (http://deb.debian.org)"  wget -q -T 5 -O /dev/null http://deb.debian.org/debian/
    ct_check "container -> host ssh (172.17.0.1:22)"           nc -z -w 3 172.17.0.1 22
    step "Check from the host itself"
    if curl -fsS -m 5 "http://127.0.0.1:$TEST_PORT/" >/dev/null 2>&1; then echo "  reachable  host -> 127.0.0.1:$TEST_PORT"
    else echo "  BLOCKED    host -> 127.0.0.1:$TEST_PORT"; fi
    echo
    echo "Expected with the firewall: DNS and internet reachable; host ssh BLOCKED; host -> 127.0.0.1 reachable."
    echo "Expected without it: all reachable. LAN access must be tested from another machine:"
    echo "  curl -m 5 http://192.168.68.115:$TEST_PORT/    (dsoffice; curl.exe on Windows)"
}

docker_test_start() {
    docker_up || fail "docker is not running"
    step "Start temporary test container $TEST_NAME (busybox httpd, published 0.0.0.0:$TEST_PORT)"
    local names; names=$(docker ps -a --format '{{.Names}}')
    if [[ $'\n'$names$'\n' == *$'\n'"$TEST_NAME"$'\n'* ]]; then fail "$TEST_NAME already exists; run docker-test-stop"; fi
    docker image inspect "$TEST_IMAGE" >/dev/null 2>&1 || docker pull -q "$TEST_IMAGE"
    info "image $TEST_IMAGE digest: $(docker image inspect -f '{{index .RepoDigests 0}}' "$TEST_IMAGE")"
    docker run -d --rm --name "$TEST_NAME" -p "$TEST_PORT:8080" \
        --user 65534:65534 --read-only --tmpfs /tmp:size=1m --cap-drop ALL --security-opt no-new-privileges \
        --memory 32m --pids-limit 32 --log-driver none \
        "$TEST_IMAGE" sh -c 'mkdir -p /tmp/w && echo dsserver-fwtest-ok >/tmp/w/index.html && exec httpd -f -p 8080 -h /tmp/w' >/dev/null
    sleep 1
    ok "running: $(docker ps --filter "name=^${TEST_NAME}$" --format '{{.Status}} {{.Ports}}')"
    docker_test_checks
}

docker_test_allow() {
    table_loaded || fail "firewall not loaded"
    $NFT add element $TABLE lan_tcp "{ $TEST_PORT }"
    ok "$TEST_PORT added to lan_tcp at runtime only (removed by reload, revert, reboot or docker-test-stop)"
    echo "Now from dsoffice/Windows: curl -m 5 http://192.168.68.115:$TEST_PORT/   -> expect dsserver-fwtest-ok"
}

docker_test_stop() {
    step "Remove the test container, runtime element and image"
    if table_loaded; then $NFT delete element $TABLE lan_tcp "{ $TEST_PORT }" 2>/dev/null && ok "runtime element $TEST_PORT removed" || true; fi
    if docker_up; then
        docker rm -f "$TEST_NAME" >/dev/null 2>&1 && ok "container removed" || info "no container"
        docker image rm "$TEST_IMAGE" >/dev/null 2>&1 && ok "image $TEST_IMAGE removed" || info "image not present"
    fi
}

revert_now() {
    step "Revert now"
    revert_pending || fail "no pending revert (use 'rollback' to remove a confirmed firewall)"
    systemctl stop "$REVERT_UNIT.timer"
    $NFT -f "$ROLLBACK"
    ok "previous state restored ($(table_loaded && echo 'previous dsserver_fw table' || echo 'no dsserver_fw table'))"
}

rollback() {
    step "Rollback: disable and remove the firewall"
    systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
    systemctl disable --now dsserver-firewall.service 2>/dev/null || true
    $NFT delete table $TABLE 2>/dev/null || true
    rm -f -- "$DST_RULES" "$DST_UNIT"; systemctl daemon-reload
    table_loaded && fail "table still loaded"
    echo "10 ROLLBACK DONE: no dsserver firewall loaded or enabled. Docker's tables were not touched."
}

case $CMD in
    preflight) preflight ;;
    selftest-revert) selftest_revert ;;
    try) try_rules ;;
    confirm) confirm ;;
    verify) verify ;;
    status) status ;;
    docker-test-start) docker_test_start ;;
    docker-test-allow) docker_test_allow ;;
    docker-test-stop) docker_test_stop ;;
    revert) revert_now ;;
    rollback) rollback ;;
    *) echo "usage: sudo $0 preflight|selftest-revert|try|confirm|verify|status|docker-test-start|docker-test-allow|docker-test-stop|revert|rollback" >&2; exit 2 ;;
esac
