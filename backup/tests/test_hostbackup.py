#!/usr/bin/env python3
"""Failure-mode tests of hostbackup against a DISPOSABLE repository (amendment 14). Run as root on dsserver or Beacon
after the host's smb.cred exists:  python3 -I tests/test_hostbackup.py
Uses the host's real share but a separate folder <share>/<host>/test-<time>/, its own password, state, mount point
and lock, so the production repository, its state and its timers are never touched. Deletes the folder at the end.
Scenarios: normal backup/check/drill/prune; interrupted backup (restic killed); NAS share unavailable (no local
fallback); wrong destination marker; incomplete snapshot (exit 3); prune refused while integrity is compromised;
lock held by another job."""
import json, os, secrets, shutil, signal, sqlite3, subprocess, sys, tempfile, time, tomllib
HERE = os.path.dirname(os.path.abspath(__file__)); PROG = os.path.join(HERE, "..", "hostbackup.py")
host = os.uname().nodename.split(".")[0]
real = tomllib.load(open(os.path.join(HERE, "..", "hosts", f"{host}.toml"), "rb"))
T = tempfile.mkdtemp(prefix="hostbackup-test-", dir="/var/tmp"); os.chmod(T, 0o700)
stamp = time.strftime("%Y%m%d-%H%M%S"); tname = f"test-{host}"
SEC = f"{T}/secrets"; os.makedirs(SEC, mode=0o700)
shutil.copy2(os.path.join(real["secrets"], "smb.cred"), f"{SEC}/smb.cred")
open(f"{SEC}/restic.pw", "w").write(secrets.token_urlsafe(32)); os.chmod(f"{SEC}/restic.pw", 0o600)
DATA = f"{T}/data"; os.makedirs(f"{DATA}/files")
for i in range(50): open(f"{DATA}/files/f{i}.txt", "w").write(secrets.token_hex(2000))
db = sqlite3.connect(f"{DATA}/app.db"); db.execute("create table runs(id integer primary key, v text)")
db.executemany("insert into runs(v) values (?)", [(secrets.token_hex(8),) for _ in range(500)]); db.commit(); db.close()
CONF = f"{T}/conf"; os.makedirs(CONF)
def write_conf(share=real["share"], paths=None):
    paths = paths or [DATA]
    open(f"{CONF}/{tname}.toml", "w").write(f'''share = "{share}"
subdir = "{host}/test-{stamp}/restic"
secrets = "{SEC}"
exclude_host = "{host}"
paths = {json.dumps(paths)}
include_axel = true
git_repos = []
retention = {{daily = 14, weekly = 8, monthly = 12}}
subset_rotation = 5
drill_paths = ["{DATA}"]
lock_wait_seconds = 15
[[sqlite]]
name = "testapp"
path = "{DATA}/app.db"
[schedule]
backup = "*-*-* 02:15"
''')
ENV = dict(os.environ, HOSTBACKUP_STATE=f"{T}/state", HOSTBACKUP_RUN=f"{T}/run", HOSTBACKUP_LOCK=f"{T}/run/lock",
           HOSTBACKUP_CONF=CONF, HOSTBACKUP_HOST=tname)
results = []
def run(*a, env=None, timeout=900):
    r = subprocess.run(["python3", "-I", PROG, *a], env=env or ENV, capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout + r.stderr
def state(): return json.load(open(f"{T}/state/state.json"))
def t(name, cond, detail=""):
    results.append(cond); print(("pass  " if cond else "FAIL  ") + name + (f"  [{detail}]" if detail and not cond else ""), flush=True)
def snapshot_count():
    rc, out = run("snapshots"); return out.count(tname)

try:
    write_conf()
    rc, out = run("init"); t("init disposable repository", rc == 0, out[-300:])
    rc, out = run("backup"); t("backup ok (incl. SQLite copy + manifest, structure check)", rc == 0 and "snapshot" in out, out[-400:])
    rc, out = run("check"); t("rotating subset check ok -> integrity ok", rc == 0 and state()["integrity"] == "ok", out[-300:])
    rc, out = run("drill"); t("restore drill ok (metadata, DB vs manifest)", rc == 0 and "database testapp" in out, out[-400:])
    n0 = snapshot_count()

    # interrupted backup: kill restic hard mid-run
    write_conf(paths=[DATA, "/usr/share"])
    p = subprocess.Popen(["python3", "-I", PROG, "backup"], env=ENV, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    killed = False
    for _ in range(120):
        time.sleep(1)
        r = subprocess.run(["pgrep", "-f", f"restic --retry-lock 15m backup"], capture_output=True, text=True)
        pids = [x for x in r.stdout.split() if x]
        if pids:
            time.sleep(4); [os.kill(int(x), signal.SIGKILL) for x in pids]; killed = True; break
    out = p.communicate(timeout=600)[0]
    t("interrupted backup is reported as FAILED", killed and p.returncode != 0 and "FAILED" in out, out[-300:])
    t("integrity becomes 'unknown' after an interrupted write", state()["integrity"] == "unknown")
    rc, out = run("prune"); t("prune refused while integrity unknown (nothing deleted)", rc != 0 and "prune refused" in out and snapshot_count() == n0, out[-300:])
    write_conf()
    rc, out = run("check"); t("check after the interruption passes (stale lock of a dead process is not an error)", rc == 0, out[-400:])

    # incomplete snapshot (restic exit 3) via a stub that returns 3 for `backup`
    stub = f"{T}/restic-stub"
    open(stub, "w").write('#!/bin/sh\nfor a in "$@"; do [ "$a" = backup ] && { echo "stub: 1 file could not be read" >&2; exit 3; }; done\nexec /usr/bin/restic "$@"\n')
    os.chmod(stub, 0o700)
    rc, out = run("backup", env=dict(ENV, HOSTBACKUP_RESTIC=stub)); t("exit 3 (incomplete snapshot) is a failure", rc != 0 and "INCOMPLETE" in out, out[-300:])

    # compromised integrity blocks pruning
    s = state(); s["integrity"] = "compromised"; json.dump(s, open(f"{T}/state/state.json", "w"))
    rc, out = run("prune"); t("prune refused while integrity compromised (nothing deleted)", rc != 0 and "compromised" in out and snapshot_count() == n0, out[-300:])

    # wrong destination marker
    did = open(f"{SEC}/destination-id").read(); open(f"{SEC}/destination-id", "w").write("00000000-0000-0000-0000-000000000000\n")
    rc, out = run("backup"); t("wrong destination marker -> refused", rc != 0 and "marker mismatch" in out, out[-300:])
    open(f"{SEC}/destination-id", "w").write(did)

    # NAS share unavailable -> no local fallback
    write_conf(share="hostbackup-no-such-share")
    rc, out = run("backup"); mnt = f"{T}/run/mnt"
    t("unavailable share -> FAILED, nothing written locally", rc != 0 and "mount" in out and (not os.path.exists(mnt) or not os.listdir(mnt)), out[-300:])
    write_conf()

    # lock held by another job
    os.makedirs(f"{T}/run", exist_ok=True); import fcntl; lf = open(f"{T}/run/lock", "w"); fcntl.flock(lf, fcntl.LOCK_EX)
    rc, out = run("check"); t("job waits for the lock and fails after lock_wait_seconds", rc != 0 and "held the lock" in out, out[-300:])
    fcntl.flock(lf, fcntl.LOCK_UN); lf.close()

    # recovery path: data check restores 'ok', prune then allowed
    rc, out = run("fullcheck"); t("full check ok -> integrity ok", rc == 0 and state()["integrity"] == "ok", out[-300:])
    rc, out = run("prune"); t("prune allowed after a passing data check", rc == 0, out[-300:])
finally:
    # remove the disposable repository folder on the share, then the local test directory
    sys.path.insert(0, os.path.join(HERE, "..")); os.environ.update(ENV)
    import importlib; hb = importlib.import_module("hostbackup")
    try:
        c = hb.load_conf(tname); c["share"] = real["share"]
        hb.mount(c); shutil.rmtree(f"{hb.MNT}/{host}/test-{stamp}", ignore_errors=True)
        gone = not os.path.exists(f"{hb.MNT}/{host}/test-{stamp}"); hb.umount()
        print(("ok    " if gone else "WARN  ") + f"disposable folder {real['share']}/{host}/test-{stamp} removed")
    except Exception as e:
        print(f"WARN  cleanup: {e}")
    shutil.rmtree(T, ignore_errors=True)
print(f"\n{sum(results)} passed, {len(results) - sum(results)} failed")
sys.exit(0 if results and all(results) else 1)
