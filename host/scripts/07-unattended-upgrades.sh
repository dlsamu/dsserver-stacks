#!/bin/bash
# dsserver A1: automatic Debian security updates with unattended-upgrades. NO automatic reboot.
# Record: host/docs/host-config.md §9.  Independent of Docker and of any NAS.
#
# Usage (as root, in Konsole; each step is separate and stops on the first failed check):
#   sudo bash 07-unattended-upgrades.sh preflight   read-only: OS, APT origins, what would be installed
#   sudo bash 07-unattended-upgrades.sh install     apt-get update, install the package, add our config,
#                                                   install dsserver-reboot-needed, then run 'verify'
#   sudo bash 07-unattended-upgrades.sh verify      read-only: configuration, timers, allowed origins,
#                                                   Docker excluded, reboot status
#   sudo bash 07-unattended-upgrades.sh run-now     run one update + upgrade cycle now (installs pending
#                                                   Debian updates), then show the result
#   sudo bash 07-unattended-upgrades.sh hold        pause automatic upgrades: stop apt-daily-upgrade.timer
#                                                   (stays enabled, so a reboot also resumes it) and leave
#                                                   a visible marker; 'verify' and 'status' report PAUSED
#   sudo bash 07-unattended-upgrades.sh release     resume automatic upgrades (start the timer, drop marker)
#   sudo bash 07-unattended-upgrades.sh status      read-only: timers, hold state, reboot status
#   sudo bash 07-unattended-upgrades.sh rollback    remove only what 'install' added (copies kept first)
#
# Delegated (passwordless) use runs a root-owned snapshot of this file, see 09-delegated-sudo.sh.
#
# Files: host/files/etc/apt/apt.conf.d/52dsserver-unattended-upgrades -> /etc/apt/apt.conf.d/
#        host/bin/dsserver-reboot-needed                               -> /usr/local/sbin/
# The package itself creates /etc/apt/apt.conf.d/20auto-upgrades (daily lists + daily upgrade) and
# 50unattended-upgrades (allowed origins) through debconf/ucf; we don't overwrite them, we verify them.
# Writes nothing inside the repository.
set -euo pipefail

# Resolve symlinks: files are always read next to the REAL script, never next to a link to it
# (a link in a user-writable directory must not be able to supply our config or binaries).
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
REPO=$(cd "$HERE/../.." && pwd)
SRC_CONF=$REPO/host/files/etc/apt/apt.conf.d/52dsserver-unattended-upgrades
SRC_RBN=$REPO/host/bin/dsserver-reboot-needed
DST_CONF=/etc/apt/apt.conf.d/52dsserver-unattended-upgrades
DST_RBN=/usr/local/sbin/dsserver-reboot-needed
AUTO=/etc/apt/apt.conf.d/20auto-upgrades
HOLD=/run/dsserver-a1-hold
EXPECTED_NEW_PKGS="python3-distro-info unattended-upgrades"
DOCKER_PKGS="containerd.io docker-buildx-plugin docker-ce docker-ce-cli docker-ce-rootless-extras docker-compose-plugin"

fail() { echo; echo "FAILED: $*"; echo "Stopped. Nothing further was changed."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }
# No pipes into grep -q under pipefail (SIGPIPE lesson, host-config §7 #3): capture, then compare.
installed() { local st; st=$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) || return 1; [ "$st" = "install ok installed" ]; }

[ "$(id -u)" = 0 ] || fail "run with sudo"
CMD=${1:-}; [ $# -eq 1 ] || CMD=""

preflight() {
    step "Preflight (read-only)"
    . /etc/os-release
    [ "${ID:-}" = debian ] && [ "${VERSION_CODENAME:-}" = trixie ] || fail "expected Debian 13 trixie, found ${PRETTY_NAME:-?}"
    ok "OS: $PRETTY_NAME"
    [ -f "$SRC_CONF" ] && [ -f "$SRC_RBN" ] || fail "repository files missing under $REPO/host"

    # Every APT source must be Debian or Docker; anything else needs review first.
    POLICY=$(apt-cache policy)
    ORIGINS=$(grep -oE 'release .*' <<<"$POLICY" | grep -oE '(^|[ ,])o=[^,]+' | sed 's/.*o=//' | sort -u)
    echo "APT origins: $(tr '\n' ' ' <<<"$ORIGINS")"
    while read -r o; do
        case $o in Debian|Docker) ;; *) fail "unexpected APT origin '$o' - review it before enabling automatic upgrades" ;; esac
    done <<<"$ORIGINS"
    ok "only Debian and Docker origins configured"

    if installed unattended-upgrades; then
        ok "unattended-upgrades already installed (install step will only verify/complete)"
    else
        SIM=$(apt-get -s install --no-install-recommends unattended-upgrades)
        NEW=$(grep '^Inst ' <<<"$SIM" | awk '{print $2}' | sort | tr '\n' ' ')
        echo "would install: $NEW"
        [ "${NEW% }" = "$EXPECTED_NEW_PKGS" ] || fail "install would bring '$NEW', expected '$EXPECTED_NEW_PKGS'"
        if grep -q '^Remv ' <<<"$SIM"; then fail "install would remove packages"; fi
        ok "install brings exactly: $EXPECTED_NEW_PKGS"
    fi

    if [ -e "$DST_CONF" ]; then cmp -s "$SRC_CONF" "$DST_CONF" || fail "$DST_CONF exists and differs from the repository copy"; fi
    if [ -e "$DST_RBN" ];  then cmp -s "$SRC_RBN" "$DST_RBN"   || fail "$DST_RBN exists and differs from the repository copy"; fi
    if [ -e "$AUTO" ] && ! installed unattended-upgrades; then
        fail "$AUTO already exists without the package - inspect it first"
    fi
    ok "no conflicting files"
}

verify() {
    step "Verify (read-only)"
    installed unattended-upgrades || fail "unattended-upgrades not installed"
    ok "package: $(dpkg-query -W -f='${Version}' unattended-upgrades)"
    cmp -s "$SRC_CONF" "$DST_CONF" || fail "$DST_CONF missing or differs from the repository"
    [ "$(stat -c '%a %U:%G' "$DST_CONF")" = "644 root:root" ] || fail "$DST_CONF owner/mode"
    cmp -s "$SRC_RBN" "$DST_RBN" || fail "$DST_RBN missing or differs from the repository"
    [ "$(stat -c '%a %U:%G' "$DST_RBN")" = "755 root:root" ] || fail "$DST_RBN owner/mode"
    ok "our files match the repository"

    v() { local x; x=$(apt-config shell X "$1"); x=${x#X=\'}; echo "${x%\'}"; }
    [ "$(v APT::Periodic::Update-Package-Lists)" = 1 ] || fail "APT::Periodic::Update-Package-Lists is not 1"
    [ "$(v APT::Periodic::Unattended-Upgrade)" = 1 ]   || fail "APT::Periodic::Unattended-Upgrade is not 1"
    [ "$(v Unattended-Upgrade::Automatic-Reboot)" = false ] || fail "Automatic-Reboot is not false"
    ok "daily package lists + daily unattended upgrade; Automatic-Reboot=false"

    for t in apt-daily.timer apt-daily-upgrade.timer; do
        [ "$(systemctl is-enabled "$t")" = enabled ] || fail "$t not enabled"
        if [ "$(systemctl is-active "$t")" != active ]; then
            if [ "$t" = apt-daily-upgrade.timer ] && [ -f "$HOLD" ]; then
                echo "WARN  $t PAUSED by 'hold' since $(cat "$HOLD"): automatic upgrades are NOT running. Resume with 'release'."
            else
                fail "$t not active"
            fi
        fi
    done
    ok "apt-daily.timer and apt-daily-upgrade.timer enabled$([ -f "$HOLD" ] && echo ' (upgrade timer PAUSED)' || echo ' and active')"

    DRY=$(unattended-upgrade --dry-run --debug 2>&1) || fail "unattended-upgrade --dry-run failed:
$DRY"
    ALLOWED=$(grep -m1 'Allowed origins are:' <<<"$DRY" || true)
    [ -n "$ALLOWED" ] || fail "dry run did not report allowed origins"
    echo "$ALLOWED"
    [[ $ALLOWED == *label=Debian-Security* ]] || fail "Debian-Security is not an allowed origin"
    if [[ ${ALLOWED,,} == *docker* ]]; then fail "Docker appears in the allowed origins"; fi
    ok "allowed origins: Debian + Debian-Security only"
    UPG=$(grep -m1 'Packages that will be upgraded:' <<<"$DRY" || true)
    echo "${UPG:-Packages that will be upgraded: (none reported)}"
    for p in $DOCKER_PKGS; do
        if [[ " ${UPG#*upgraded:} " == *" $p "* ]]; then fail "dry run would upgrade Docker package $p"; fi
    done
    ok "no Docker package in the dry run's upgrade list"

    step "Docker packages (updated by hand only)"
    for p in $DOCKER_PKGS; do
        installed "$p" || continue
        POL=$(apt-cache policy "$p")
        INST=$(awk '/Installed:/ {print $2}' <<<"$POL"); CAND=$(awk '/Candidate:/ {print $2}' <<<"$POL")
        printf '  %-28s installed %-28s candidate %s%s\n' "$p" "$INST" "$CAND" "$([ "$INST" != "$CAND" ] && echo '  <- manual update available')"
    done

    step "Shutdown helper and reboot status"
    echo "unattended-upgrades.service (waits for a running upgrade at shutdown): $(systemctl is-enabled unattended-upgrades.service 2>/dev/null || true)"
    "$DST_RBN" || true
    echo; echo "07 VERIFY PASSED $(date -Is)"
}

install_all() {
    step "Refresh package lists"
    apt-get update -q
    preflight
    step "Install unattended-upgrades (automatic updates enabled through debconf)"
    if ! installed unattended-upgrades; then
        echo 'unattended-upgrades unattended-upgrades/enable_auto_updates boolean true' | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends unattended-upgrades
    fi
    step "Install our files"
    [ -e "$DST_CONF" ] || install -m 0644 -o root -g root "$SRC_CONF" "$DST_CONF"
    [ -e "$DST_RBN" ]  || install -m 0755 -o root -g root "$SRC_RBN" "$DST_RBN"
    ok "installed $DST_CONF and $DST_RBN"
    verify
    echo; echo "07 INSTALL PASSED. Next: 'run-now' (optional, installs pending updates now) or wait for the 06:00 timer."
}

run_now() {
    step "Run one cycle now: package lists, then unattended upgrade (this can take a few minutes)"
    systemctl start apt-daily.service
    systemctl start apt-daily-upgrade.service
    for s in apt-daily.service apt-daily-upgrade.service; do
        R=$(systemctl show -p Result --value "$s"); echo "$s result: $R"; [ "$R" = success ] || fail "$s result $R (see: journalctl -u $s)"
    done
    for f in /var/lib/apt/periodic/update-stamp /var/lib/apt/periodic/upgrade-stamp; do
        [ -f "$f" ] || fail "$f was not written"
        echo "$f: $(date -r "$f" -Is)"
    done
    step "Last unattended-upgrades log lines"
    tail -n 15 /var/log/unattended-upgrades/unattended-upgrades.log || true
    step "Reboot status"
    "$DST_RBN" || true
    echo; echo "07 RUN-NOW PASSED $(date -Is)"
}

hold() {
    step "Hold: pause automatic upgrades"
    systemctl stop apt-daily-upgrade.timer
    date -Is >"$HOLD"
    [ "$(systemctl is-active apt-daily-upgrade.timer)" != active ] || fail "timer still active"
    echo "PAUSED: apt-daily-upgrade.timer stopped (still enabled; a reboot resumes it). Package lists still refresh."
    echo "Resume with: release"
}

release() {
    step "Release: resume automatic upgrades"
    systemctl start apt-daily-upgrade.timer
    rm -f -- "$HOLD"
    [ "$(systemctl is-active apt-daily-upgrade.timer)" = active ] || fail "timer did not start"
    systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager
    echo "RESUMED: automatic upgrades active"
}

status() {
    step "Status (read-only)"
    systemctl list-timers apt-daily.timer apt-daily-upgrade.timer --no-pager || true
    if [ -f "$HOLD" ]; then echo "automatic upgrades: PAUSED since $(cat "$HOLD") (run 'release')"
    elif [ "$(systemctl is-active apt-daily-upgrade.timer)" = active ]; then echo "automatic upgrades: ACTIVE"
    else echo "automatic upgrades: timer INACTIVE without a hold marker - investigate"; fi
    for f in /var/lib/apt/periodic/update-stamp /var/lib/apt/periodic/upgrade-stamp; do
        echo "$f: $([ -f "$f" ] && date -r "$f" -Is || echo missing)"
    done
    [ -x "$DST_RBN" ] && { "$DST_RBN" || true; }
}

rollback() {
    step "Rollback: remove only what 'install' added"
    B=/root/dsserver-rollback/07-$(date +%Y%m%dT%H%M%S); install -d -m 0700 "$B"
    for f in "$DST_CONF" "$DST_RBN" "$AUTO" /etc/apt/apt.conf.d/50unattended-upgrades; do
        if [ -e "$f" ]; then cp -a "$f" "$B/"; echo "saved $f -> $B/"; fi
    done
    rm -f -- "$DST_CONF" "$DST_RBN" "$HOLD"
    systemctl start apt-daily-upgrade.timer 2>/dev/null || true
    if installed unattended-upgrades; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -q unattended-upgrades
    fi
    [ ! -e "$AUTO" ] || fail "$AUTO still present after purge (saved in $B); inspect it"
    X=$(apt-config shell X APT::Periodic::Unattended-Upgrade); [ -z "$X" ] || [ "$X" = "X='0'" ] || fail "APT::Periodic::Unattended-Upgrade still set: $X"
    echo "python3-distro-info was pulled in as a dependency; review with: apt-get -s autoremove"
    echo; echo "07 ROLLBACK DONE $(date -Is). Copies: $B"
}

case $CMD in
    preflight) preflight; echo; echo "07 PREFLIGHT PASSED (nothing changed)" ;;
    install)   install_all ;;
    verify)    verify ;;
    run-now)   run_now ;;
    hold)      hold ;;
    release)   release ;;
    status)    status ;;
    rollback)  rollback ;;
    *) echo "usage: sudo bash $0 preflight|install|verify|run-now|hold|release|status|rollback" >&2; exit 2 ;;
esac
