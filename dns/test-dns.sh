#!/bin/bash
# End-to-end test of the local DNS resolvers from a LAN client (needs dig).
# Usage: bash test-dns.sh [RESOLVER ...]     default: 192.168.68.121 192.168.68.115
# Checks per resolver, over UDP and TCP: every record in records.conf (A + PTR), AAAA = no data,
# internet names, an unknown rubusdua.net name (NXDOMAIN: zone not declared local), stockpulse -> Cloudflare
# (not a LAN address), SOA/TXT forwarding used by Caddy DNS-01. Exit 0 = all passed.
set -uo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
SERVERS=("$@"); [ ${#SERVERS[@]} -gt 0 ] || SERVERS=(192.168.68.121 192.168.68.115)
PASS=0; FAIL=0
t() { local d=$1 want=$2 got=$3
    if [[ $got == $want ]]; then PASS=$((PASS+1)); echo "pass  $d"; else FAIL=$((FAIL+1)); echo "FAIL  $d: got '$got', want '$want'"; fi; }
d() { dig +time=2 +tries=1 "$@" 2>&1; }
status() { d "$@" | sed -n 's/.*status: \([A-Z]*\).*/\1/p' | head -1; }
short() { d +short "$@" | sort | tr '\n' ' ' | sed 's/ $//'; }
for s in "${SERVERS[@]}"; do
    echo "=== resolver $s"
    while IFS=, read -r name ip; do
        t "$name A udp"   "$ip" "$(short @"$s" "$name" A)"
        t "$name A tcp"   "$ip" "$(short +tcp @"$s" "$name" A)"
        t "$ip PTR"       "$name." "$(short @"$s" -x "$ip")"
        t "$name AAAA"    "NOERROR" "$(status @"$s" "$name" AAAA)"
        t "$name AAAA empty" "" "$(short @"$s" "$name" AAAA)"
    done < <(sed -n 's/^host-record=//p' "$HERE/records.conf")
    for n in example.com www.debian.org github.com; do t "$n resolves" "*.*" "$(short @"$s" "$n" A | grep -Eo '^[0-9.]+' | head -1)"; done
    t "unknown rubusdua.net name NXDOMAIN" "NXDOMAIN" "$(status @"$s" local-dns-probe.rubusdua.net A)"
    sp=$(short @"$s" stockpulse.rubusdua.net A)
    t "stockpulse resolves" "*.*" "$sp"
    t "stockpulse not a LAN address" "" "$(grep -o '192\.168\.[0-9.]*' <<<"$sp")"
    t "rubusdua.net SOA from Cloudflare" "*cloudflare.com.*" "$(short @"$s" rubusdua.net SOA)"
    t "_acme-challenge TXT forwarded (answer from public zone)" "*" "$(status @"$s" _acme-challenge.dsserver.rubusdua.net TXT)"
    t "single-label name not forwarded" "NXDOMAIN" "$(status @"$s" dsnas A)"
    t "private reverse lookup stays local" "NXDOMAIN" "$(status @"$s" -x 192.168.68.250)"
done
echo; echo "$PASS passed, $FAIL failed"; [ $FAIL -eq 0 ]
