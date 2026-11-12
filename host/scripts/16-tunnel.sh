#!/bin/bash
# dsserver: Cloudflare Tunnel + Access for https://stockpulse.rubusdua.net (design: docs/external-access.md).
# Outbound-only connector (tunnel/compose.yaml) that reaches only Caddy; Cloudflare Access (e-mail one-time PIN)
# in front; /healthz bypassed for monitoring. No router port, no firewall change, Caddy and LAN names unchanged.
#
# Usage: sudo /usr/local/lib/dsserver-admin/host/scripts/16-tunnel.sh <mode>
#   preflight      read-only: routes registry, compose file, connector image (digest) and its commands
#   token-install  /home/daniel/.cloudflare-token-tunnel-setup (daniel 0600) -> root-only file; checked; shredded
#   emails-install /home/daniel/.stockpulse-access-emails (daniel 0600, one address per line) -> root-only; shredded
#   check          read-only at Cloudflare: token, zone, Zero Trust team, tunnel, Access apps, DNS, allow-list
#   access-setup   create/update the login method, policies, StockPulse Access app + /healthz bypass app
#   tunnel-create  create tunnel "dsserver-apps"; its credentials file (this tunnel only) -> $CFD (root:65532 0640)
#   config         render config.yml from routes.toml, validate ingress, show which rule each test hostname hits
#   up             start the connector, wait for health and for Cloudflare to report it connected
#   dns-switch     stockpulse A 192.168.68.115 -> proxied CNAME to the tunnel (refuses without the Access app)
#   verify         external checks over the internet + LAN direct path + DNS of the admin names
#   status         container, tunnel connections, DNS
#   dns-rollback   stockpulse back to A 192.168.68.115, DNS only (LAN-only, as before)
#   down           stop and remove the connector
#   teardown       (after dns-rollback + down) delete Access apps/policies and the tunnel at Cloudflare
#   token-remove   shred the setup token file (then revoke the token in the Cloudflare dashboard)
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
T="$ROOT/tunnel"
CF=(python3 -I "$T/cf.py")
COMPOSE=(docker compose -f "$T/compose.yaml")
CFD=/etc/dsserver-secrets/cloudflared
TOKEN=/etc/dsserver-secrets/cloudflare-tunnel-setup.env
EMAILS=/etc/dsserver-secrets/stockpulse-access-emails
CT=tunnel-cloudflared
HOST=stockpulse.rubusdua.net
UID_=65532
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
FAILS=0
[ "$(id -u)" = 0 ] || fail "run as root"
[ "$(hostname)" = dsserver ] || fail "not dsserver"

image() { sed -n 's/^ *image: *//p' "$T/compose.yaml" | head -n1; }
# cloudflared with the real config, but no network and read-only (for ingress validation only)
cfd_offline() { docker run --rm --network none --user "$UID_:$UID_" --read-only --cap-drop ALL \
    --security-opt no-new-privileges -v "$CFD:/etc/cloudflared:ro" "$(image)" "$@"; }
stage() {  # $1 staged file, $2 destination, $3 validation regex for every line
    local s=$1 d=$2
    [ -f "$s" ] && [ ! -L "$s" ] || fail "missing $s (or a symlink)"
    [ "$(stat -c '%U %a' "$s")" = "daniel 600" ] || fail "$s must be owned by daniel, mode 600"
    grep -v '^[[:space:]]*$' "$s" | grep -qvE "$3" && fail "$s has a line in the wrong format (content not shown)"
    install -d -m 0700 -o root -g root /etc/dsserver-secrets
    ( umask 077; cat "$s" > "$d.new" ); mv "$d.new" "$d"
    ok "installed $d (root 0600)"
}
tunnel_id() { "${CF[@]}" tunnel-id; }
cf_ips() { dig +short "$HOST" @1.1.1.1 | grep -E '^[0-9.]+$' | head -n1; }

case "${1:-}:$#" in
  preflight:1)
    python3 -I "$T/render.py" --check && ok "routes.toml valid" || bad "routes.toml"
    ( cd "$T" && python3 -I -m unittest -q test_render 2>&1 | tail -n1 )
    "${COMPOSE[@]}" config -q && ok "compose file valid" || bad "compose file"
    docker pull -q "$(image)" >/dev/null && ok "image $(image | cut -c1-60)… pulled (digest pinned)" || bad "image pull"
    docker run --rm --network none "$(image)" --version | sed 's/^/      /'
    docker run --rm --network none "$(image)" tunnel ready --help >/dev/null 2>&1 \
      && ok "'tunnel ready' exists (healthcheck)" || bad "'tunnel ready' missing in this version (healthcheck)"
    for f in "$TOKEN" "$EMAILS" "$CFD/credentials.json" "$CFD/config.yml"; do
      [ -e "$f" ] && echo "      present: $f" || echo "      absent:  $f"; done
    docker ps --format '{{.Names}}' | grep -qx "$CT" && echo "      connector running" || echo "      connector not running"
    [ "$FAILS" = 0 ] && echo "16 PREFLIGHT PASSED" || fail "$FAILS check(s) failed" ;;

  token-install:1)
    stage /home/daniel/.cloudflare-token-tunnel-setup "$TOKEN.raw" '^[A-Za-z0-9_-]{30,}$'
    ( umask 077; printf 'CF_API_TOKEN=%s\n' "$(head -n1 "$TOKEN.raw" | tr -d '[:space:]')" > "$TOKEN" ); shred -u "$TOKEN.raw"
    "${CF[@]}" check || echo "      (a FAIL above may only mean the Zero Trust organisation or allow-list is not there yet)"
    shred -u /home/daniel/.cloudflare-token-tunnel-setup && ok "staged file shredded" ;;
  emails-install:1)
    stage /home/daniel/.stockpulse-access-emails "$EMAILS" '^[^@[:space:]]+@[^@[:space:]]+\.[A-Za-z]{2,}$'
    shred -u /home/daniel/.stockpulse-access-emails && ok "staged file shredded" ;;
  check:1) "${CF[@]}" check ;;
  token-remove:1)
    [ -e "$TOKEN" ] && shred -u "$TOKEN" && ok "setup token file shredded: now revoke the token in the Cloudflare dashboard" \
      || ok "no setup token file" ;;

  access-setup:1) "${CF[@]}" access-setup || fail "Access setup" ;;

  tunnel-create:1)
    install -d -m 0750 -o root -g "$UID_" "$CFD"
    [ -e "$CFD/credentials.json" ] && fail "$CFD/credentials.json exists already (nothing changed)"
    "${CF[@]}" tunnel-create "$CFD/credentials.json" || fail "tunnel creation"
    chown root:"$UID_" "$CFD/credentials.json"; chmod 0640 "$CFD/credentials.json"
    ok "$CFD/credentials.json root:$UID_ 0640 (can run this one tunnel only)" ;;

  config:1)
    id=$(tunnel_id); [ -n "$id" ] || fail "no tunnel (tunnel-create)"
    [ -s "$CFD/credentials.json" ] || fail "no credentials file"
    python3 -I "$T/render.py" --tunnel-id "$id" > "$CFD/config.yml.new" || fail "render"
    chown root:"$UID_" "$CFD/config.yml.new"; chmod 0640 "$CFD/config.yml.new"; mv "$CFD/config.yml.new" "$CFD/config.yml"
    sed 's/^/      /' "$CFD/config.yml"
    cfd_offline tunnel --config /etc/cloudflared/config.yml ingress validate >/dev/null 2>&1 \
      && ok "cloudflared: ingress valid" || bad "cloudflared ingress validate"
    for u in "https://$HOST/latest/us" https://beacon.rubusdua.net/ https://dsserver.rubusdua.net/ https://other.rubusdua.net/; do
      r=$(cfd_offline tunnel --config /etc/cloudflared/config.yml ingress rule "$u" 2>&1 | grep -i 'service' | head -n1 | sed 's/^[[:space:]]*//')
      case "$u" in
        "https://$HOST"*) [[ $r == *proxy-caddy:443* ]] && ok "$u -> $r" || bad "$u -> $r" ;;
        *)                [[ $r == *http_status:404* ]] && ok "$u -> $r" || bad "$u -> $r (expected 404)" ;;
      esac
    done
    [ "$FAILS" = 0 ] && echo "16 CONFIG PASSED" || fail "$FAILS check(s) failed" ;;

  up:1)
    [ -s "$CFD/config.yml" ] || fail "no config.yml (config)"
    "${COMPOSE[@]}" up -d
    for _ in $(seq 1 24); do
      h=$(docker inspect -f '{{.State.Health.Status}}' "$CT" 2>/dev/null || echo none); [ "$h" = healthy ] && break; sleep 5
    done
    [ "$h" = healthy ] && ok "connector healthy" || fail "connector not healthy ($h): docker logs $CT"
    docker logs "$CT" 2>&1 | grep -iE 'registered tunnel connection|error|failed' | tail -n 6 | sed 's/^/      /'
    sleep 3; "${CF[@]}" tunnel-status || fail "Cloudflare does not see the connector" ;;

  dns-switch:1)
    docker inspect -f '{{.State.Health.Status}}' "$CT" 2>/dev/null | grep -qx healthy || fail "connector not healthy"
    "${CF[@]}" tunnel-status >/dev/null || fail "tunnel not connected"
    "${CF[@]}" dns-switch || fail "DNS switch" ;;
  dns-rollback:1) "${CF[@]}" dns-rollback || fail "DNS rollback" ;;

  verify:1)
    ip=$(cf_ips); [ -n "$ip" ] || fail "no public A answer for $HOST from 1.1.1.1"
    [[ $ip == 192.168.* ]] && fail "$HOST still resolves to the LAN address $ip publicly (dns-switch?)"
    ok "public DNS (1.1.1.1): $HOST -> $ip (Cloudflare edge)"
    X=(curl -s -m 20 --resolve "$HOST:443:$ip")
    r=$("${X[@]}" -w ' %{http_code}' "https://$HOST/healthz"); [ "$r" = "ok 200" ] && ok "internet /healthz: 200 ok (Access bypass, tunnel, Caddy, app)" || bad "internet /healthz: $r"
    for p in /latest/us /archive/ /history.db /; do
      read -r code loc < <("${X[@]}" -o /dev/null -w '%{http_code} %{redirect_url}\n' "https://$HOST$p")
      [[ $code =~ ^30[0-9]$ && $loc == https://*.cloudflareaccess.com/* ]] && ok "internet $p without login: $code -> Access login" \
        || bad "internet $p without login: $code $loc (expected redirect to the Access login)"
    done
    srv=$("${X[@]}" -o /dev/null -D - "https://$HOST/healthz" | tr -d '\r' | sed -n 's/^server: //Ip'); [ "$srv" = cloudflare ] && ok "served via Cloudflare" || bad "server header: $srv"
    r=$(curl -s -m 10 --resolve "$HOST:443:192.168.68.115" -w ' %{http_code}' "https://$HOST/healthz"); [ "$r" = "ok 200" ] && ok "LAN direct path (Caddy) unchanged: $r" || bad "LAN direct: $r"
    for n in beacon dsserver; do
      a=$(dig +short "$n.rubusdua.net" @1.1.1.1 | tr '\n' ' '); [[ $a == 192.168.68.* ]] && ok "$n.rubusdua.net still LAN-only A: $a" || bad "$n.rubusdua.net: $a"
    done
    docker inspect -f '{{.State.Health.Status}}' "$CT" | grep -qx healthy && ok "connector healthy" || bad "connector health"
    "${CF[@]}" tunnel-status || FAILS=$((FAILS+1))
    [ "$FAILS" = 0 ] && echo "16 VERIFY PASSED" || fail "$FAILS check(s) failed" ;;

  status:1)
    docker ps -a --filter "name=^$CT\$" --format '{{.Names}} {{.Status}} {{.Image}}' | cut -c1-120
    "${CF[@]}" tunnel-status || true; "${CF[@]}" dns-show || true
    docker logs --tail 5 "$CT" 2>&1 | sed 's/^/      /' || true ;;
  down:1) "${COMPOSE[@]}" down && ok "connector stopped and removed" ;;
  teardown:1)
    docker ps --format '{{.Names}}' | grep -qx "$CT" && fail "connector still running (down first)"
    "${CF[@]}" teardown || fail "teardown"
    rm -f "$CFD/credentials.json" "$CFD/config.yml" && ok "local tunnel credentials removed" ;;
  *) echo "usage: sudo $0 preflight|token-install|emails-install|check|access-setup|tunnel-create|config|up|dns-switch|verify|status|dns-rollback|down|teardown|token-remove" >&2; exit 2 ;;
esac
