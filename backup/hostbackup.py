#!/usr/bin/env python3
"""hostbackup: off-device backups of one host to its own restic repository on dsnas (SMB3). Design and rules:
/srv/stacks/backup/README.md (proposal B1 + owner amendments 2026-11-14). Runs as root; same program on every host,
configured by backup/hosts/<hostname>.toml.

Jobs (each a separate systemd unit + timer + Healthchecks check; all repository jobs serialized by one flock):
  backup     consistent SQLite copies + manifests (staging), system manifest, restic backup, restic check (structure)
  check      restic check --read-data-subset=K/N, K = deterministic rotation (ISO week); whole repo every N weeks
  fullcheck  restic check --read-data
  prune      forget + prune with the retention policy; REFUSED unless integrity is "ok" and a data check passed recently
  drill      restore the latest snapshot's drill paths to a scratch dir and verify contents, metadata, databases
             (against their manifests), git, enabled units; StockPulse DB opened by its own image, isolated
Other commands: preflight | init | status | snapshots | mount-test | test <scenario> (disposable test repository)

Safety rules enforced here:
  - every repository operation first verifies: mounted CIFS from the expected //server/share, the destination marker
    (written at init) and the repository id; otherwise abort. There is no local fallback path.
  - restic exit 3 (incomplete snapshot) and any non-zero exit are failures.
  - never `restic unlock`, never `restic repair`; lock contention waits (--retry-lock) and then fails.
  - integrity state: unknown (initial / after an interrupted write) -> ok (after a passing data check) ->
    compromised (any failing check). Prune runs only when "ok" and the last data check passed within 9 days."""
import datetime, fcntl, hashlib, json, os, shutil, sqlite3, subprocess, sys, time, tomllib, urllib.request, uuid

HERE = os.path.dirname(os.path.abspath(__file__))
# Overridable ONLY for the disposable test repositories (tests/test_hostbackup.py); production uses the defaults.
STATE_DIR = os.environ.get("HOSTBACKUP_STATE", "/var/lib/hostbackup")
STAGING = f"{STATE_DIR}/staging"
DRILL_DIR = f"{STATE_DIR}/drill"
STATE = f"{STATE_DIR}/state.json"
METRICS = f"{STATE_DIR}/metrics.jsonl"
RUN_DIR = os.environ.get("HOSTBACKUP_RUN", "/run/hostbackup")
MNT = f"{RUN_DIR}/mnt"
LOCK = os.environ.get("HOSTBACKUP_LOCK", "/run/hostbackup/lock")
CONF_DIR = os.environ.get("HOSTBACKUP_CONF", os.path.join(HERE, "hosts"))
RESTIC = os.environ.get("HOSTBACKUP_RESTIC", "/usr/bin/restic")   # tests may point this at a stub
NAS = "192.168.68.112"

def now(): return datetime.datetime.now().astimezone()
def log(m): print(m, flush=True)
class Fail(Exception):
    def __init__(self, msg, rc=None): super().__init__(msg); self.rc = rc

# ------------------------------------------------------------------ configuration
def load_conf(host=None):
    host = host or os.uname().nodename.split(".")[0]
    with open(f"{CONF_DIR}/{host}.toml", "rb") as f: c = tomllib.load(f)
    c["host"] = host
    c["repo"] = f"{MNT}/{c['subdir']}".rstrip("/")
    c["excl_host"] = c.get("exclude_host", host)
    return c

def secret(c, name): return os.path.join(c["secrets"], name)

def restic_env(c):
    e = {"PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "RESTIC_REPOSITORY": c["repo"],
         "RESTIC_PASSWORD_FILE": secret(c, "restic.pw"), "RESTIC_CACHE_DIR": f"{STATE_DIR}/cache",
         "RESTIC_PROGRESS_FPS": "0.016"}
    return e

def restic(c, *args, check=True, capture=False, timeout=None):
    """Run restic against the VERIFIED repository. Returns CompletedProcess. Non-zero exit -> Fail (if check)."""
    verify_destination(c)
    cmd = [RESTIC, "--retry-lock", "15m", *args]
    r = subprocess.run(cmd, env=restic_env(c), capture_output=capture, text=True, timeout=timeout)
    if check and r.returncode != 0:
        raise Fail(f"restic {args[0]} exit {r.returncode}" + (" (incomplete snapshot: some files could not be read)" if r.returncode == 3 else "")
                   + (f": {(r.stderr or '').strip()[-300:]}" if capture else ""), rc=r.returncode)
    return r

# ------------------------------------------------------------------ mount + identity
def mounted_source():
    r = subprocess.run(["findmnt", "-n", "-o", "SOURCE,FSTYPE", "--mountpoint", MNT], capture_output=True, text=True)
    return r.stdout.split() if r.returncode == 0 else None

def mount(c):
    want = f"//{NAS}/{c['share']}"
    cur = mounted_source()
    if cur:
        if cur != [want, "cifs"]: raise Fail(f"{MNT} has {cur}, expected {want} cifs: refusing")
        return
    os.makedirs(MNT, mode=0o700, exist_ok=True)
    if os.listdir(MNT): raise Fail(f"{MNT} is not empty while unmounted: refusing (never write locally)")
    opts = ("vers=3.1.1,seal,credentials=" + secret(c, "smb.cred") + ",uid=0,gid=0,file_mode=0600,dir_mode=0700,"
            "soft,echo_interval=10,actimeo=1,nosharesock")
    r = subprocess.run(["mount", "-t", "cifs", want, MNT, "-o", opts], capture_output=True, text=True, timeout=60)
    if r.returncode != 0: raise Fail(f"mount {want} failed: {r.stderr.strip()[:200]}")
    if mounted_source() != [want, "cifs"]: raise Fail("mount verification failed")

def umount():
    if mounted_source():
        subprocess.run(["umount", MNT], timeout=60)
        if mounted_source(): subprocess.run(["umount", "-l", MNT], timeout=30)

def verify_destination(c):
    """Mounted from the expected share, marker matches, repository id matches. Raises Fail otherwise."""
    want = f"//{NAS}/{c['share']}"
    if mounted_source() != [want, "cifs"] or not os.path.ismount(MNT):
        raise Fail(f"destination not mounted ({MNT} must be {want}): refusing")
    if not c["repo"].startswith(MNT + "/"): raise Fail("repository path outside the mount: refusing")
    mfile = os.path.join(os.path.dirname(c["repo"]), "DESTINATION.json")
    exp_dest = open(secret(c, "destination-id")).read().strip() if os.path.exists(secret(c, "destination-id")) else None
    if exp_dest is None: return  # only before init
    try: m = json.load(open(mfile))
    except Exception: raise Fail(f"destination marker {mfile} missing/unreadable: wrong share or folder?")
    if m.get("id") != exp_dest or m.get("host") != c["host"]: raise Fail(f"destination marker mismatch ({m.get('host')}/{str(m.get('id'))[:8]})")
    exp_repo = open(secret(c, "repo-id")).read().strip() if os.path.exists(secret(c, "repo-id")) else None
    if exp_repo:
        got = repo_id_from_files(c)
        if got != exp_repo: raise Fail(f"repository id mismatch (got {str(got)[:12]}, expected {exp_repo[:12]})")

def repo_id_from_files(c):
    # `restic cat config` without verify_destination recursion
    r = subprocess.run([RESTIC, "--no-lock", "cat", "config"], env=restic_env(c), capture_output=True, text=True, timeout=120)
    if r.returncode != 0: raise Fail(f"cannot read repository config: {r.stderr.strip()[-200:]}")
    return json.loads(r.stdout)["id"]

# ------------------------------------------------------------------ state, metrics, healthchecks
def load_state():
    try: return json.load(open(STATE))
    except Exception: return {"integrity": "unknown", "jobs": {}}

def save_state(s):
    os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    tmp = STATE + ".tmp"; json.dump(s, open(tmp, "w"), indent=1); os.replace(tmp, STATE)

def metric(**kw):
    kw["time"] = now().isoformat(timespec="seconds")
    with open(METRICS, "a") as f: f.write(json.dumps(kw) + "\n")

def hc(c, job, kind, body=""):
    try: urls = json.load(open(secret(c, "healthchecks.json")))
    except Exception: return
    u = urls.get(job)
    if not u: return
    if kind != "success": u = f"{u}/{kind}"
    try: urllib.request.urlopen(urllib.request.Request(u, data=body[-9000:].encode(), method="POST"), timeout=15).read()
    except Exception as e: log(f"warn  Healthchecks ping failed: {e}")

# ------------------------------------------------------------------ staging: consistent copies + manifests
def sqlite_copy(name, src, dst_dir):
    os.makedirs(dst_dir, mode=0o700, exist_ok=True)
    dst = os.path.join(dst_dir, f"{name}.db"); tmp = dst + ".tmp"
    if os.path.exists(tmp): os.remove(tmp)
    s = sqlite3.connect(f"file:{src}?mode=ro", uri=True, timeout=60)
    d = sqlite3.connect(tmp)
    s.backup(d); s.close()
    integ = d.execute("pragma integrity_check").fetchone()[0]
    tables = [r[0] for r in d.execute("select name from sqlite_master where type='table' and name not like 'sqlite_%' order by name")]
    counts = {t: d.execute(f'select count(*) from "{t}"').fetchone()[0] for t in tables}
    schema = hashlib.sha256("\n".join(r[0] or "" for r in d.execute("select sql from sqlite_master order by type, name")).encode()).hexdigest()
    d.close()
    if integ != "ok": raise Fail(f"{name}: integrity_check of the fresh copy: {integ}")
    os.replace(tmp, dst); os.chmod(dst, 0o600)
    h = hashlib.sha256(open(dst, "rb").read()).hexdigest()
    man = {"name": name, "source": src, "copy": dst, "sha256": h, "size": os.path.getsize(dst), "integrity": integ,
           "tables": counts, "schema_sha256": schema, "created": now().isoformat(timespec="seconds")}
    json.dump(man, open(os.path.join(dst_dir, f"{name}.manifest.json"), "w"), indent=1)
    return man

def stage(c):
    if os.path.exists(STAGING): shutil.rmtree(STAGING)
    os.makedirs(STAGING, mode=0o700)
    mans = [sqlite_copy(d["name"], d["path"], f"{STAGING}/sqlite") for d in c.get("sqlite", [])]
    sysman = {"host": c["host"], "created": now().isoformat(timespec="seconds"),
              "enabled_units": sorted(subprocess.run(["systemctl", "list-unit-files", "--state=enabled", "--no-legend", "--plain"],
                                      capture_output=True, text=True).stdout.split()[0::2]),
              "dpkg_selections_sha256": None, "git": {}, "docker_images": []}
    sel = subprocess.run(["dpkg", "--get-selections"], capture_output=True, text=True).stdout
    open(f"{STAGING}/dpkg-selections.txt", "w").write(sel); sysman["dpkg_selections_sha256"] = hashlib.sha256(sel.encode()).hexdigest()
    for g in c.get("git_repos", []):
        r = subprocess.run(["git", "-C", g, "rev-parse", "HEAD"], capture_output=True, text=True, env={"PATH": "/usr/bin:/bin", "HOME": "/root", "GIT_CONFIG_GLOBAL": "/dev/null"})
        sysman["git"][g] = r.stdout.strip() if r.returncode == 0 else None
    if shutil.which("docker"):
        r = subprocess.run(["docker", "image", "ls", "--format", "{{.Repository}}:{{.Tag}} {{.ID}}"], capture_output=True, text=True)
        sysman["docker_images"] = sorted(r.stdout.split("\n")) if r.returncode == 0 else []
    json.dump(sysman, open(f"{STAGING}/system-manifest.json", "w"), indent=1)
    return mans

# ------------------------------------------------------------------ jobs
def excludes(c):
    files = [f"{HERE}/excludes/common.txt", f"{HERE}/excludes/{c['excl_host']}.txt"]
    if not c.get("include_axel"): files.append(f"{HERE}/excludes/no-axel.txt")
    return [a for f in files if os.path.exists(f) for a in ("--exclude-file", f)]

def job_backup(c, st):
    t0 = time.time(); mans = stage(c)
    log(f"ok    staging: {len(mans)} database copies verified, system manifest written")
    s = st
    r = restic(c, "backup", "--one-file-system", "--tag", "nightly", "--host", c["host"], *excludes(c), "--json",
               *c["paths"], STAGING, check=False, capture=True)
    summ = next((json.loads(l) for l in r.stdout.splitlines()[::-1] if '"message_type":"summary"' in l), {})
    if r.returncode != 0:
        if r.returncode != 3: s["integrity"] = "unknown"   # an interrupted write may leave unreferenced data
        raise Fail(f"restic backup exit {r.returncode}" + (" (INCOMPLETE snapshot: some files could not be read)" if r.returncode == 3 else "")
                   + f": {r.stderr.strip()[-400:]}")
    dt = time.time() - t0
    log(f"ok    snapshot {summ.get('snapshot_id','?')[:8]}: {summ.get('total_files_processed')} files, "
        f"{summ.get('total_bytes_processed',0)/2**20:.0f} MiB scanned, {summ.get('data_added',0)/2**20:.1f} MiB added, {dt:.0f} s")
    run_check(c, s, [])   # structure only
    log("ok    restic check (structure) passed")
    stats = json.loads(restic(c, "stats", "--mode", "raw-data", "--json", capture=True).stdout)
    df = shutil.disk_usage(MNT)
    metric(job="backup", seconds=round(dt), snapshot=summ.get("snapshot_id"), files=summ.get("total_files_processed"),
           bytes_scanned=summ.get("total_bytes_processed"), bytes_added=summ.get("data_added"),
           repo_raw_bytes=stats.get("total_size"), share_free_bytes=df.free, share_total_bytes=df.total)
    s["last_backup"] = now().isoformat(timespec="seconds")

def run_check(c, st, extra):
    """restic check; exit 1 = the repository has errors -> 'compromised'; any other failure (lock, mount, timeout)
    -> 'unknown' unless already compromised. Both stop pruning."""
    try:
        restic(c, "check", *extra, capture=True)
    except Fail as e:
        if e.rc == 1: st["integrity"] = "compromised"
        elif st.get("integrity") != "compromised": st["integrity"] = "unknown"
        raise

def subset_k(n):
    return (datetime.date.today().isocalendar().week % n) + 1

def job_check(c, st, full=False):
    t0 = time.time()
    n = c.get("subset_rotation", 5)
    arg = "--read-data" if full else f"--read-data-subset={subset_k(n)}/{n}"
    run_check(c, st, [arg])
    st["integrity"] = "ok"
    st["last_data_check"] = now().isoformat(timespec="seconds")
    st.setdefault("subsets_passed", {})[str(subset_k(n))] = st["last_data_check"]
    if full: st["last_full_check"] = st["last_data_check"]
    metric(job="fullcheck" if full else "check", seconds=round(time.time() - t0), arg=arg)
    log(f"ok    restic check {arg} passed ({time.time()-t0:.0f} s)")

def job_prune(c, st):
    if st.get("integrity") != "ok":
        raise Fail(f"prune refused: repository integrity is '{st.get('integrity')}' (needs a passing data check; nothing deleted)")
    last = st.get("last_data_check")
    if not last or (now() - datetime.datetime.fromisoformat(last)).days > 9:
        raise Fail(f"prune refused: last passing data check {last} is older than 9 days (nothing deleted)")
    run_check(c, st, [])
    t0 = time.time(); k = c["retention"]
    restic(c, "forget", "--host", c["host"], "--keep-daily", str(k["daily"]), "--keep-weekly", str(k["weekly"]),
           "--keep-monthly", str(k["monthly"]), "--prune")
    st["integrity"] = "unknown"   # prune rewrote the repository: the next data check must confirm it
    run_check(c, st, [])
    stats = json.loads(restic(c, "stats", "--mode", "raw-data", "--json", capture=True).stdout)
    metric(job="prune", seconds=round(time.time() - t0), repo_raw_bytes=stats.get("total_size"))
    log(f"ok    forget+prune done, structure check passed ({time.time()-t0:.0f} s); integrity 'unknown' until the next data check")

def job_drill(c, st):
    t0 = time.time()
    snaps = json.loads(restic(c, "snapshots", "--host", c["host"], "--json", capture=True).stdout)
    if not snaps: raise Fail("no snapshots")
    snap = sorted(snaps, key=lambda x: x["time"])[-1]
    target = f"{DRILL_DIR}/{snap['short_id']}"
    if os.path.exists(DRILL_DIR): shutil.rmtree(DRILL_DIR)
    os.makedirs(target, mode=0o700)
    try:
        inc = [a for p in c["drill_paths"] + [STAGING] for a in ("--include", p)]
        restic(c, "restore", snap["id"], "--target", target, "--verify", *inc)
        t_restore = time.time() - t0
        log(f"ok    restored + verified snapshot {snap['short_id']} ({snap['time'][:16]}) paths {c['drill_paths']} in {t_restore:.0f} s")
        # 1) metadata of every restored file vs. the snapshot listing
        bad = n = 0
        for line in restic(c, "ls", "--json", "--recursive", snap["id"], *c["drill_paths"], STAGING, capture=True).stdout.splitlines():
            e = json.loads(line)
            if e.get("struct_type") != "node" or e.get("type") not in ("file", "dir"): continue
            p = target + e["path"]
            try: s = os.lstat(p)
            except FileNotFoundError: bad += 1; continue
            n += 1
            # restic encodes modes Go-style (type/setuid bits differ from Unix); the low 9 permission bits are comparable
            if (s.st_uid, s.st_gid, s.st_mode & 0o777) != (e["uid"], e["gid"], e["mode"] & 0o777) or (e["type"] == "file" and s.st_size != e["size"]):
                bad += 1
                if bad <= 5: log(f"FAIL  metadata {e['path']}")
        if bad: raise Fail(f"{bad} restored entries differ in owner/permissions/size from the snapshot")
        log(f"ok    {n} restored files/dirs: owner, group, permissions, size identical to the snapshot")
        # 2) databases vs. their manifests (on the restored copies only)
        for mf in sorted(os.listdir(f"{target}{STAGING}/sqlite")) if os.path.isdir(f"{target}{STAGING}/sqlite") else []:
            if not mf.endswith(".manifest.json"): continue
            m = json.load(open(f"{target}{STAGING}/sqlite/{mf}")); db = f"{target}{STAGING}/sqlite/{m['name']}.db"
            if hashlib.sha256(open(db, "rb").read()).hexdigest() != m["sha256"]: raise Fail(f"{m['name']}: sha256 differs from manifest")
            con = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
            if con.execute("pragma integrity_check").fetchone()[0] != "ok": raise Fail(f"{m['name']}: integrity_check failed")
            counts = {t: con.execute(f'select count(*) from "{t}"').fetchone()[0] for t in m["tables"]}
            con.close()
            if counts != m["tables"]: raise Fail(f"{m['name']}: row counts differ from manifest")
            log(f"ok    database {m['name']}: sha256, integrity_check and row counts of {len(counts)} tables match the manifest")
        # 3) git repositories
        sysman = json.load(open(f"{target}{STAGING}/system-manifest.json"))
        for g, head in sysman.get("git", {}).items():
            if not head or not os.path.isdir(target + g): continue
            env = {"PATH": "/usr/bin:/bin", "HOME": "/root", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_SYSTEM": "/dev/null"}
            r = subprocess.run(["git", "-c", f"safe.directory={target+g}", "-C", target + g, "fsck", "--no-dangling", "--no-progress"], capture_output=True, text=True, env=env)
            h = subprocess.run(["git", "-c", f"safe.directory={target+g}", "-C", target + g, "rev-parse", "HEAD"], capture_output=True, text=True, env=env).stdout.strip()
            if r.returncode != 0 or h != head: raise Fail(f"git {g}: fsck rc {r.returncode}, HEAD {h[:8]} vs manifest {head[:8]}")
            log(f"ok    git {g}: fsck clean, HEAD {head[:8]} as recorded")
        # 4) enabled systemd units of the snapshot are restorable (wants-symlinks present in restored /etc)
        if "/etc" in c["drill_paths"]:
            restored = set()
            for root, dirs, files in os.walk(f"{target}/etc/systemd/system"):
                if root.endswith((".wants", ".requires")): restored.update(files)
            mine = [u for u in sysman["enabled_units"] if os.path.exists(f"/etc/systemd/system/{u}")]
            missing = [u for u in mine if u not in restored and not u.endswith(".target")]
            if missing: raise Fail(f"enabled local units without restored wants-link: {missing[:5]}")
            log(f"ok    {len(mine)} locally defined enabled units have their unit files + enablement in the restored /etc")
        # 5) application check: StockPulse opens its restored database with its own image, isolated
        for app in c.get("app_checks", []):
            app_check(app, target)
        dt = time.time() - t0
        metric(job="drill", seconds=round(dt), restore_seconds=round(t_restore), snapshot=snap["short_id"], files=n)
        st["last_drill"] = now().isoformat(timespec="seconds")
        log(f"ok    restore drill passed in {dt:.0f} s")
    finally:
        shutil.rmtree(DRILL_DIR, ignore_errors=True)

def app_check(app, target):
    if app["type"] != "stockpulse": return
    img = subprocess.run(["docker", "inspect", "-f", "{{.Config.Image}}", app["container"]], capture_output=True, text=True).stdout.strip()
    if not img: raise Fail("StockPulse image not found (container not running?)")
    work = f"{DRILL_DIR}/stockpulse-isolated"; os.makedirs(work, mode=0o700)
    shutil.copy2(f"{target}{STAGING}/sqlite/{app['db']}.db", f"{work}/history.db")
    os.chown(work, app["uid"], app["uid"]); os.chown(f"{work}/history.db", app["uid"], app["uid"])
    code = ("import sqlite3; c=sqlite3.connect('/data/history.db'); "
            "assert c.execute('pragma integrity_check').fetchone()[0]=='ok'; "
            "runs=c.execute('select count(*) from runs').fetchone()[0]; "
            "c.execute('begin'); c.execute('create table _restore_probe(x)'); c.execute('insert into _restore_probe values (1)'); c.execute('rollback'); "
            "print(f'opened by the app image: integrity ok, {runs} runs, write transaction ok (rolled back)')")
    r = subprocess.run(["docker", "run", "--rm", "--network", "none", "--user", f"{app['uid']}:{app['uid']}", "--read-only",
                        "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "-e", "STOCKPULSE_FCM_KEY=/nonexistent",
                        "-v", f"{work}:/data", img, "python", "-c", code], capture_output=True, text=True, timeout=300)
    if r.returncode != 0: raise Fail(f"StockPulse isolated DB check failed: {r.stderr.strip()[-300:]}")
    log(f"ok    StockPulse ({img}, no network, no key): {r.stdout.strip()}")

# ------------------------------------------------------------------ init / status
def cmd_init(c):
    for f in ("restic.pw", "smb.cred"):
        if not os.path.exists(secret(c, f)): raise Fail(f"{secret(c, f)} missing")
    mount(c)
    base = os.path.dirname(c["repo"])
    os.makedirs(base, exist_ok=True)
    marker = os.path.join(base, "DESTINATION.json")
    if os.path.exists(secret(c, "destination-id")) or os.path.exists(marker):
        raise Fail("already initialised (destination-id or marker exists): nothing changed")
    if os.path.exists(c["repo"]) and os.listdir(c["repo"]): raise Fail(f"{c['repo']} not empty: nothing changed")
    did = str(uuid.uuid4())
    json.dump({"host": c["host"], "share": c["share"], "id": did, "created": now().isoformat(timespec="seconds")}, open(marker, "w"))
    r = subprocess.run([RESTIC, "init"], env=restic_env(c), capture_output=True, text=True)
    if r.returncode != 0: raise Fail(f"restic init: {r.stderr.strip()[-300:]}")
    rid = repo_id_from_files(c)
    for f, v in (("destination-id", did), ("repo-id", rid)):
        fd = os.open(secret(c, f), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600); os.write(fd, (v + "\n").encode()); os.close(fd)
    verify_destination(c)
    st = load_state(); st["integrity"] = "unknown"; save_state(st)
    log(f"ok    repository initialised at //{NAS}/{c['share']}/{os.path.relpath(c['repo'], MNT)}: id {rid[:12]}, marker {did[:8]}")

def cmd_status(c):
    st = load_state()
    log(json.dumps({k: v for k, v in st.items() if k != "jobs"}, indent=1))
    for j, v in sorted(st.get("jobs", {}).items()): log(f"{j:10} {v.get('result'):8} {v.get('end','')} {v.get('error','')[:120]}")
    if os.path.exists(METRICS):
        for l in open(METRICS).readlines()[-8:]: log("metric " + l.strip())

def preflight(c):
    ok = True
    for f in ("restic.pw", "smb.cred"):
        p = secret(c, f); good = os.path.exists(p) and (os.stat(p).st_mode & 0o077) == 0 and os.stat(p).st_uid == 0
        log(("ok    " if good else "FAIL  ") + f"{p} root-only"); ok &= good
    good = os.path.exists(RESTIC); log(("ok    " if good else "FAIL  ") + f"{RESTIC} " + (subprocess.run([RESTIC, "version"], capture_output=True, text=True).stdout.strip() if good else "missing")); ok &= good
    good = os.path.exists("/usr/sbin/mount.cifs") or os.path.exists("/sbin/mount.cifs"); log(("ok    " if good else "FAIL  ") + "mount.cifs (cifs-utils)"); ok &= good
    hcok = os.path.exists(secret(c, "healthchecks.json")); log(("ok    " if hcok else "info  ") + "Healthchecks URLs " + ("present" if hcok else "not configured yet"))
    for p in c["paths"]: log(("ok    " if os.path.exists(p) else "FAIL  ") + f"path {p}"); ok &= os.path.exists(p)
    return ok

# ------------------------------------------------------------------ main
JOBS = {"backup": job_backup, "check": lambda c, s: job_check(c, s), "fullcheck": lambda c, s: job_check(c, s, True),
        "prune": job_prune, "drill": job_drill}

def run_job(c, job):
    os.makedirs(os.path.dirname(LOCK), mode=0o700, exist_ok=True); os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
    lockf = open(LOCK, "w")
    t0 = time.time(); wait = c.get("lock_wait_seconds", 4 * 3600)
    while True:
        try: fcntl.flock(lockf, fcntl.LOCK_EX | fcntl.LOCK_NB); break
        except BlockingIOError:
            if time.time() - t0 > wait: raise Fail(f"another backup job held the lock for {wait}s")
            time.sleep(10)
    if time.time() - t0 > 10: log(f"info  waited {time.time()-t0:.0f} s for another job")
    st = load_state(); rec = {"start": now().isoformat(timespec="seconds")}
    hc(c, job, "start")
    out = []
    try:
        mount(c); verify_destination(c)
        JOBS[job](c, st)
        rec.update(result="ok")
    except (Fail, subprocess.TimeoutExpired, OSError) as e:
        rec.update(result="FAILED", error=str(e)); log(f"FAILED: {e}")
    finally:
        rec["end"] = now().isoformat(timespec="seconds"); st.setdefault("jobs", {})[job] = rec; save_state(st)
        try: umount()
        except Exception: pass
        hc(c, job, "success" if rec["result"] == "ok" else "fail", json.dumps(rec))
    return 0 if rec["result"] == "ok" else 1

def main():
    if os.geteuid() != 0: print("run as root"); return 2
    a = sys.argv[1:]
    if not a: print(__doc__); return 2
    c = load_conf(os.environ.get("HOSTBACKUP_HOST"))
    if a[0] in JOBS: return run_job(c, a[0])
    try:
        if a[0] == "preflight": return 0 if preflight(c) else 1
        if a[0] == "init": cmd_init(c); return 0
        if a[0] == "status": cmd_status(c); return 0
        if a[0] == "snapshots":
            mount(c); verify_destination(c); restic(c, "snapshots", "--host", c["host"]); return 0
        if a[0] == "mount-test":
            mount(c); verify_destination(c); log(f"ok    {MNT} = //{NAS}/{c['share']}, marker and repository id verified"); return 0
    except Fail as e:
        log(f"FAILED: {e}"); return 1
    finally:
        if a[0] in ("snapshots", "mount-test", "init"): umount()
    print(__doc__); return 2

if __name__ == "__main__":
    sys.exit(main())
