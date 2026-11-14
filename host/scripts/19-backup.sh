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
#   xrecover-beacon      cross-machine recovery test: Beacon's repository restored ON dsserver with docs/recovery.md
#                        section 1 as written (Beacon's credentials fetched root-to-root, shredded afterwards)
#   xrecover-on-beacon   the same in the other direction: dsserver's repository restored ON Beacon
#   alert-drill          prove the failure path: mark integrity 'unknown' and run prune through its unit -> prune
#                        refuses (deletes nothing), unit fails (Beszel SystemdFailed -> ntfy), Healthchecks 'fail' (e-mail)
#   alert-drill-clear    recovery: check (integrity ok) + prune (nothing to forget yet) -> both alerts recover
#   status | snapshots | mount-test     read-only
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
B="$ROOT/backup"; PROG="$B/hostbackup.py"
SEC=/etc/dsserver-secrets/backup
fail() { echo "FAILED: $*"; exit 1; }
ok()   { echo "ok    $*"; }
[ "$(id -u)" = 0 ] || fail "run as root"
[ $# -eq 1 ] || { sed -n '2,28p' "$0"; exit 2; }
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
  xrecover-beacon)
    install -d -m 0700 /root/rb
    for f in smb.cred restic.pw; do sudo -u daniel ssh beacon "sudo cat /etc/beacon-secrets/backup/$f" | ( umask 077; cat > /root/rb/$f ); done
    SHARE=beacon-backup REPO=beacon/restic bash "$B/recovery-test.sh" "$ROOT/docs/recovery.md" ;;
  xrecover-on-beacon)
    rb() { sudo -u daniel ssh beacon "$@"; }
    rb "sudo install -d -m 0700 /root/rb && sudo install -d -m 0700 /root/rbtest"
    for f in smb.cred restic.pw; do rb "sudo sh -c 'umask 077; cat > /root/rb/$f'" < "$SEC/$f"; done
    rb "sudo sh -c 'cat > /root/rbtest/recovery.md'" < "$ROOT/docs/recovery.md"
    rb "sudo sh -c 'cat > /root/rbtest/recovery-test.sh'" < "$B/recovery-test.sh"
    rb "sudo env SHARE=server-backup REPO=dsserver/restic bash /root/rbtest/recovery-test.sh /root/rbtest/recovery.md; r=\$?; sudo rm -rf /root/rbtest; exit \$r" ;;
  alert-drill)
    python3 -I - <<'PY'
import json; p = "/var/lib/hostbackup/state.json"; s = json.load(open(p)); s["integrity"] = "unknown"; json.dump(s, open(p, "w"), indent=1)
print("info  integrity set to 'unknown' (drill): prune must refuse")
PY
    ( runjob prune ) || true
    [ "$(systemctl show -p Result --value hostbackup@prune.service)" != success ] && ok "prune refused and the unit FAILED as intended: expect ntfy (Beszel dsserver SystemdFailed, within ~10 min) and a Healthchecks e-mail" || fail "prune did not fail" ;;
  alert-drill-clear) runjob check && runjob prune ;;
  status) hb status; systemctl list-timers 'hostbackup-*' --no-pager ;;
  snapshots) hb snapshots ;;
  mount-test) hb mount-test ;;
  *) sed -n '2,28p' "$0"; exit 2 ;;
esac
