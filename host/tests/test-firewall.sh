#!/bin/bash
# Functional test of host/files/etc/dsserver-firewall.nft with REAL traffic, run unprivileged.
# Everything happens inside a throw-away user + network namespace; the real host is not touched.
#
# Topology (all inside the sandbox):
#   srv  (the "dsserver")  eno1    192.168.68.115/24   docker0 172.17.0.1/16, ip_forward=1,
#                          a Docker-like NAT table: host port 18080 -> 172.17.0.2:80, masquerade out
#   lan  (a LAN client)    c0      192.168.68.50/24, plus 203.0.113.9 as a NON-LAN source address
#   ctr  (a "container")   ctr0    172.17.0.2/16, default via 172.17.0.1
#
# Usage: bash host/tests/test-firewall.sh        (exit 0 = all passed)
set -uo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
RULES=$(readlink -f "$HERE/../files/etc/dsserver-firewall.nft")
[ -f "$RULES" ] || { echo "missing $RULES"; exit 1; }

if [ "${1:-}" != --inside ]; then
    exec unshare -rnm --propagation private bash "$0" --inside "$RULES"
fi
RULES=$2
NFT=/usr/sbin/nft
PASS=0; FAIL=0
t() { # t <description> <expected: ok|blocked> <command...>
    local d=$1 e=$2; shift 2
    local r=blocked; if "$@" >/dev/null 2>&1; then r=ok; fi
    if [ "$r" = "$e" ]; then PASS=$((PASS+1)); echo "pass  $d ($r)"
    else FAIL=$((FAIL+1)); echo "FAIL  $d (expected $e, got $r)"; fi
}
in_lan() { nsenter --net=/run/netns/lan "$@"; }
in_ctr() { nsenter --net=/run/netns/ctr "$@"; }

set -e
mount -t tmpfs none /run; mkdir -p /run/netns /run/fwtest
ip netns add lan; ip netns add ctr
ip link set lo up
ip link add eno1 type veth peer name c0;      ip link set c0 netns lan
ip link add docker0 type veth peer name ctr0; ip link set ctr0 netns ctr
ip addr add 192.168.68.115/24 dev eno1; ip link set eno1 up
ip addr add 172.17.0.1/16 dev docker0;  ip link set docker0 up
ip route add 203.0.113.9/32 via 192.168.68.50
echo 1 >/proc/sys/net/ipv4/ip_forward
in_lan ip link set lo up
in_lan ip addr add 192.168.68.50/24 dev c0; in_lan ip addr add 203.0.113.9/32 dev c0; in_lan ip link set c0 up
in_lan ip route add 172.17.0.0/16 via 192.168.68.115     # a LAN host trying to route to containers
in_ctr ip link set lo up
in_ctr ip addr add 172.17.0.2/16 dev ctr0; in_ctr ip link set ctr0 up
in_ctr ip route add default via 172.17.0.1

# Docker-like NAT (Docker's real rules live in separate tables, just like this one)
$NFT -f - <<'EOF'
table ip dockersim {
    chain pre  { type nat hook prerouting priority dstnat; fib daddr type local tcp dport 18080 dnat to 172.17.0.2:80; }
    chain post { type nat hook postrouting priority srcnat; ip saddr 172.17.0.0/16 oifname "eno1" masquerade; }
}
EOF

# Listeners
L() { setsid "$@" >/dev/null 2>&1 < /dev/null & }
L socat TCP-LISTEN:22,fork,reuseaddr SYSTEM:'echo ssh'
L socat TCP-LISTEN:9999,fork,reuseaddr SYSTEM:'echo unlisted'
L socat -u UDP-RECV:68 OPEN:/run/fwtest/dhcp,creat,append
L socat -u UDP-RECV:5353 OPEN:/run/fwtest/mdns,creat,append
L socat -u UDP-RECV:4444 OPEN:/run/fwtest/udp4444,creat,append
L socat TCP-LISTEN:53,fork,reuseaddr SYSTEM:'echo dns'
L socat -u UDP-RECV:53 OPEN:/run/fwtest/dns,creat,append
L nsenter --net=/run/netns/ctr socat TCP-LISTEN:80,fork,reuseaddr SYSTEM:'echo web'
L nsenter --net=/run/netns/lan socat TCP-LISTEN:8000,fork,reuseaddr SYSTEM:'echo outside'
sleep 2   # listeners up, IPv6 DAD done
set +e

udp_sent() { sleep 0.5; [ -s "/run/fwtest/$1" ]; }

echo "=== Without firewall (baseline: everything reachable)"
t "LAN -> host ssh"                    ok      in_lan nc -z -w 2 192.168.68.115 22
t "LAN -> published 18080"             ok      in_lan nc -z -w 2 192.168.68.115 18080

echo "=== Firewall loaded"
$NFT -f "$RULES" || { echo "FAIL  ruleset did not load"; exit 1; }
t "Docker-like table still present after load" ok $NFT list table ip dockersim
t "LAN -> host ssh (new connection)"   ok      in_lan nc -z -w 2 192.168.68.115 22
t "non-LAN -> host ssh"                blocked in_lan nc -z -w 2 -s 203.0.113.9 192.168.68.115 22
t "LAN -> unlisted host port 9999"     blocked in_lan nc -z -w 2 192.168.68.115 9999
t "LAN ping"                           ok      in_lan ping -c1 -W1 192.168.68.115
t "non-LAN ping"                       blocked in_lan ping -c1 -W1 -I 203.0.113.9 192.168.68.115
LL=$(ip -6 -o addr show dev eno1 scope link | awk '{print $4}' | cut -d/ -f1)
t "IPv6 link-local ping (ND works)"    ok      in_lan ping -6 -c1 -W1 "$LL%c0"
in_lan socat -u - UDP-SENDTO:192.168.68.115:68,sourceport=67 <<<x
t "DHCP reply (udp 67 -> 68)"          ok      udp_sent dhcp
in_lan socat -u - UDP-SENDTO:192.168.68.115:5353 <<<x
t "LAN mDNS udp 5353"                  ok      udp_sent mdns
in_lan socat -u - UDP-SENDTO:192.168.68.115:4444 <<<x
t "LAN unlisted udp 4444"              blocked udp_sent udp4444
t "LAN -> host DNS tcp 53"             ok      in_lan nc -z -w 2 192.168.68.115 53
t "non-LAN -> host DNS tcp 53"         blocked in_lan nc -z -w 2 -s 203.0.113.9 192.168.68.115 53
in_lan socat -u - UDP-SENDTO:192.168.68.115:53 <<<x
t "LAN -> host DNS udp 53"             ok      udp_sent dns
t "container -> host DNS tcp 53 (bridge address)" ok in_ctr nc -z -w 2 172.17.0.1 53
t "container -> host DNS tcp 53 (LAN address)"    ok in_ctr nc -z -w 2 192.168.68.115 53
: > /run/fwtest/dns
in_ctr socat -u - UDP-SENDTO:172.17.0.1:53 <<<x
t "container -> host DNS udp 53"       ok      udp_sent dns

echo "=== Docker published port (default: not in any scope)"
t "LAN -> published 18080"             blocked in_lan nc -z -w 2 192.168.68.115 18080
t "LAN -> container address directly"  blocked in_lan nc -z -w 2 172.17.0.2 80
t "container -> outside (outbound)"    ok      in_ctr nc -z -w 2 192.168.68.50 8000
t "container -> host ssh"              blocked in_ctr nc -z -w 2 172.17.0.1 22
t "host -> outside (outbound)"         ok      nc -z -w 2 192.168.68.50 8000

echo "=== Published port 18080 added to LAN scope (runtime element, as 'docker-test-allow' does)"
$NFT add element inet dsserver_fw lan_tcp '{ 18080 }'
t "LAN -> published 18080"             ok      in_lan nc -z -w 2 192.168.68.115 18080
t "non-LAN -> published 18080"         blocked in_lan nc -z -w 2 -s 203.0.113.9 192.168.68.115 18080
t "LAN -> container address directly"  blocked in_lan nc -z -w 2 172.17.0.2 80
t "LAN -> unlisted host port 9999"     blocked in_lan nc -z -w 2 192.168.68.115 9999

echo "=== Reload (atomic replace) keeps Docker's table and drops runtime additions"
$NFT -f "$RULES"
t "Docker-like table still present"    ok      $NFT list table ip dockersim
t "LAN -> published 18080 again closed" blocked in_lan nc -z -w 2 192.168.68.115 18080
t "LAN -> host ssh after reload"       ok      in_lan nc -z -w 2 192.168.68.115 22

echo "=== Firewall removed (what the automatic revert does)"
$NFT delete table inet dsserver_fw
t "LAN -> unlisted 9999 open again"    ok      in_lan nc -z -w 2 192.168.68.115 9999
t "Docker-like table untouched"        ok      $NFT list table ip dockersim

echo; echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
