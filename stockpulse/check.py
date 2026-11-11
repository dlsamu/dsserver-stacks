#!/usr/bin/python3 -I
"""StockPulse application check (host side, root, stdlib only). Run by `15-stockpulse.sh check`
(stockpulse-check.timer, every 15 min). Exit 1 = problem -> stockpulse-check.service is "failed"
-> Beszel's SystemdFailed alert for dsserver -> ntfy. The next passing run clears it.

  check.py --data DIR --reports DIR [--state DIR] [--now ISO] [--uid N]

Checks
  database   history.db present, SQLite quick_check ok, expected tables, owned by the app uid
  storage    >= 2 GiB and >= 5 % free on the data filesystem; data/report dirs owned by the app uid
  reports    the 5 latest reports exist as regular files
  freshness  only for screeners whose timer is enabled (state/timers-enabled-at): each latest report must
             be newer than the most recent weekday slot (08/09/10:00) that is older than the grace period
             and later than the enable time (no false alarm right after enabling)
  backup     if the backup timer is enabled (state/backup-enabled): newest backup younger than 26 h
  test       state/fail-test exists -> deliberate failure (alert pipeline test)
"""
import argparse, glob, os, shutil, sqlite3, stat, sys
from datetime import datetime, timedelta

LATEST = {"us": ["report.html"], "intl": ["report_intl_nordic.html", "report_intl_european.html", "report_intl_pacific.html"],
          "ath": ["report_ath.html"]}
SLOT_HOUR = {"us": 8, "intl": 9, "ath": 10}
GRACE = timedelta(minutes=90)          # a run normally finishes within ~10 minutes
FAILS = []


def ok(m): print("ok    " + m)
def bad(m): print("FAIL  " + m); FAILS.append(m)


def last_slot(now: datetime, hour: int) -> datetime:
    """Most recent weekday hour:00 whose grace period has passed."""
    d = now.replace(hour=hour, minute=0, second=0, microsecond=0)
    while d.weekday() >= 5 or d + GRACE > now:
        d -= timedelta(days=1)
    return d


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", required=True); p.add_argument("--reports", required=True)
    p.add_argument("--state", default="/var/lib/stockpulse"); p.add_argument("--now")
    p.add_argument("--uid", type=int, default=10010)
    a = p.parse_args()
    now = datetime.fromisoformat(a.now) if a.now else datetime.now()

    if os.path.exists(os.path.join(a.state, "fail-test")):
        bad("deliberate test failure (state/fail-test present)")

    db = os.path.join(a.data, "history.db")
    try:
        st = os.stat(db)
        c = sqlite3.connect(f"file:{db}?mode=ro", uri=True, timeout=30)
        r = c.execute("pragma quick_check").fetchone()[0]
        tables = {t for (t,) in c.execute("select name from sqlite_master where type='table'")}
        runs, last = c.execute("select count(*), max(run_date) from runs").fetchone()
        c.close()
        (ok if r == "ok" else bad)(f"database quick_check: {r}")
        missing = {"runs", "qualifiers", "ath_weeks"} - tables
        (bad if missing else ok)(f"database tables{' missing: ' + ', '.join(sorted(missing)) if missing else ' present'}; {runs} runs, latest {last}")
        (ok if st.st_uid == a.uid else bad)(f"history.db owner uid {st.st_uid}")
    except (OSError, sqlite3.Error) as e:
        bad(f"database: {e}")

    try:
        u = shutil.disk_usage(a.data)
        free_gib, free_pct = u.free / 2**30, 100 * u.free / u.total
        (ok if free_gib >= 2 and free_pct >= 5 else bad)(f"storage: {free_gib:.1f} GiB ({free_pct:.0f} %) free")
    except OSError as e:
        bad(f"storage: {e}")
    for d in (a.data, a.reports, os.path.join(a.reports, "reports")):
        try:
            (ok if os.stat(d).st_uid == a.uid else bad)(f"{d} owned by uid {os.stat(d).st_uid}")
        except OSError as e:
            bad(f"{d}: {e.strerror}")

    try:
        enabled_at = datetime.fromtimestamp(os.stat(os.path.join(a.state, "timers-enabled-at")).st_mtime)
    except OSError:
        enabled_at = None
    for job, files in LATEST.items():
        slot = last_slot(now, SLOT_HOUR[job])
        for f in files:
            try:
                st = os.lstat(os.path.join(a.reports, f))
            except OSError:
                bad(f"report {f} missing"); continue
            if not stat.S_ISREG(st.st_mode):
                bad(f"report {f} is not a regular file"); continue
            mtime = datetime.fromtimestamp(st.st_mtime)
            if enabled_at is None or slot < enabled_at:
                ok(f"report {f} present ({mtime:%Y-%m-%d %H:%M}); freshness not required yet")
            else:
                (ok if mtime >= slot else bad)(f"report {f} from {mtime:%Y-%m-%d %H:%M}, expected run {slot:%a %Y-%m-%d %H:%M}"
                                               + ("" if mtime >= slot else " -> STALE"))

    if os.path.exists(os.path.join(a.state, "backup-enabled")):
        b = sorted(glob.glob(os.path.join(a.data, "backups", "history-*.db")), key=os.path.getmtime)
        if not b:
            bad("backup: none yet")
        else:
            age = now - datetime.fromtimestamp(os.path.getmtime(b[-1]))
            (ok if age <= timedelta(hours=26) else bad)(f"backup: newest {os.path.basename(b[-1])}, {age.total_seconds()/3600:.1f} h old")

    print("STOCKPULSE CHECK " + ("PASSED" if not FAILS else f"FAILED ({len(FAILS)})"))
    sys.exit(1 if FAILS else 0)


main()
