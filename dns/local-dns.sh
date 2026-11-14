#!/bin/bash
# Local DNS resolver (dnsmasq, DNS only) on dsserver and Beacon. Design: /srv/stacks/dns/README.md.
#
# Usage (as root, on the host itself; the host is recognised by its hostname):
#   preflight     read-only: dnsmasq present, port 53 free (or ours), config syntax, firewall rule present
#   install       install config + unit from this directory, enable + start, then verify
#   verify        read-only: unit enabled/active, sockets only on loopback + LAN address, no DHCP,
#                 installed files identical to this directory, every record answers on both addresses
#                 (UDP and TCP), an internet name resolves, an unknown rubusdua.net name is NXDOMAIN
#   status        read-only: unit state and listening sockets
#   test-restart  restart the unit, then kill -9 its process (Restart=always must bring it back); verify
#   rollback      stop + disable, remove the unit and /etc/local-dns (nothing else is touched)
# Files are read from the directory this script is in (repository checkout, delegated snapshot on
# dsserver, or /srv/local-dns on Beacon). Writes nothing in that directory.
set -euo pipefail

HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ETC=/etc/local-dns
UNIT=local-dns.service
UNIT_DST=/etc/systemd/system/$UNIT
DNSMASQ=/usr/sbin/dnsmasq
PY="python3 -I"

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }
info() { echo "info  $*"; }
[ "$(id -u)" = 0 ] || fail "run as root"
CMD=${1:-}; [ $# -eq 1 ] || CMD=""

case $(hostname -s) in
    dsserver) ADDR=192.168.68.115; FWTABLE="inet dsserver_fw" ;;
    beacon)   ADDR=192.168.68.121; FWTABLE="inet beacon_fw" ;;
    *) fail "unknown host $(hostname -s): this resolver is meant for dsserver and beacon only" ;;
esac

port53() { ss -Hlnptu 'sport = :53' 2>/dev/null; }   # columns: netid state recv-q send-q local peer process

q() {  # q SERVER NAME TYPE [--tcp] -> prints "RCODE|data data ..."
    local out
    out=$($PY "$HERE/dnsq.py" "$@" 2>&1) || { echo "ERROR|$out"; return 0; }
    echo "$(head -1 <<<"$out")|$(tail -n +2 <<<"$out" | awk '{print $2}' | sort | tr '\n' ' ' | sed 's/ $//')"
}

check_answers() {
    local srv=$1 name ip got
    while IFS=, read -r name ip; do
        got=$(q "$srv" "$name" A);         [ "$got" = "NOERROR|$ip" ] || fail "$name @$srv udp: got '$got', want $ip"
        got=$(q "$srv" "$name" A --tcp);   [ "$got" = "NOERROR|$ip" ] || fail "$name @$srv tcp: got '$got', want $ip"
        got=$(q "$srv" "$ip" PTR);         [ "$got" = "NOERROR|$name" ] || fail "PTR $ip @$srv: got '$got', want $name"
        got=$(q "$srv" "$name" AAAA);      [ "${got%%|*}" = NOERROR ] && [ -z "${got#*|}" ] || fail "$name AAAA @$srv: got '$got', want NOERROR without data"
    done < <(sed -n 's/^host-record=//p' "$HERE/records.conf")
    ok "@$srv: all $(grep -c '^host-record=' "$HERE/records.conf") local records (A udp+tcp, PTR, AAAA=no data)"
    got=$(q "$srv" example.com A);                  [[ $got == NOERROR\|*.* ]] || fail "example.com @$srv: '$got'"
    got=$(q "$srv" local-dns-probe.rubusdua.net A); [ "${got%%|*}" = NXDOMAIN ] || fail "unknown rubusdua.net name @$srv not NXDOMAIN: '$got'"
    got=$(q "$srv" stockpulse.rubusdua.net A)
    for a in ${got#*|}; do [[ $a == 192.168.* ]] && fail "stockpulse resolves to a LAN address @$srv: '$got'"; done
    [ "${got%%|*}" = NOERROR ] && [ -n "${got#*|}" ] || fail "stockpulse @$srv: '$got'"
    ok "@$srv: internet name, unknown rubusdua.net name (NXDOMAIN, zone not local), stockpulse -> public Cloudflare ($got)"
}

case $CMD in
preflight)
    step "preflight on $(hostname -s) ($ADDR)"
    [ -x $DNSMASQ ] || fail "$DNSMASQ missing (package dnsmasq-base)"; ok "$($DNSMASQ --version | head -1)"
    id dnsmasq >/dev/null 2>&1 || fail "user dnsmasq missing"; ok "user dnsmasq exists"
    ip -4 -o addr show | grep -q " $ADDR/" || fail "$ADDR is not configured on this host"; ok "$ADDR present"
    p=$(port53 | grep -v '"dnsmasq"' || true); [ -z "$p" ] || fail "port 53 already in use: $p"; ok "port 53 free (or ours)"
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    sed -e "s#$ETC/listen.conf#$t/listen.conf#; s#$ETC/records.conf#$HERE/records.conf#" "$HERE/dnsmasq.conf" > "$t/c"
    echo "listen-address=$ADDR" > "$t/listen.conf"
    $DNSMASQ --test --conf-file="$t/c" >/dev/null 2>&1 || fail "dnsmasq syntax check"; ok "configuration syntax"
    if nft -nn list table $FWTABLE 2>/dev/null | grep -qE 'th dport 53 accept|[ {,]53 comment'; then ok "firewall ($FWTABLE) has a port 53 rule"
    else info "no port 53 rule in the firewall yet: LAN clients will be dropped until it is added"; fi
    ;;
install)
    "$0" preflight
    step "install"
    install -d -m 0755 $ETC
    install -m 0644 "$HERE/dnsmasq.conf" $ETC/dnsmasq.conf
    install -m 0644 "$HERE/records.conf" $ETC/records.conf
    echo "listen-address=$ADDR" > $ETC/listen.conf; chmod 0644 $ETC/listen.conf
    install -m 0644 "$HERE/local-dns.service" $UNIT_DST
    $DNSMASQ --test --conf-file=$ETC/dnsmasq.conf >/dev/null 2>&1 || fail "installed config fails syntax check"
    systemctl daemon-reload
    systemctl enable $UNIT >/dev/null 2>&1
    systemctl restart $UNIT
    sleep 2
    ok "installed, enabled, (re)started"
    "$0" verify
    ;;
verify)
    step "verify on $(hostname -s) ($ADDR)"
    [ "$(systemctl is-enabled $UNIT 2>/dev/null)" = enabled ] || fail "$UNIT not enabled"
    [ "$(systemctl is-active $UNIT 2>/dev/null)" = active ] || fail "$UNIT not active"
    ok "$UNIT enabled and active (pid $(systemctl show -p MainPID --value $UNIT), user $(ps -o user= -p "$(systemctl show -p MainPID --value $UNIT)"))"
    for f in dnsmasq.conf records.conf; do cmp -s "$HERE/$f" $ETC/$f || fail "$ETC/$f differs from $HERE/$f (run install)"; done
    cmp -s "$HERE/local-dns.service" $UNIT_DST || fail "$UNIT_DST differs from $HERE/local-dns.service (run install)"
    [ "$(cat $ETC/listen.conf)" = "listen-address=$ADDR" ] || fail "$ETC/listen.conf unexpected"
    ok "installed files identical to $HERE"
    socks=$(port53 | awk '{print $1" "$5}' | sort -u)
    bad=$(grep -vE " (127\.0\.0\.1|\[::1\]|${ADDR//./\\.}):53$" <<<"$socks" || true)
    [ -z "$bad" ] || fail "unexpected listening sockets on port 53: $bad"
    for want in "udp 127.0.0.1:53" "tcp 127.0.0.1:53" "udp $ADDR:53" "tcp $ADDR:53"; do grep -qx "$want" <<<"$socks" || fail "not listening: $want"; done
    ok "port 53 only on loopback and $ADDR (udp+tcp)"
    ss -Hlnpu 'sport = :67' | grep -q dnsmasq && fail "dnsmasq listens on the DHCP port"
    ok "no DHCP"
    check_answers 127.0.0.1
    check_answers "$ADDR"
    echo; echo "VERIFY PASSED"
    ;;
status)
    systemctl --no-pager --lines=5 status $UNIT || true
    port53 || true
    ;;
test-restart)
    step "restart"
    systemctl restart $UNIT; sleep 2; "$0" verify >/dev/null || fail "verify after restart"; ok "restart: verify passed"
    step "crash recovery (kill -9)"
    pid=$(systemctl show -p MainPID --value $UNIT); kill -9 "$pid"
    for i in $(seq 1 20); do sleep 1; n=$(systemctl show -p MainPID --value $UNIT); [ "$n" != 0 ] && [ "$n" != "$pid" ] && [ "$(systemctl is-active $UNIT)" = active ] && break; done
    [ "$n" != "$pid" ] || fail "not restarted after kill -9"
    sleep 1; "$0" verify >/dev/null || fail "verify after crash recovery"; ok "killed pid $pid, restarted as pid $n within ${i}s, verify passed"
    ;;
rollback)
    step "rollback"
    systemctl disable --now $UNIT >/dev/null 2>&1 || true
    rm -f $UNIT_DST; rm -rf $ETC; systemctl daemon-reload; systemctl reset-failed $UNIT 2>/dev/null || true
    ok "local DNS removed (unit, $ETC)"
    ;;
*)
    sed -n '2,13p' "$0"; exit 2 ;;
esac
