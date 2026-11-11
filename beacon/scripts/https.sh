#!/bin/bash
# HTTPS for Beacon (Caddy + Let's Encrypt DNS-01 via Cloudflare). Run on dsserver as daniel; works on
# Beacon over `ssh beacon` (NOPASSWD sudo there). README "HTTPS" is the operating guide.
#
#   build          sync /srv/stacks/beacon to Beacon (scripts/deploy.sh) and build the Caddy image
#   test-local     throw-away proxy on Beacon 127.0.0.1:8443 (internal CA): dashboard, SSE, WebSocket,
#                  login; removed afterwards. Needs no token, opens nothing.
#   token-install  move the Cloudflare token from ~/.cloudflare-token-beacon (yours, 0600, one line)
#                  to Beacon /etc/beacon-secrets/cloudflare.env (root 0600), check it at Cloudflare
#                  (active, sees zone rubusdua.net), then shred the local file. Never prints it.
#   token-check    re-check the installed token at Cloudflare
#   up             start Caddy (obtains/renews the certificate itself); waits for the certificate
#   verify         full check on Beacon (trusted cert, login, SSE, WebSocket) and from dsserver by name
#   status         container, certificate expiry, recent Caddy log lines
#   down           stop and remove the Caddy container (certificates and account kept); hub untouched
set -euo pipefail
B=/srv/beacon
NAME=beacon.rubusdua.net
BEACON_IP=192.168.68.121
STAGED=$HOME/.cloudflare-token-beacon
COMPOSE="docker compose -f $B/compose/caddy/compose.yaml"
on() { ssh -o BatchMode=yes beacon "$@"; }

case ${1:-} in
  build)
    bash /srv/stacks/beacon/scripts/deploy.sh
    on "sudo $COMPOSE build --pull=false 2>&1 | tail -n 3; sudo docker image ls beacon-caddy --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'" ;;
  test-local)
    on "set -e
      sudo docker rm -f caddy-proxytest >/dev/null 2>&1 || true
      sudo docker run -d --name caddy-proxytest --network host --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
        --security-opt no-new-privileges:true --tmpfs /data --tmpfs /config --tmpfs /tmp \
        -v $B/compose/caddy/Caddyfile.test:/etc/caddy/Caddyfile:ro beacon-caddy:2.11.9-cf0.2.4 >/dev/null
      for i in \$(seq 20); do sudo ss -tlnH 'sport = :8443' | grep -q 127.0.0.1 && break; sleep 0.5; done
      rc=0; sudo python3 -I $B/scripts/https_check.py $NAME --ip 127.0.0.1 --port 8443 --insecure --login || rc=\$?
      sudo docker rm -f caddy-proxytest >/dev/null; echo 'test proxy removed'; exit \$rc" ;;
  token-install)
    [ -f "$STAGED" ] && [ ! -L "$STAGED" ] || { echo "missing $STAGED (see README 'HTTPS: Cloudflare token')" >&2; exit 1; }
    [ "$(stat -c '%U %a' "$STAGED")" = "$USER 600" ] || { echo "$STAGED must be yours, mode 600" >&2; exit 1; }
    tok=$(head -n1 "$STAGED" | tr -d '[:space:]')
    [[ $tok =~ ^[A-Za-z0-9_-]{30,}$ ]] || { echo "$STAGED does not look like a Cloudflare API token (not shown)" >&2; exit 1; }
    printf 'CF_API_TOKEN=%s\n' "$tok" | on 'sudo install -d -m 0700 /etc/beacon-secrets &&
      sudo sh -c "umask 077; cat > /etc/beacon-secrets/cloudflare.env.new && mv /etc/beacon-secrets/cloudflare.env.new /etc/beacon-secrets/cloudflare.env"'
    unset tok
    echo "installed on Beacon: /etc/beacon-secrets/cloudflare.env (root 0600)"
    bash "$0" token-check
    shred -u "$STAGED" && echo "local copy $STAGED shredded" ;;
  token-check)
    # The token is put into curl's config on stdin by shell builtins: never in a command line or log.
    on 'sudo sh -c ". /etc/beacon-secrets/cloudflare.env
        for p in user/tokens/verify \"zones?name=rubusdua.net\"; do
          printf \"header = \\\"Authorization: Bearer %s\\\"\\nurl = \\\"https://api.cloudflare.com/client/v4/%s\\\"\\n\" \"\$CF_API_TOKEN\" \"\$p\" | curl -s -m 20 -K -; echo
        done"' | python3 -c '
import json, sys
v, z = (json.loads(l) for l in sys.stdin if l.strip())
st = (v.get("result") or {}).get("status")
print(("ok    " if v.get("success") and st == "active" else "FAIL  ") + f"token status at Cloudflare: {st}")
zs = [x["name"] for x in z.get("result") or []]
print(("ok    " if zs == ["rubusdua.net"] else "FAIL  ") + f"token sees zone(s): {zs}")
sys.exit(0 if v.get("success") and st == "active" and zs == ["rubusdua.net"] else 1)' ;;
  up)
    on "sudo test -s /etc/beacon-secrets/cloudflare.env" || { echo "no token on Beacon: run token-install first" >&2; exit 1; }
    on "sudo install -d -m 0700 -o root -g root /srv/appdata/caddy /srv/appdata/caddy/data /srv/appdata/caddy/config
        sudo $COMPOSE up -d --no-build --force-recreate 2>&1 | tail -n 2"
    echo "waiting for the certificate (DNS-01 takes ~30-90 s)..."
    for _ in $(seq 60); do
      if on "sudo find /srv/appdata/caddy/data/caddy/certificates -name '$NAME.crt' 2>/dev/null | grep -q ."; then
        echo "certificate stored"; break; fi
      sleep 5
    done
    on "sudo docker logs --since 10m caddy 2>&1 | grep -E 'certificate obtained|error|failed' | tail -n 5 | cut -c1-300" || true ;;
  verify)
    echo "== on Beacon (127.0.0.1:443, public trust store, automation login)"
    on "sudo python3 -I $B/scripts/https_check.py $NAME --ip 127.0.0.1 --login"
    echo "== from dsserver ($(hostname -I | cut -d' ' -f1)) by name"
    python3 -I /srv/stacks/beacon/scripts/https_check.py $NAME ;;
  status)
    on "sudo docker ps -a --filter name=^caddy\$ --format '{{.Names}} {{.Image}} {{.Status}}'
        f=\$(sudo find /srv/appdata/caddy/data/caddy/certificates -name '$NAME.crt' 2>/dev/null | head -n1)
        [ -n \"\$f\" ] && sudo openssl x509 -in \"\$f\" -noout -issuer -enddate || echo 'no certificate yet'
        sudo docker logs --since 24h caddy 2>&1 | tail -n 5 | cut -c1-250" ;;
  down)
    on "sudo $COMPOSE down 2>&1 | tail -n 2" ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
