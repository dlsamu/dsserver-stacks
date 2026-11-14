#!/bin/bash
# Executes docs/recovery.md section 1 AS WRITTEN (RESTORE, VERIFY, CLEANUP blocks), as root, and times it.
# Only the interactive lines are not executed: `sudo -i` (we already are root) and the two `cat > /root/rb/...`
# credential lines - the caller has put the same secrets into /root/rb/smb.cred and /root/rb/restic.pw (0600).
# Usage: SHARE=... REPO=... recovery-test.sh /path/to/recovery.md
set -uo pipefail
DOC=${1:?recovery.md}
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
[ -s /root/rb/smb.cred ] && [ -s /root/rb/restic.pw ] || { echo "credentials not prepared in /root/rb"; exit 1; }
block() { awk -v b="<!-- $1-BEGIN -->" -v e="<!-- $1-END -->" '$0==b{f=1;next} $0==e{f=0} f' "$DOC" | sed '/^```/d'; }
run_block() {
    local name=$1 script
    script=$(block "$name" | grep -vE '^sudo -i( |$)' | grep -vE '^cat > /root/rb/(smb\.cred|restic\.pw)')
    echo "--- $name block ($(wc -l <<<"$script") lines), executed as written:"; sed 's/^/    /' <<<"$script"
    local s=$(date +%s.%N)
    bash -e -o pipefail -c "$script"; local rc=$?
    printf -- '--- %s: rc=%s, %s s\n' "$name" "$rc" "$(awk -v a="$s" -v b="$(date +%s.%N)" 'BEGIN{printf "%.1f", b-a}')"
    return $rc
}
export SHARE REPO
rc=0
run_block RESTORE || rc=1
if [ $rc = 0 ]; then
    n=$(find /root/rb/restore -type f | wc -l); sz=$(du -sm /root/rb/restore | cut -f1)
    echo "restored: $n files, $sz MiB; top level: $(ls /root/rb/restore | tr '\n' ' ')"
    run_block VERIFY || rc=1
fi
run_block CLEANUP || rc=1
[ ! -e /root/rb ] && ! findmnt /mnt/rb >/dev/null && echo "ok    cleaned up (credentials shredded, restore removed, unmounted)" || { echo "FAIL  cleanup incomplete"; rc=1; }
[ $rc = 0 ] && echo "RECOVERY TEST PASSED" || echo "RECOVERY TEST FAILED"
exit $rc
