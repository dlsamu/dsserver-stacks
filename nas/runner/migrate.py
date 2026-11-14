#!/usr/bin/env python3
"""DATASERVER -> dsnas migration runner (runs ON dsnas as root).

Sources are read-only CIFS mounts of DATASERVER shares under SRC/<share>. Destination: /volume1/<share>.
Never writes to the source. Never overwrites an existing destination file (atomic link-into-place).

  migrate.py plan                       enumerate sources, apply mapping, record manifest + collisions
  migrate.py copy [collections...]      copy pending files (resumable, retries), SHA-256 of the bytes read
  migrate.py verify-dst [collections..] re-read destination files from disk, compare SHA-256
  migrate.py export                     write manifest TSV + summary JSON
  migrate.py status                     one-line progress per collection
"""
import hashlib, json, os, sqlite3, sys, time, unicodedata, signal, traceback

W = "/volume1/@claude-migration"
SRC = W + "/src"
DB = W + "/state.db"
LOG = W + "/logs"
HB = W + "/heartbeat"
CHUNK = 4 * 1024 * 1024
STOP = False


def onsig(*_):
    global STOP
    STOP = True


signal.signal(signal.SIGTERM, onsig)
signal.signal(signal.SIGINT, onsig)


def log(msg, name="runner"):
    os.makedirs(LOG, exist_ok=True)
    line = time.strftime("%Y-%m-%d %H:%M:%S ") + msg
    with open(f"{LOG}/{name}.log", "a") as f:
        f.write(line + "\n")
    print(line, flush=True)


def beat():
    with open(HB, "w") as f:
        f.write(str(time.time()))


def db():
    c = sqlite3.connect(DB, timeout=60)
    c.execute("""CREATE TABLE IF NOT EXISTS files(
        id INTEGER PRIMARY KEY, src BLOB UNIQUE, dst BLOB, collection TEXT, rule TEXT,
        size INTEGER, mtime_ns INTEGER, status TEXT, sha_stream TEXT, sha_dst TEXT,
        attempts INTEGER DEFAULT 0, error TEXT, copied_at REAL, verified_at REAL)""")
    c.execute("CREATE TABLE IF NOT EXISTS issues(id INTEGER PRIMARY KEY, kind TEXT, src BLOB, dst BLOB, detail TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS excluded(src BLOB PRIMARY KEY, size INTEGER, why TEXT)")
    c.execute("CREATE TABLE IF NOT EXISTS emptydirs(src BLOB PRIMARY KEY)")
    return c


def b(s):
    return os.fsencode(s)


def u(x):
    return os.fsdecode(x)


def load_map():
    return json.load(open(W + "/mapping.json"))


def match(m, rel):
    """rel = '<share>/<path>' -> ('exclude', why) | ('map', collection, dst, rule) | ('review', dst)"""
    parts = rel.split("/")
    if any(p in m["exclude_names"] for p in parts):
        return ("exclude", "system/metadata file (" + next(p for p in parts if p in m["exclude_names"]) + ")")
    for e in m["exclude"]:
        if rel == e["src"] or (e["src"].endswith("/") and rel.startswith(e["src"])):
            return ("exclude", e["why"])
    for r in m["rules"]:
        s = r["src"]
        if s.endswith("/"):
            if rel.startswith(s):
                return ("map", r["collection"], r["dst"] + rel[len(s):], s)
        elif rel == s:
            return ("map", r["collection"], r["dst"], s)
    return ("review", m["review_dst"] + rel)


def plan():
    m = load_map()
    c = db()
    if c.execute("SELECT count(*) FROM files").fetchone()[0]:
        log("plan: manifest already exists, re-planning only adds new source files")
    shares = sorted(os.listdir(SRC))
    n = 0
    for share in shares:
        root = os.path.join(SRC, share)
        if not os.path.ismount(root):
            log(f"plan: {root} is not mounted, skipping share")
            continue
        for dp, dns, fns in os.walk(root):
            beat()
            reldir = share + dp[len(root):]
            if not dns and not fns:
                c.execute("INSERT OR IGNORE INTO emptydirs VALUES(?)", (b(reldir),))
            for fn in fns:
                full = os.path.join(dp, fn)
                rel = reldir + "/" + fn
                st = os.stat(full)
                r = match(m, rel)
                if r[0] == "exclude":
                    c.execute("INSERT OR IGNORE INTO excluded VALUES(?,?,?)", (b(rel), st.st_size, r[1]))
                    continue
                if r[0] == "review":
                    coll, dst, rule = "review", r[1], "(unmapped)"
                else:
                    _, coll, dst, rule = r
                c.execute("""INSERT OR IGNORE INTO files(src,dst,collection,rule,size,mtime_ns,status)
                             VALUES(?,?,?,?,?,?, 'pending')""", (b(rel), b(dst), coll, rule, st.st_size, st.st_mtime_ns))
                n += 1
        c.commit()
    # collisions: two sources -> one destination, or names equal except for case/Unicode form in one directory
    c.execute("DELETE FROM issues WHERE kind IN ('collision','case-collision')")
    seen, folded = {}, {}
    for fid, src, dst in c.execute("SELECT id,src,dst FROM files ORDER BY id").fetchall():
        if dst in seen:
            c.execute("UPDATE files SET status='collision', error=? WHERE id=?", ("destination already claimed by " + u(seen[dst]), fid))
            c.execute("INSERT INTO issues(kind,src,dst,detail) VALUES('collision',?,?,?)", (src, dst, "same destination as " + u(seen[dst])))
            continue
        seen[dst] = src
        key = unicodedata.normalize("NFC", u(dst)).casefold()
        if key in folded and folded[key] != dst:
            c.execute("INSERT INTO issues(kind,src,dst,detail) VALUES('case-collision',?,?,?)",
                      (src, dst, "differs only by case/Unicode form from " + u(folded[key]) + " (both copied; SMB clients may show only one)"))
        folded.setdefault(key, dst)
    c.commit()
    log(f"plan: {n} files recorded; " + json.dumps(dict(c.execute("SELECT collection,count(*) FROM files GROUP BY collection").fetchall())))


def sha_file(path):
    h = hashlib.sha256()
    with open(path, "rb", buffering=0) as f:
        while True:
            blk = f.read(CHUNK)
            if not blk:
                break
            h.update(blk)
    return h.hexdigest()


def copy_one(c, fid, src, dst, size, mtime_ns, status):
    sp = os.path.join(SRC, u(src))
    dp = os.path.join("/volume1", u(dst))
    st = os.stat(sp)
    if st.st_size != size or st.st_mtime_ns != mtime_ns:
        raise RuntimeError(f"source changed since planning (size {size}->{st.st_size})")
    if os.path.lexists(dp):
        if status == "mismatch":
            pass                      # our own earlier copy failed verification: replaced below after a good copy
        else:
            ds = os.stat(dp)
            if ds.st_size == size and ds.st_mtime_ns == mtime_ns:
                # probably our own copy from an interrupted batch: accept only if both sides hash identically
                s_src, s_dst = sha_file(sp), sha_file(dp)
                if s_src == s_dst:
                    return s_src
            raise FileExistsError("destination exists and was not written by this migration")
    os.makedirs(os.path.dirname(dp), exist_ok=True)
    tmp = os.path.join(os.path.dirname(dp), ".migrating-" + str(fid))
    h = hashlib.sha256()
    n = 0
    with open(sp, "rb", buffering=0) as fi, open(tmp, "wb") as fo:
        while True:
            blk = fi.read(CHUNK)
            if not blk:
                break
            h.update(blk)
            fo.write(blk)
            n += len(blk)
            if n % (256 * CHUNK) < CHUNK:
                beat()
    if n != size:
        os.unlink(tmp)
        raise IOError(f"short read: {n} of {size} bytes")
    os.utime(tmp, ns=(st.st_atime_ns, st.st_mtime_ns))
    if status == "mismatch" and os.path.lexists(dp):
        os.replace(tmp, dp)
    else:
        os.link(tmp, dp)              # fails if dp exists: never overwrites
        os.unlink(tmp)
    return h.hexdigest()


def copy(colls, workers=4, batch=100):
    from concurrent.futures import ThreadPoolExecutor, as_completed
    c = db()
    q = "SELECT id,src,dst,size,mtime_ns,status,collection FROM files WHERE status IN ('pending','failed','mismatch') AND attempts < 5"
    rows = c.execute(q).fetchall()
    if colls:
        rows = [r for r in rows if r[6] in colls]
    order = {k: i for i, k in enumerate(colls)} if colls else {}
    rows.sort(key=lambda r: (order.get(r[6], 99), r[0]))
    total = sum(r[3] for r in rows)
    log(f"copy: {len(rows)} files, {total/2**30:.1f} GiB, collections={colls or 'all'}, workers={workers}", "copy")

    def work(r):
        fid, src, dst, size, mt, status, coll = r
        last_err = None
        for attempt in range(3):
            if STOP:
                return (r, "stopped", None)
            try:
                return (r, "copied", copy_one(None, fid, src, dst, size, mt, status))
            except FileExistsError as e:
                return (r, "collision", str(e))
            except Exception as e:
                last_err = f"{type(e).__name__}: {e}"
                log(f"copy: attempt {attempt+1} failed for {u(src)}: {last_err}", "copy")
                time.sleep(10 * (attempt + 1))
        return (r, "failed", last_err)

    done_b, t0, last, n = 0, time.time(), time.time(), 0
    pending = []
    def flush():
        os.sync()                      # data on disk before the status says 'copied'
        for (r, st, val) in pending:
            fid, src, dst = r[0], r[1], r[2]
            if st == "copied":
                c.execute("UPDATE files SET status='copied', sha_stream=?, sha_dst=NULL, error=NULL, copied_at=?, attempts=attempts+1 WHERE id=?", (val, time.time(), fid))
            elif st == "collision":
                c.execute("UPDATE files SET status='collision', error=? WHERE id=?", (val, fid))
                c.execute("INSERT INTO issues(kind,src,dst,detail) VALUES('existing-destination',?,?,?)", (src, dst, val))
            elif st == "failed":
                c.execute("UPDATE files SET status='failed', error=?, attempts=attempts+3 WHERE id=?", (val, fid))
        c.commit()
        pending.clear()
        beat()

    with ThreadPoolExecutor(workers) as ex:
        it = iter(rows)
        futs = set()
        for r in it:
            futs.add(ex.submit(work, r))
            if len(futs) >= workers * 4:
                break
        while futs:
            donef = next(as_completed(futs))
            futs.remove(donef)
            r, st, val = donef.result()
            if st != "stopped":
                pending.append((r, st, val)); n += 1; done_b += r[3]
            if not STOP:
                nxt = next(it, None)
                if nxt is not None:
                    futs.add(ex.submit(work, nxt))
            if len(pending) >= batch:
                flush()
            if time.time() - last > 60:
                last = time.time()
                el = time.time() - t0
                log(f"copy: {n}/{len(rows)} files, {done_b/2**30:.1f}/{total/2**30:.1f} GiB, {done_b/el/2**20:.1f} MiB/s", "copy")
    flush()
    if STOP:
        log("copy: stop requested", "copy")
    el = time.time() - t0
    log(f"copy: finished pass, {n} files, {done_b/2**30:.1f} GiB in {el/60:.0f} min", "copy")


def verify_dst(colls):
    os.system("sync; echo 1 > /proc/sys/vm/drop_caches")
    c = db()
    rows = c.execute("SELECT id,dst,size,sha_stream,collection FROM files WHERE status='copied'").fetchall()
    if colls:
        rows = [r for r in rows if r[4] in colls]
    log(f"verify-dst: {len(rows)} files", "verify")
    bad = 0
    for i, (fid, dst, size, sha_s, coll) in enumerate(rows):
        if STOP:
            break
        dp = os.path.join("/volume1", u(dst))
        try:
            st = os.stat(dp)
            sha = sha_file(dp)
            ok = (sha == sha_s and st.st_size == size)
            c.execute("UPDATE files SET sha_dst=?, status=?, verified_at=? WHERE id=?",
                      (sha, "verified-dst" if ok else "mismatch", time.time(), fid))
            if not ok:
                bad += 1
                log(f"verify-dst: MISMATCH {u(dst)}", "verify")
        except Exception as e:
            bad += 1
            c.execute("UPDATE files SET status='mismatch', error=? WHERE id=?", (f"verify: {e}", fid))
        if i % 200 == 0:
            c.commit()
            beat()
    c.commit()
    log(f"verify-dst: done, {bad} problems", "verify")


def export():
    c = db()
    out = W + "/manifest.tsv"
    with open(out, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("old_path\tnew_path\tcollection\tsize\tmtime_ns\tsha256_read\tsha256_dst\tstatus\n")
        for r in c.execute("SELECT src,dst,collection,size,mtime_ns,sha_stream,sha_dst,status FROM files ORDER BY collection,src"):
            f.write("\t".join([u(r[0]), u(r[1])] + ["" if x is None else str(x) for x in r[2:]]) + "\n")
    with open(W + "/excluded.tsv", "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("old_path\tsize\treason\n")
        for s, z, why in c.execute("SELECT src,size,why FROM excluded ORDER BY src"):
            f.write(f"{u(s)}\t{z}\t{why}\n")
    with open(W + "/issues.tsv", "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write("kind\told_path\tnew_path\tdetail\n")
        for k, s, d, det in c.execute("SELECT kind,src,dst,detail FROM issues ORDER BY kind,src"):
            f.write(f"{k}\t{u(s)}\t{u(d)}\t{det}\n")
    with open(W + "/emptydirs.tsv", "w", encoding="utf-8", errors="surrogateescape") as f:
        for (s,) in c.execute("SELECT src FROM emptydirs ORDER BY src"):
            f.write(u(s) + "\n")
    summ = {}
    for coll, st, n, z in c.execute("SELECT collection,status,count(*),sum(size) FROM files GROUP BY collection,status"):
        summ.setdefault(coll, {})[st] = {"files": n, "bytes": z}
    json.dump(summ, open(W + "/summary.json", "w"), indent=1)
    print(json.dumps(summ, indent=1))


def status():
    c = db()
    for coll, st, n, z in c.execute("SELECT collection,status,count(*),sum(size) FROM files GROUP BY collection,status ORDER BY collection"):
        print(f"{coll:18} {st:13} {n:7} {z/2**30:9.2f} GiB")
    print("issues:", c.execute("SELECT kind,count(*) FROM issues GROUP BY kind").fetchall())


if __name__ == "__main__":
    cmd, args = sys.argv[1], sys.argv[2:]
    try:
        {"plan": lambda: plan(), "copy": lambda: copy(args), "verify-dst": lambda: verify_dst(args),
         "export": lambda: export(), "status": lambda: status()}[cmd]()
    except Exception:
        log("FATAL " + traceback.format_exc().replace("\n", " | "))
        raise
