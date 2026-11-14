#!/bin/bash
# dsserver: Caddy HTTPS reverse proxy (proxy/compose.yaml, proxy/README.md). Delegated through
# host/scripts/09-delegated-sudo.sh: always runs the reviewed files in the root-owned snapshot.
#
#   preflight      read-only: docker, files, token, port 443, current state
#   token-install  /home/daniel/.cloudflare-token-dsserver (daniel 0600, one line) ->
#                  /etc/dsserver-secrets/cloudflare.env (root 0600); checked at Cloudflare; local file shredded
#   token-check    re-check the installed token at Cloudflare (status, zone visibility); never prints it
#   dns-ensure     for every *.rubusdua.net site in the snapshot's Caddyfile (except '# cert-only' sites): create a missing A record
#                  -> 192.168.68.115, DNS only (grey cloud). Never changes or deletes existing records.
#   build          build the image (same Dockerfile as Beacon)
#   up             create/recreate the container from the snapshot's compose file and Caddyfile, wait
#                  for the certificate. Recreating takes a few seconds (that is how Caddyfile changes apply).
#   verify         certificate chain/hostname/expiry via 127.0.0.1:443 and container settings
#   status         container, certificate expiry, recent log lines
#   down           stop and remove the container (certificates kept in /srv/appdata/proxy)
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
COMPOSE=(docker compose -f "$ROOT/proxy/compose.yaml")
NAME=dsserver.rubusdua.net
STAGED=/home/daniel/.cloudflare-token-dsserver
SECRET=/etc/dsserver-secrets/cloudflare.env
DATA=/srv/appdata/proxy
CT=proxy-caddy
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
FAILS=0
[ "$(id -u)" = 0 ] || fail "run as root"
[ "$(hostname)" = dsserver ] || fail "not dsserver"

cert_file() { find "$DATA/data/caddy/certificates" -name "$NAME.crt" 2>/dev/null | head -n1; }

token_check() {
    # The token reaches curl's config on stdin through shell builtins: never in argv or a log.
    # shellcheck disable=SC1090
    ( . "$SECRET"
      for p in user/tokens/verify "zones?name=rubusdua.net"; do
        printf 'header = "Authorization: Bearer %s"\nurl = "https://api.cloudflare.com/client/v4/%s"\n' "$CF_API_TOKEN" "$p" | curl -s -m 20 -K -; echo
      done ) | python3 -I -c '
import json, sys
v, z = (json.loads(l) for l in sys.stdin if l.strip())
st = (v.get("result") or {}).get("status")
print(("ok    " if v.get("success") and st == "active" else "FAIL  ") + f"token status at Cloudflare: {st}")
zs = [x["name"] for x in z.get("result") or []]
print(("ok    " if zs == ["rubusdua.net"] else "FAIL  ") + f"token sees zone(s): {zs}")
sys.exit(0 if v.get("success") and st == "active" and zs == ["rubusdua.net"] else 1)'
}

case "${1:-}:$#" in
  preflight:1)
    systemctl is-active --quiet docker && ok "docker active" || fail "docker not active"
    for f in proxy/compose.yaml proxy/Caddyfile beacon/compose/caddy/Dockerfile; do
      [ -f "$ROOT/$f" ] && ok "snapshot has $f" || bad "missing $ROOT/$f"; done
    [ -s "$SECRET" ] && ok "token installed ($SECRET)" || echo "info  no token installed yet"
    [ -e "$STAGED" ] && echo "info  staged token file present: $STAGED"
    ss -tlnH 'sport = :443' | grep -q . && echo "info  something listens on :443: $(ss -tlnpH 'sport = :443' | head -n1)" || ok "port 443 free"
    echo "container: $(docker inspect -f '{{.State.Status}}' $CT 2>/dev/null || echo absent)"
    echo "image: $(docker image ls dsserver-caddy --format '{{.Tag}} {{.ID}}' | head -n1)"
    [ "$FAILS" = 0 ] && echo "14 PREFLIGHT PASSED" || fail "$FAILS check(s) failed" ;;
  token-install:1)
    [ -f "$STAGED" ] && [ ! -L "$STAGED" ] || fail "missing $STAGED (or a symlink)"
    [ "$(stat -c '%U %a' "$STAGED")" = "daniel 600" ] || fail "$STAGED must be owned by daniel, mode 600"
    tok=$(head -n1 "$STAGED" | tr -d '[:space:]')
    [[ $tok =~ ^[A-Za-z0-9_-]{30,}$ ]] || fail "$STAGED does not look like a Cloudflare API token (not shown)"
    install -d -m 0700 -o root -g root /etc/dsserver-secrets
    ( umask 077; printf 'CF_API_TOKEN=%s\n' "$tok" > "$SECRET.new" ); mv "$SECRET.new" "$SECRET"; unset tok
    ok "installed $SECRET (root 0600)"
    token_check || fail "token check failed: staged file kept; fix the token and run token-install again"
    shred -u "$STAGED" && ok "staged file shredded" ;;
  token-check:1) token_check ;;
  dns-ensure:1)
    # Names come only from the reviewed Caddyfile; the token reaches curl through builtins (never argv/logs).
    # Sites marked "# cert-only" are served by another host (e.g. dsnas): never create a record for them.
    mapfile -t names < <(grep -oE '^[a-z0-9-]+\.rubusdua\.net' "$ROOT/proxy/Caddyfile" | sort -u | grep -vxF -f <(sed -n 's/^# cert-only: //p' "$ROOT/proxy/Caddyfile") || true)
    ( . "$SECRET"; cf() { printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n%s' "$CF_API_TOKEN" "$1" | curl -s -m 20 -K -; }
      zone=$(cf 'url = "https://api.cloudflare.com/client/v4/zones?name=rubusdua.net"' | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
      for n in "${names[@]}"; do
        cur=$(cf "url = \"https://api.cloudflare.com/client/v4/zones/$zone/dns_records?name=$n\"" | python3 -I -c 'import json,sys; print(" ".join("%s:%s:%s" % (r["type"], r["content"], "proxied" if r["proxied"] else "dns-only") for r in json.load(sys.stdin)["result"]))')
        if [ -z "$cur" ]; then
          r=$(cf "request = \"POST\"
url = \"https://api.cloudflare.com/client/v4/zones/$zone/dns_records\"
data = \"{\\\"type\\\":\\\"A\\\",\\\"name\\\":\\\"$n\\\",\\\"content\\\":\\\"192.168.68.115\\\",\\\"ttl\\\":1,\\\"proxied\\\":false,\\\"comment\\\":\\\"dsserver LAN HTTPS (proxy/Caddyfile); DNS only\\\"}\"
" | python3 -I -c 'import json,sys; d=json.load(sys.stdin); print("created" if d["success"] else "error %s" % d["errors"])')
          echo "$n: $r A 192.168.68.115 dns-only"
        elif [ "$cur" = "A:192.168.68.115:dns-only" ]; then echo "$n: ok (A 192.168.68.115, dns-only)"
        else echo "$n: EXISTS WITH DIFFERENT VALUE ($cur) - left unchanged"; fi
      done ) ;;
  build:1)
    "${COMPOSE[@]}" build --pull=false 2>&1 | tail -n 3
    docker image ls dsserver-caddy --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}' ;;
  up:1)
    [ -s "$SECRET" ] || fail "no token: run token-install first"
    install -d -m 0700 -o root -g root "$DATA" "$DATA/data" "$DATA/config"
    "${COMPOSE[@]}" up -d --no-build --force-recreate 2>&1 | tail -n 2
    for _ in $(seq 60); do [ -n "$(cert_file)" ] && break; sleep 5; done
    [ -n "$(cert_file)" ] && ok "certificate stored" || bad "no certificate after 5 minutes"
    docker logs --since 10m $CT 2>&1 | grep -E 'certificate obtained|error|failed' | tail -n 5 | cut -c1-300 || true
    [ "$FAILS" = 0 ] && echo "14 UP DONE" || fail "$FAILS check(s) failed" ;;
  verify:1)
    [ "$(docker inspect -f '{{.State.Running}} {{.HostConfig.RestartPolicy.Name}} {{.HostConfig.ReadonlyRootfs}}' $CT 2>/dev/null)" = "true unless-stopped true" ] \
      && ok "$CT running, restart unless-stopped, read-only root" || bad "$CT state/settings"
    [ "$(stat -c '%U %a' "$SECRET")" = "root 600" ] && ok "$SECRET root 0600" || bad "$SECRET perms"
    [ "$(stat -c '%U %a' "$DATA")" = "root 700" ] && ok "$DATA root 0700" || bad "$DATA perms"
    python3 -I - "$ROOT" "$NAME" <<'EOF' || FAILS=$((FAILS+1))
import socket, ssl, sys, time
root, name = sys.argv[1:]
ctx = ssl.create_default_context()
with socket.create_connection(("127.0.0.1", 443), 10) as s, ctx.wrap_socket(s, server_hostname=name) as t:
    c = t.getpeercert(); days = (ssl.cert_time_to_seconds(c["notAfter"]) - time.time()) / 86400
    t.sendall(f"GET / HTTP/1.1\r\nHost: {name}\r\nConnection: close\r\n\r\n".encode()); first = t.recv(64).split(b"\r\n")[0]
    issuer = dict(x[0] for x in c["issuer"])
    print(f"ok    certificate trusted, matches {name}; {issuer.get('organizationName')} {issuer.get('commonName')}; {days:.0f} days left; {t.version()}")
    print(f"ok    answer: {first.decode()}")
    sys.exit(0 if days >= 14 else 1)
EOF
    [ "$FAILS" = 0 ] && echo "14 VERIFY PASSED" || fail "$FAILS check(s) failed" ;;
  status:1)
    docker ps -a --filter "name=^$CT\$" --format '{{.Names}} {{.Image}} {{.Status}}'
    f=$(cert_file); [ -n "$f" ] && openssl x509 -in "$f" -noout -issuer -enddate || echo "no certificate yet"
    docker logs --since 24h $CT 2>&1 | tail -n 5 | cut -c1-250 || true ;;
  down:1) "${COMPOSE[@]}" down 2>&1 | tail -n 2 ;;
  *) echo "usage: sudo $0 preflight|token-install|token-check|dns-ensure|build|up|verify|status|down" >&2; exit 2 ;;
esac
