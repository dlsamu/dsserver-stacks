#!/bin/bash
# Public DNS records for the LAN-only hosts (beacon., dsserver.rubusdua.net) at Cloudflare. Since the LAN resolvers
# (dns/) answer these names, the public A records (pointing at private addresses) are no longer needed.
# Approved by the owner 2026-11-14 for exactly these two records. Run on dsserver as daniel; uses Beacon's
# Cloudflare token (/etc/beacon-secrets/cloudflare.env, root 0600, DNS edit on rubusdua.net) over `ssh beacon`;
# the token reaches curl only through stdin, never argv or output.
#
#   list      show all A/AAAA/CNAME records of the zone (name, type, content, proxied) - read-only
#   retire    delete the A records beacon.rubusdua.net -> 192.168.68.121 and dsserver.rubusdua.net ->
#             192.168.68.115, only if each is exactly that (A, that address, DNS only). Nothing else is touched.
#   restore   recreate them as before (A, DNS only, TTL auto) - rollback
set -euo pipefail
CMD=${1:-}
declare -A WANT=([beacon.rubusdua.net]=192.168.68.121 [dsserver.rubusdua.net]=192.168.68.115)

cf() {  # cf METHOD PATH [JSON-BODY]  -> response JSON. Non-secret curl config goes over stdin; Beacon adds the token header.
    local m=$1 p=$2 body=${3:-}
    {
        printf 'header = "Content-Type: application/json"\nrequest = "%s"\nurl = "https://api.cloudflare.com/client/v4/%s"\n' "$m" "$p"
        if [ -n "$body" ]; then printf 'data = "%s"\n' "${body//\"/\\\"}"; fi
    } | ssh beacon 'sudo sh -c ". /etc/beacon-secrets/cloudflare.env; { printf \"header = \\\"Authorization: Bearer %s\\\"\\n\" \"\$CF_API_TOKEN\"; cat; } | curl -s -m 20 -K -"'
}
zone=$(cf GET "zones?name=rubusdua.net" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
records() { cf GET "zones/$zone/dns_records?per_page=200"; }

case $CMD in
  list)
    records | python3 -I -c '
import json,sys
for r in sorted(json.load(sys.stdin)["result"], key=lambda r: r["name"]):
    if r["type"] in ("A","AAAA","CNAME"): print("%-32s %-5s %-45s %s" % (r["name"], r["type"], r["content"], "proxied" if r["proxied"] else "dns-only"))' ;;
  retire)
    all=$(records)
    for n in "${!WANT[@]}"; do
        id=$(python3 -I -c '
import json,sys
n, ip = sys.argv[1:]
rs = [r for r in json.load(sys.stdin)["result"] if r["name"] == n]
if not rs: print("ABSENT"); sys.exit()
if len(rs) == 1 and rs[0]["type"] == "A" and rs[0]["content"] == ip and not rs[0]["proxied"]: print(rs[0]["id"])
else: print("UNEXPECTED " + json.dumps([(r["type"], r["content"], r["proxied"]) for r in rs]))' "$n" "${WANT[$n]}" <<<"$all")
        case $id in
          ABSENT) echo "ok    $n: no public record (already retired)" ;;
          UNEXPECTED*) echo "STOP  $n: $id - not touching it"; exit 1 ;;
          *) r=$(cf DELETE "zones/$zone/dns_records/$id"); [[ $r == *'"success":true'* ]] && echo "ok    $n: A ${WANT[$n]} deleted" || { echo "FAIL  $n: $r"; exit 1; } ;;
        esac
    done ;;
  restore)
    for n in "${!WANT[@]}"; do
        body="{\"type\":\"A\",\"name\":\"$n\",\"content\":\"${WANT[$n]}\",\"ttl\":1,\"proxied\":false,\"comment\":\"LAN HTTPS (restored from dns/cf-private-records.sh)\"}"
        r=$(cf POST "zones/$zone/dns_records" "$body"); [[ $r == *'"success":true'* ]] && echo "ok    $n: A ${WANT[$n]} created" || echo "FAIL  $n: $(cut -c1-200 <<<"$r")"
    done ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
