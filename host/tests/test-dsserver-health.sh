#!/bin/bash
# Unprivileged tests for host/bin/dsserver-health and host/bin/dsserver-reboot-needed.
# Run as daniel (NOT root; the scripts ignore test overrides under root):  bash host/tests/test-dsserver-health.sh
# Uses fake systemctl/smartctl/curl in a temporary directory: no network, no system changes.
set -uo pipefail

REPO=$(cd "$(dirname "$0")/../.." && pwd)
DSH=$REPO/host/bin/dsserver-health
RBN=$REPO/host/bin/dsserver-reboot-needed
[ "$(id -u)" != 0 ] || { echo "run as a normal user"; exit 2; }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
PASS=0; FAILN=0
URL=https://hc-ping.com/0123abcd-4567-89ab-cdef-0123456789ab

# --- fakes ---
mkdir -p "$T/bin" "$T/stamps"
cat >"$T/bin/systemctl" <<'EOF'
#!/bin/bash
case "$1" in
  list-units) printf '%b' "${FAKE_FAILED:-}" ;;
  is-active) echo "${FAKE_DOCKER:-active}"; [ "${FAKE_DOCKER:-active}" = active ] ;;
esac
EOF
cat >"$T/bin/smartctl" <<'EOF'
#!/bin/bash
if [ "$1" = --scan ]; then printf '%b' "${FAKE_SCAN-/dev/nvme0 -d nvme # /dev/nvme0, NVMe device\n}"; exit 0; fi
echo "$*" >>"$FAKE_DIR/smartctl.args"; exit "${FAKE_SMART_RC:-0}"
EOF
cat >"$T/bin/curl" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >"$FAKE_DIR/curl.args"
cat /dev/fd/3 >"$FAKE_DIR/curl.conf" 2>/dev/null
echo "curl: (7) fake error mentioning $(cat "$FAKE_DIR/curl.conf")" >&2
exit "${FAKE_CURL_RC:-0}"
EOF
cat >"$T/bin/rbn" <<'EOF'
#!/bin/bash
if [ "${FAKE_RBN_RC:-0}" = 1 ]; then echo "REBOOT NEEDED: fake"; exit 1; fi; echo "no reboot needed"
EOF
chmod +x "$T/bin/"*

reset() {
    export FAKE_DIR=$T DSH_SYSTEMCTL=$T/bin/systemctl DSH_SMARTCTL=$T/bin/smartctl DSH_CURL=$T/bin/curl
    export DSH_REBOOT_NEEDED=$T/bin/rbn DSH_STAMP_DIR=$T/stamps DSH_CONF=$T/ping-url DSH_TEST_FLAG=$T/flag
    export DSH_DISK_MAX_PCT=100
    unset FAKE_FAILED FAKE_DOCKER FAKE_SCAN FAKE_SMART_RC FAKE_CURL_RC FAKE_RBN_RC
    rm -f "$T/curl.args" "$T/curl.conf" "$T/smartctl.args" "$T/flag"
    touch "$T/stamps/update-stamp" "$T/stamps/upgrade-stamp"
    printf '%s\n' "$URL" >"$T/ping-url"; chmod 600 "$T/ping-url"
}
run() { OUT=$("$DSH" "$@" 2>&1); RC=$?; }
check() { # check <name> <condition...>
    local name=$1; shift
    if "$@"; then PASS=$((PASS+1)); echo "PASS  $name"; else FAILN=$((FAILN+1)); echo "FAIL  $name"; echo "      rc=$RC out=$OUT"; fi
}
has()  { [[ $1 == *"$2"* ]]; }
nothas() { [[ $1 != *"$2"* ]]; }
conf() { cat "$T/curl.conf" 2>/dev/null; }
args() { cat "$T/curl.args" 2>/dev/null; }
noleak() { nothas "$OUT" "0123abcd" && nothas "$(args)" "0123abcd"; }

# 1 healthy
reset; run --ping
check "healthy: rc 0"                  [ "$RC" = 0 ]
check "healthy: success URL"           [ "$(conf)" = "url = \"$URL\"" ]
check "healthy: body"                  has "$(args)" "status=ok info=docker:active"
check "healthy: URL not in output/args" noleak
check "healthy: https only, timeouts"  has "$(args)" "=https"
check "healthy: max-time 10"           has "$(args)" $'--max-time\n10'

# 2 failed host unit -> /fail, unit name stays local
reset; export FAKE_FAILED='secret-thing.service loaded failed failed X\n'; run --ping
check "failed unit: /fail URL"         [ "$(conf)" = "url = \"$URL/fail\"" ]
check "failed unit: code in body"      has "$(args)" "problems=failed_units"
check "failed unit: name not external" nothas "$(args)" "secret-thing"
check "failed unit: name in local log" has "$OUT" "secret-thing.service"

# 3 Docker stopped deliberately -> NOT a host failure
reset; export FAKE_DOCKER=inactive; run --ping
check "docker inactive: success URL"   [ "$(conf)" = "url = \"$URL\"" ]
check "docker inactive: reported"      has "$(args)" "docker:inactive"

# 4 Docker crashed (failed unit) -> reported, not a host failure
reset; export FAKE_DOCKER=failed FAKE_FAILED='docker.service loaded failed failed D\ncontainerd.service loaded failed failed C\n'; run --ping
check "docker failed: success URL"     [ "$(conf)" = "url = \"$URL\"" ]
check "docker failed: info"            has "$(args)" "docker:failed"
check "docker failed: local detail"    has "$OUT" "application-layer unit failed"

# 5 SMART failing / unreadable / old error-log bit only
reset; export FAKE_SMART_RC=8; run --ping
check "smart rc8: disk_health"         has "$(args)" "problems=disk_health"
reset; export FAKE_SMART_RC=2; run --ping
check "smart rc2: disk_unreadable"     has "$(args)" "problems=disk_unreadable"
reset; export FAKE_SMART_RC=64; run --ping
check "smart rc64: still ok"           has "$(args)" "status=ok"
reset; export FAKE_SCAN=''; run --ping
check "smart no disks: disk_unreadable" has "$(args)" "disk_unreadable"
reset; run --ping
check "smart nvme: no -n standby"      nothas "$(cat "$T/smartctl.args")" "standby"
reset; export FAKE_SCAN='/dev/sda -d sat # x\n'; run --ping
check "smart sata: -n standby,0"       has "$(cat "$T/smartctl.args")" "standby,0"

# 6 disk space
reset; export DSH_DISK_MAX_PCT=0; run --ping
check "disk space: problem"            has "$(args)" "problems=disk_space"

# 7 stale / missing update stamps
reset; touch -d '-80 hours' "$T/stamps/upgrade-stamp"; run --ping
check "stale upgrade-stamp"            has "$(args)" "problems=updates_stale"
reset; rm "$T/stamps/update-stamp"; run --ping
check "missing update-stamp"           has "$(args)" "updates_stale"
reset; touch -d '-70 hours' "$T/stamps/upgrade-stamp"; run --ping
check "70h stamp still ok"             has "$(args)" "status=ok"

# 8 several problems -> one code each, comma separated
reset; export FAKE_FAILED='a.service x\nb.service y\n' FAKE_SMART_RC=8 DSH_DISK_MAX_PCT=0; run --ping
check "multi: codes"                   has "$(args)" "problems=failed_units,disk_health,disk_space"

# 9 test flag; symlink flag ignored
reset; touch "$T/flag"; run --ping
check "test flag: /fail + test"        has "$(args)" "problems=test"
reset; ln -s /etc/hostname "$T/flag"; run --ping
check "symlink flag ignored"           has "$(args)" "status=ok"

# 10 reboot info
reset; export FAKE_RBN_RC=1; run --ping
check "reboot required: info only"     has "$(args)" "status=ok info=docker:active,reboot:required"

# 11 config safety
reset; chmod 644 "$T/ping-url"; run --ping
check "644 url file: refused"          [ "$RC" = 1 ] && [ ! -e "$T/curl.args" ]
reset; printf 'http://hc-ping.com/0123abcd-4567-89ab-cdef-0123456789ab\n' >"$T/ping-url"; run --ping
check "http url: refused"              [ "$RC" = 1 ] && [ ! -e "$T/curl.args" ]
reset; printf 'https://evil.example/0123abcd-4567-89ab-cdef-0123456789ab\n' >"$T/ping-url"; run --ping
check "other host: refused"            [ "$RC" = 1 ] && [ ! -e "$T/curl.args" ] && noleak
reset; rm "$T/ping-url"; run --ping
check "missing url: rc 1"              [ "$RC" = 1 ]

# 12 curl failure: rc 1, URL not leaked through curl's stderr
reset; export FAKE_CURL_RC=28; run --ping
check "curl fail: rc 1"                [ "$RC" = 1 ]
check "curl fail: no URL leak"         noleak
check "curl fail: exit code logged"    has "$OUT" "curl exit code 28"

# 13 report / dry-run never use the network
reset; export FAKE_FAILED='x.service a\n'; run --report
check "report: rc 1 on problem"        [ "$RC" = 1 ] && [ ! -e "$T/curl.args" ]
reset; run --dry-run
check "dry-run: rc 0, shows body"      [ "$RC" = 0 ] && has "$OUT" "would send: status=ok" && [ ! -e "$T/curl.args" ]
reset; run --bogus
check "bad argument: rc 2"             [ "$RC" = 2 ]

# 14 dsserver-reboot-needed
mkdir -p "$T/boot" "$T/run"; touch "$T/boot/vmlinuz-6.12.107+deb13-amd64" "$T/boot/vmlinuz-6.12.116+deb13-amd64"
OUT=$(RBN_RUN_DIR=$T/run RBN_BOOT_DIR=$T/boot RBN_UNAME_R=6.12.116+deb13-amd64 "$RBN"); RC=$?
check "rbn: current kernel -> 0"       [ "$RC" = 0 ]
OUT=$(RBN_RUN_DIR=$T/run RBN_BOOT_DIR=$T/boot RBN_UNAME_R=6.12.107+deb13-amd64 "$RBN"); RC=$?
check "rbn: older kernel -> 1"         [ "$RC" = 1 ] && has "$OUT" "newest installed 6.12.116"
touch "$T/boot/vmlinuz-6.12.9+deb13-amd64"
OUT=$(RBN_RUN_DIR=$T/run RBN_BOOT_DIR=$T/boot RBN_UNAME_R=6.12.116+deb13-amd64 "$RBN"); RC=$?
check "rbn: version sort (6.12.9 < 6.12.116)" [ "$RC" = 0 ]
touch "$T/run/reboot-required"; echo libc6 >"$T/run/reboot-required.pkgs"
OUT=$(RBN_RUN_DIR=$T/run RBN_BOOT_DIR=$T/boot RBN_UNAME_R=6.12.116+deb13-amd64 "$RBN"); RC=$?
check "rbn: flag file -> 1 with pkgs"  [ "$RC" = 1 ] && has "$OUT" "libc6"
OUT=$(RBN_RUN_DIR=$T/run RBN_BOOT_DIR=$T/boot "$RBN" --quiet); RC=$?
check "rbn: --quiet prints nothing"    [ -z "$OUT" ] && [ "$RC" = 1 ]
OUT=$("$RBN" --nope 2>&1); RC=$?
check "rbn: bad argument -> 2"         [ "$RC" = 2 ]

# 15 --libs line matching (pattern copied from the script; memfd lines must not count)
PAT=$(grep -oE "grep -qE '[^']+'" "$RBN" | sed "s/^grep -qE '//; s/'\$//")
printf '7f 00 r-xp 0 0:0 1 /usr/lib/x86_64-linux-gnu/libssl.so.3 (deleted)\n' >"$T/m1"
printf '7f 00 r-xp 0 0:0 1 /usr/lib/libfoo.so.1\n7f 00 rw-s 0 0:1 2 /memfd:pipewire-memfd (deleted)\n' >"$T/m2"
grep -qE "$PAT" "$T/m1"; RC=$?; OUT=""
check "libs: deleted .so line matches"  [ "$RC" = 0 ]
grep -qE "$PAT" "$T/m2"; RC=$?
check "libs: .so + memfd on separate lines doesn't" [ "$RC" = 1 ]

echo; echo "$PASS passed, $FAILN failed"
[ "$FAILN" = 0 ]
