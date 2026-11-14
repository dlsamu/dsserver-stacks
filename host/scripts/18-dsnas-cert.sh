#!/bin/bash
# dsnas: trusted HTTPS (https://dsnas.rubusdua.net, served by DSM itself). Caddy on dsserver obtains/renews the
# Let's Encrypt certificate by DNS-01; host/bin/dsnas-cert-push imports it into DSM. Design: docs/internal-https.md.
# Delegated through host/scripts/09-delegated-sudo.sh (runs from the root-owned snapshot).
#
#   preflight      read-only: Caddy certificate present, password file, DSM reachable, timer state
#   gen-password   create /etc/dsserver-secrets/dsnas-cert-deploy.pw (root 0600, 32 random characters) if it does
#                  not exist yet; never prints it. The owner reads it in Konsole to create the DSM account.
#   check          read-only: Caddy's vs dsnas's certificate, trust, days left
#   push           deploy if different (what the timer runs)
#   force          re-import the current certificate (renewal simulation, no reissue)
#   install        install + enable dsnas-cert-push.service/.timer (daily), then run it once
#   status         timer, last runs
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
PUSH="$ROOT/host/bin/dsnas-cert-push"
PW=/etc/dsserver-secrets/dsnas-cert-deploy.pw
UNITS="dsnas-cert-push.service dsnas-cert-push.timer"
fail() { echo "FAILED: $*"; exit 1; }
ok()   { echo "ok    $*"; }
[ "$(id -u)" = 0 ] || fail "run as root"
[ $# -eq 1 ] || { sed -n '2,14p' "$0"; exit 2; }
case $1 in
  preflight)
    [ -n "$(find /srv/appdata/proxy/data/caddy/certificates -name 'dsnas.rubusdua.net.crt' 2>/dev/null)" ] \
        && ok "Caddy holds a certificate for dsnas.rubusdua.net" || echo "info  no Caddy certificate for dsnas yet (14-https-proxy.sh up)"
    [ -s "$PW" ] && [ "$(stat -c '%U %a' "$PW")" = "root 600" ] && ok "$PW root 0600" || echo "info  $PW missing (gen-password)"
    timeout 5 bash -c '</dev/tcp/192.168.68.112/443' && ok "dsnas 443 reachable" || fail "dsnas 443 not reachable"
    systemctl is-enabled dsnas-cert-push.timer 2>/dev/null | sed 's/^/info  timer: /' || true ;;
  gen-password)
    install -d -m 0700 -o root -g root /etc/dsserver-secrets
    if [ -s "$PW" ]; then ok "$PW exists (unchanged)"; else
        ( umask 077; python3 -I -c 'import secrets,string; a=string.ascii_letters+string.digits; print("".join(secrets.choice(a) for _ in range(32)))' > "$PW" )
        chown root:root "$PW"; chmod 0600 "$PW"; ok "$PW created (32 characters, root 0600)"; fi ;;
  check) "$PUSH" check ;;
  push)  "$PUSH" push ;;
  force) "$PUSH" force ;;
  install)
    for u in $UNITS; do install -m 0644 "$ROOT/host/files/etc/systemd/system/$u" "/etc/systemd/system/$u"; done
    systemctl daemon-reload; systemctl enable --now dsnas-cert-push.timer >/dev/null 2>&1
    systemctl start dsnas-cert-push.service; sleep 3
    journalctl -u dsnas-cert-push.service -n 6 --no-pager -o cat
    [ "$(systemctl show -p Result --value dsnas-cert-push.service)" = success ] && ok "timer enabled; first run ok" || fail "first run failed" ;;
  status)
    systemctl list-timers dsnas-cert-push.timer --no-pager | head -2
    journalctl -u dsnas-cert-push.service -n 8 --no-pager -o short-iso ;;
  *) sed -n '2,14p' "$0"; exit 2 ;;
esac
