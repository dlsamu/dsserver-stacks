#!/bin/bash
# dsserver: off-device backups (restic -> dsnas server-backup). Design: backup/README.md. Delegated through
# host/scripts/09-delegated-sudo.sh (always runs the reviewed snapshot).
#
#   preflight       read-only: restic, secrets (root-only), paths, Healthchecks config
#   install-restic  apt-get install restic + cifs-utils (Debian packages; no services)
#   cred-install    root-only secrets: SMB login from ~daniel/.config/nas/dsnas-accounts.cred (dsserver-backup=),
#                   and a new random restic repository password if none exists. Never prints them.
#   hc-key-install  ~daniel/.healthchecks-api-key (one line, 0600) -> root-only; staged file shredded
#   hc-sync         create/update the Healthchecks checks for dsserver + Beacon, store ping URLs root-only
#   hc-test-missed  temporary Healthchecks check: missed run -> "down" (e-mail), then deleted
#   hc-key-remove   shred the Healthchecks API key (after setup and tests)
#   init            create the repository + destination marker (refuses if one exists)
#   units-install   install/refresh hostbackup@.service + timers (enables them)
#   run-backup | run-check | run-fullcheck | run-prune | run-drill
#                   start that job through its systemd unit, wait, show its log (same path as the timer)
#   test            failure-mode tests against a disposable repository (backup/tests/test_hostbackup.py)
#   status | snapshots | mount-test     read-only
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
B="$ROOT/backup"; PROG="$B/hostbackup.py"
SEC=/etc/dsserver-secrets/backup
fail() { echo "FAILED: $*"; exit 1; }
ok()   { echo "ok    $*"; }
[ "$(id -u)" = 0 ] || fail "run as root"
[ $# -eq 1 ] || { sed -n '2,22p' "$0"; exit 2; }
hb() { python3 -I "$PROG" "$@"; }
runjob() {
    local u="hostbackup@$1.service" since; since=$(date '+%F %T')
    systemctl reset-failed "$u" 2>/dev/null || true
    systemctl start "$u"
    while [ "$(systemctl is-active "$u")" = active ] || [ "$(systemctl is-active "$u")" = activating ]; do sleep 5; done
    journalctl -u "$u" --since "$since" --no-pager -o cat | grep -vE '^(Started|Starting|Finished|hostbackup@)' || true
    [ "$(systemctl show -p Result --value "$u")" = success ] && ok "$1 finished (unit result success)" || fail "$1 failed (unit result $(systemctl show -p Result --value "$u"))"
}
case $1 in
  preflight) hb preflight ;;
  install-restic)
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends restic cifs-utils >/dev/null
    ok "$(restic version)"; ok "$(dpkg-query -W -f='cifs-utils ${Version}' cifs-utils)" ;;
  cred-install)
    install -d -m 0700 -o root -g root /etc/dsserver-secrets "$SEC"
    src=/home/daniel/.config/nas/dsnas-accounts.cred
    if [ -s "$SEC/smb.cred" ]; then ok "$SEC/smb.cred exists (unchanged)"
    else
        [ -s "$src" ] || fail "$src missing"
        ( umask 077; python3 -I - "$src" "$SEC/smb.cred" <<'PY'
import sys, os
pw = next(l.split("=", 1)[1].rstrip("\n") for l in open(sys.argv[1]) if l.startswith("dsserver-backup="))
fd = os.open(sys.argv[2], os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, f"username=dsserver-backup\npassword={pw}\n".encode()); os.close(fd)
PY
        ); ok "$SEC/smb.cred created (root 0600)"; fi
    if [ -s "$SEC/restic.pw" ]; then ok "$SEC/restic.pw exists (unchanged)"
    else ( umask 077; python3 -I -c 'import secrets; print(secrets.token_urlsafe(36))' > "$SEC/restic.pw" ); ok "$SEC/restic.pw created (root 0600) - copy it into Bitwarden"; fi ;;
  hc-key-install)
    st=/home/daniel/.healthchecks-api-key; [ -s "$st" ] || fail "$st missing"
    install -d -m 0700 "$SEC"; ( umask 077; tr -d ' \n' < "$st" > "$SEC/healthchecks-api-key" ); shred -u "$st"; ok "API key installed root-only, staged file shredded" ;;
  hc-sync) python3 -I "$B/hc_setup.py" sync ;;
  hc-test-missed) python3 -I "$B/hc_setup.py" test-missed ;;
  hc-key-remove) [ -e "$SEC/healthchecks-api-key" ] && shred -u "$SEC/healthchecks-api-key"; ok "API key removed" ;;
  init) hb init ;;
  units-install) python3 -I "$B/install-units.py" "$PROG" ;;
  run-backup) runjob backup ;;
  run-check) runjob check ;;
  run-fullcheck) runjob fullcheck ;;
  run-prune) runjob prune ;;
  run-drill) runjob drill ;;
  test) python3 -I "$B/tests/test_hostbackup.py" ;;
  status) hb status; systemctl list-timers 'hostbackup-*' --no-pager ;;
  snapshots) hb snapshots ;;
  mount-test) hb mount-test ;;
  *) sed -n '2,22p' "$0"; exit 2 ;;
esac
