#!/bin/bash
# dsserver: create or verify /srv/stacks and /srv/appdata, prove the bind-mount permission model,
# and check that non-admin users can't read either directory. Idempotent.
#
# Usage:  sudo bash 06-srv-dirs.sh [--no-probe]
#   Copy it out of the repository first (e.g. to /tmp) so root never writes inside /srv/stacks.
#
# Behaviour:
#   - a MISSING directory is created: /srv/appdata root:root 0700, /srv/stacks daniel:daniel 0750 (empty)
#   - an EXISTING directory is only checked; its owner/mode/contents are never changed.
#     A wrong owner or mode is reported and the script exits 1 (fix it deliberately, by hand).
#   - probe (skipped with --no-probe): a throwaway container as uid 2001 must be able to write to a
#     2001-owned 0750 directory under /srv/appdata, and uid 2002 must be refused. It uses
#     /srv/appdata/_probe, refuses to run if that already exists, removes only what it created, and
#     removes the probe image only if it wasn't present before.
#   - isolation: every non-admin login user (uid 1000-59999, not in sudo) must be denied listing both dirs.
# SRV_ROOT=<dir> runs against a scratch directory for testing: no chown, no probe, no isolation check.
#
# Origin: replaces the one-off phaseS-root.sh (S1, 2026-11-09), which refused to run on existing dirs.
set -euo pipefail

IMG='docker.io/library/alpine:3.24.4@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf'
ROOT=${SRV_ROOT:-/srv}
TEST=no; [ -n "${SRV_ROOT:-}" ] && TEST=yes
PROBE=yes
case $# in
    0) ;;
    1) [ "$1" = "--no-probe" ] || { echo "usage: $0 [--no-probe]" >&2; exit 2; }; PROBE=no ;;
    *) echo "usage: $0 [--no-probe]" >&2; exit 2 ;;
esac

fail() { echo; echo "FAILED: $*"; exit 1; }
step() { echo; echo "=== $*"; }
RC=0

if [ "$TEST" = no ]; then
    [ "$(id -u)" = 0 ] || fail "run with sudo"
    getent passwd daniel >/dev/null || fail "user daniel missing"
fi

# ensure <path> <owner:group> <mode>
ensure() {
    local d=$1 og=$2 mode=$3 want cur
    want="${mode#0} $og"
    [ "$TEST" = yes ] && want="${mode#0} $(id -un):$(id -gn)"
    if [ -L "$d" ]; then echo "PROBLEM  $d is a symlink - not changed"; RC=1; return; fi
    if [ -e "$d" ]; then
        [ -d "$d" ] || { echo "PROBLEM  $d exists but is not a directory - not changed"; RC=1; return; }
        cur=$(stat -c '%a %U:%G' "$d")
        if [ "$cur" = "$want" ]; then echo "ok       $d ($cur) - existing, left as is"
        else echo "PROBLEM  $d is '$cur', expected '$want' - NOT changed"; RC=1; fi
    else
        if [ "$TEST" = yes ]; then install -d -m "$mode" "$d"; else install -d -o "${og%:*}" -g "${og#*:}" -m "$mode" "$d"; fi
        cur=$(stat -c '%a %U:%G' "$d")
        [ "$cur" = "$want" ] || fail "created $d but it is '$cur'"
        echo "created  $d ($cur)"
    fi
}

echo "##### 06-srv-dirs $(date -Is) on $(hostname); probe=$PROBE test=$TEST"
step "1. Directories"
[ -d "$ROOT" ] || fail "$ROOT does not exist"
ensure "$ROOT/appdata" root:root   0700
ensure "$ROOT/stacks"  daniel:daniel 0750
[ "$RC" = 0 ] || fail "existing directories don't match the expected owner/mode (see PROBLEM lines); nothing was changed"

if [ "$TEST" = yes ]; then echo; echo "TEST MODE: probe and isolation checks skipped."; exit 0; fi

if [ "$PROBE" = yes ]; then
    step "2. Probe: bind-mount permissions below the 0700 parent"
    [ "$(systemctl is-active docker)" = active ] || fail "docker is not running (use --no-probe to skip)"
    P=/srv/appdata/_probe
    [ -e "$P" ] && fail "$P already exists; refusing to touch it"
    HAD_IMG=no; docker image inspect "$IMG" >/dev/null 2>&1 && HAD_IMG=yes
    cleanup() {
        [ -d "$P" ] && rm -rf --one-file-system "$P"
        [ "$HAD_IMG" = no ] && docker image rm "$IMG" >/dev/null 2>&1 || true
    }
    trap cleanup EXIT
    install -d -m 0755 -o root -g root "$P"
    install -d -m 0750 -o 2001 -g 2001 "$P/data"
    OUT=$(docker run --rm --network none --read-only --user 2001:2001 \
          --mount type=bind,source="$P/data",target=/data "$IMG" \
          sh -c 'echo probe-ok > /data/t && cat /data/t && id -u') || fail "uid 2001 could not write to its bind mount"
    [[ $OUT == *probe-ok*2001* ]] || fail "unexpected probe output: $OUT"
    [ "$(stat -c '%u:%g' "$P/data/t")" = 2001:2001 ] || fail "probe file not owned by 2001:2001 on the host"
    echo "uid 2001: write OK, host sees $(stat -c '%u:%g' "$P/data/t")"
    if docker run --rm --network none --read-only --user 2002:2002 \
          --mount type=bind,source="$P/data",target=/data "$IMG" sh -c 'echo x > /data/u' 2>/dev/null; then
        fail "uid 2002 could write to a 2001-owned 0750 directory"
    fi
    echo "uid 2002: refused (OK)"
    cleanup; trap - EXIT
    [ ! -e "$P" ] || fail "probe directory not removed"
    echo "probe cleaned up (image removed: $([ "$HAD_IMG" = no ] && echo yes || echo 'no, it was present before'))"
else
    step "2. Probe skipped (--no-probe)"
fi

step "3. Isolation: non-admin users can't list /srv/stacks or /srv/appdata"
SUDOERS=$(getent group sudo | cut -d: -f4)
USERS=$(getent passwd | awk -F: '$3>=1000 && $3<60000 {print $1}')
N=0
for u in $USERS; do
    [[ ,$SUDOERS, == *,$u,* ]] && continue
    for d in /srv/stacks /srv/appdata; do
        if runuser -u "$u" -- ls "$d" >/dev/null 2>&1; then fail "$u can list $d"; fi
        echo "$u -> $d: denied (OK)"
    done
    N=$((N+1))
done
[ "$N" -gt 0 ] || echo "(no non-admin login users to check)"

echo; echo "06-srv-dirs PASSED $(date -Is)"
