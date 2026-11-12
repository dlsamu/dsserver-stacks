#!/bin/bash
# Unprivileged tests for stockpulse/check.py (the 15-minute application check).
# Run as daniel:  bash stockpulse/tests/test-check.sh
# Builds throwaway data/report/state directories in a temp dir: no access to the real data, no network.
set -uo pipefail
HERE=$(cd "$(dirname "$0")/.." && pwd)
CHECK=$HERE/check.py
[ "$(id -u)" != 0 ] || { echo "run as a normal user"; exit 2; }
T=$(mktemp -d); trap 'rm -rf -- "$T"' EXIT
ME=$(id -u); PASS=0; FAILN=0
REPORTS="report.html report_intl_nordic.html report_intl_european.html report_intl_pacific.html report_ath.html"

reset() {
    rm -rf "$T/d" "$T/r" "$T/s"; mkdir -p "$T/d/backups" "$T/r/reports" "$T/s"
    python3 -I -c 'import sqlite3, sys
c = sqlite3.connect(sys.argv[1])
c.executescript("create table runs(run_date text); create table qualifiers(x); create table ath_weeks(x); insert into runs values (\"2026-11-10\");")
c.commit()' "$T/d/history.db"
    for f in $REPORTS; do echo "<html>" >"$T/r/$f"; touch -d "$1" "$T/r/$f"; done
}
run() { OUT=$(python3 -I "$CHECK" --data "$T/d" --reports "$T/r" --state "$T/s" --uid "$ME" --now "$NOW" 2>&1); RC=$?; }
check() { local name=$1; shift
    if "$@"; then PASS=$((PASS+1)); echo "PASS  $name"; else FAILN=$((FAILN+1)); echo "FAIL  $name"; echo "      rc=$RC"; sed 's/^/      | /' <<<"$OUT"; fi; }
has() { [[ $OUT == *"$1"* ]]; }
passed() { [ "$RC" = 0 ] && has "STOCKPULSE CHECK PASSED"; }
failed() { [ "$RC" = 1 ] && has "$1"; }

# Wednesday 2026-11-11 12:00: today's slots 08/09/10:00 + 90 min grace have all passed.
NOW=2026-11-11T12:00:00

reset "2026-11-11 10:05"; run;                                    check "healthy"                         passed
reset "2026-11-11 10:05"; touch "$T/s/fail-test"; run;            check "fail-test flag"                  failed "deliberate test failure"
reset "2026-11-11 10:05"; rm "$T/d/history.db"; run;              check "database missing"                failed "FAIL  database:"
reset "2026-11-11 10:05"; head -c 4096 /dev/urandom >"$T/d/history.db"; run
                                                                  check "database corrupt"                failed "FAIL  database"
reset "2026-11-11 10:05"; python3 -I -c 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("drop table ath_weeks"); c.commit()' "$T/d/history.db"; run
                                                                  check "table missing"                   failed "missing: ath_weeks"
reset "2026-11-11 10:05"; python3 -I "$CHECK" --data "$T/d" --reports "$T/r" --state "$T/s" --uid 10010 --now "$NOW" >/dev/null 2>&1; RC=$?; OUT="(wrong uid run)"
                                                                  check "wrong owner uid"                 [ "$RC" = 1 ]
reset "2026-11-11 10:05"; rm "$T/r/report_ath.html"; run;         check "report missing"                  failed "report report_ath.html missing"
reset "2026-11-11 10:05"; rm "$T/r/report.html"; ln -s "$T/d/history.db" "$T/r/report.html"; run
                                                                  check "report is a symlink"             failed "not a regular file"
reset "2026-11-11 10:05"; rmdir "$T/r/reports"; run;              check "archive dir missing"             failed "/r/reports: No such file"

# Freshness: only after timers-enable, and only for slots after the enable time.
reset "2026-11-10 10:05"; run;                                    check "old reports, timers off: ok"     passed
reset "2026-11-10 10:05"; touch -d "2026-11-10 12:00" "$T/s/timers-enabled-at"; run
                                                                  check "stale after enable: FAIL"        failed "STALE"
reset "2026-11-10 10:05"; touch -d "2026-11-11 11:00" "$T/s/timers-enabled-at"; run
                                                                  check "enabled after today's slots: ok" passed
reset "2026-11-11 08:05"; touch -d "2026-11-01" "$T/s/timers-enabled-at"; touch -d "2026-11-11 10:05" "$T/r/report_ath.html"; run
                                                                  check "intl not run today: STALE"       failed "report_intl_nordic.html from 2026-11-11 08:05, expected run Wed 2026-11-11 09:00 -> STALE"
reset "2026-11-11 10:05"; touch -d "2026-11-01" "$T/s/timers-enabled-at"; NOW=2026-11-11T09:30:00; run
                                                                  check "within grace: not stale yet"     passed
reset "2026-11-13 10:05"; touch -d "2026-11-01" "$T/s/timers-enabled-at"; NOW=2026-11-16T09:00:00; run
                                                                  check "Monday 09:00: Friday counts"     passed
NOW=2026-11-11T12:00:00

# Per-screener enable (15 timer-enable <job>): only that screener's reports must be fresh.
reset "2026-11-10 10:05"; touch -d "2026-11-01" "$T/s/timer-us-enabled-at"; touch -d "2026-11-11 08:20" "$T/r/report.html"; run
                                                                  check "only us enabled, us fresh: ok"   passed
has "report_intl_nordic.html present (2026-11-10 10:05); freshness not required yet" && has "report_ath.html present" \
                                                               && check "intl/ath not checked" true || check "intl/ath not checked" false
reset "2026-11-10 10:05"; touch -d "2026-11-01" "$T/s/timer-us-enabled-at"; run
                                                                  check "only us enabled, us stale: FAIL" failed "report.html from 2026-11-10 10:05, expected run Wed 2026-11-11 08:00 -> STALE"
[ "$(grep -c STALE <<<"$OUT")" = 1 ]; check "exactly one stale report (us)" [ $? = 0 ]
reset "2026-11-10 10:05"; touch -d "2026-11-11 08:30" "$T/s/timer-us-enabled-at"; run
                                                                  check "us enabled after its slot: ok"   passed

# Backup age (only once backup-enable has run).
reset "2026-11-11 10:05"; touch "$T/s/backup-enabled"; run;       check "backup enabled, none yet: FAIL"  failed "backup: none yet"
reset "2026-11-11 10:05"; touch "$T/s/backup-enabled"; touch -d "2026-11-11 03:15" "$T/d/backups/history-20261111-031500.db"; run
                                                                  check "backup 9 h old: ok"              passed
reset "2026-11-11 10:05"; touch "$T/s/backup-enabled"; touch -d "2026-11-10 03:15" "$T/d/backups/history-20261110-031500.db"; run
                                                                  check "backup 33 h old: FAIL"           failed "32.8 h old"

echo; echo "$PASS passed, $FAILN failed"; [ "$FAILN" = 0 ]
