#!/usr/bin/python3 -I
"""Transfer ownership of existing Beszel alert rules IN PLACE (same records, same IDs) between the
dashboard account and the automation account. Runs ON BEACON as root; started from dsserver by
scripts/alert-ownership.sh. README "Automation (API)".

  alert_owner.py check      read-only: preconditions for migrate AND rollback, current state
  alert_owner.py migrate    admin@beacon.lan -> automation account (all alerts the dashboard account owns)
  alert_owner.py rollback   automation account -> admin@beacon.lan (exactly the IDs of the last migrate)

How (migrate/rollback):
 1. preconditions (read-only): hub healthy; expected number of alerts, all owned by the source
    account; none firing or pending; both accounts' notification URLs identical (digest); no quiet
    hours on either account; no e-mail recipients with SMTP on (so delivery can't change)
 2. full read-only snapshot -> /root/beszel-automation/alert-ownership/<mode>-<time>.json (root 0600)
 3. TEMPORARY superuser (Beszel's own CLI), the only way to change an alert's owner: Beszel's API
    rules forbid changing `user`, even for the owner. For each alert: PATCH {"user": <target>} and
    check the response. On any error the alerts already changed are set back.
 4. `finally`: delete the temporary superuser, then VERIFY (superuser list == snapshot, login refused)
 5. compare with the snapshot: every alert field except `user`/`updated` identical; history, other
    users' data, notification settings, systems, network checks, tokens unchanged; metrics kept
 6. check through the API as the automation account that it sees (migrate) / no longer sees
    (rollback) exactly these alerts
Your password is never used or read. No secret is printed or written to the snapshot (notification
settings are stored as digests only).
Testing only: BZ_HUB, BZ_DB, BZ_CT, BZ_STATE override hub URL, database, container, state dir;
BZ_TEST_FAIL_AFTER=N simulates a failure after N alerts (ignored unless BZ_DB is set).
"""
import hashlib, json, os, secrets, sqlite3, subprocess, sys, time, urllib.error, urllib.request

HUB = os.environ.get("BZ_HUB", "http://127.0.0.1:8090")
DB = "file:%s?mode=ro" % os.environ.get("BZ_DB", "/srv/appdata/beszel/data.db")
CT = os.environ.get("BZ_CT", "beszel-hub")
STATE = os.environ.get("BZ_STATE", "/root/beszel-automation/alert-ownership")
CRED = "/root/beszel-automation/credentials"
PERSONAL = "admin@beacon.lan"
EXPECT = 13
FAILS = []


def ok(m): print("ok    " + m, flush=True)
def bad(m): print("FAIL  " + m, flush=True); FAILS.append(m)
def die(m): raise SystemExit("FAILED: " + m)
def digest(v): return hashlib.sha256(json.dumps(v, sort_keys=True, default=str).encode()).hexdigest()[:12]


def q(sql, args=()):
    c = sqlite3.connect(DB, uri=True)
    c.row_factory = sqlite3.Row
    try:
        return [dict(r) for r in c.execute(sql, args).fetchall()]
    finally:
        c.close()


def call(method, path, body=None, token=None):
    req = urllib.request.Request(HUB + path, method=method, data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        return e.code, {"message": e.read().decode(errors="replace")[:200]}


def automation_creds():
    d = dict(l.rstrip("\n").split("=", 1) for l in open(CRED) if "=" in l)
    return d["email"], d["password"]


def snapshot():
    users = {u["email"]: u for u in q("select id, email, role, verified, password, tokenKey, updated from users")}
    settings = {}
    for r in q("select id, user, settings, updated from user_settings"):
        j = json.loads(r["settings"] or "{}")
        settings[r["user"]] = {"id": r["id"], "updated": r["updated"], "webhooks": digest(j.get("webhooks") or []),
                               "emails": len(j.get("emails") or []), "other": digest({k: v for k, v in j.items() if k not in ("webhooks", "emails")})}
    smtp = False
    for p in q("select id, value from _params where id = 'settings'"):
        smtp = bool((json.loads(p["value"] or "{}").get("smtp") or {}).get("enabled"))
    return {
        "time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "alerts": q("select id, user, system, name, value, min, triggered, state, pending_since, created, updated from alerts order by id"),
        "alerts_history": q("select * from alerts_history order by id"),
        "quiet_hours": q("select id, user from quiet_hours order by id"),
        "users": {e: {"id": u["id"], "role": u["role"], "verified": u["verified"], "cred_digest": digest([u["password"], u["tokenKey"]]), "updated": u["updated"]} for e, u in users.items()},
        "user_settings": settings,
        "smtp_enabled": smtp,
        "systems": q("select id, name, host, port, users from systems order by id"),
        "network_monitors": q("select id, system, protocol, target, port, interval, enabled, server, skipTlsVerify from network_monitors order by id"),
        "fingerprints": digest(q("select id, system, token from fingerprints order by id")),
        "superusers": [r["email"] for r in q("select email from _superusers order by id")],
        "counts": {t: q(f"select count(*) n from {t}")[0]["n"] for t in ("system_stats", "container_stats", "alerts_history")},
    }


def ids(snap):
    p = snap["users"].get(PERSONAL)
    a_email, _ = automation_creds()
    a = snap["users"].get(a_email)
    if not p or not a:
        die(f"missing account: {PERSONAL if not p else a_email}")
    return p["id"], a["id"], a_email


def preconditions(snap, src, dst, alert_ids, label):
    n = 0
    st, _ = call("GET", "/api/health")
    (ok if st == 200 else bad)(f"[{label}] hub API healthy (HTTP {st})")
    env = subprocess.run(["docker", "inspect", "-f", "{{range .Config.Env}}{{println .}}{{end}}", CT], capture_output=True, text=True).stdout.split()
    if label == "migrate":   # without it the automation account could own but not edit alerts on systems it isn't a member of
        (ok if "SHARE_ALL_SYSTEMS=true" in env else bad)(f"[{label}] hub runs with SHARE_ALL_SYSTEMS=true")
    owned = [a for a in snap["alerts"] if a["id"] in alert_ids]
    (ok if len(owned) == len(alert_ids) else bad)(f"[{label}] {len(owned)}/{len(alert_ids)} alerts present")
    wrong = [a["id"] for a in owned if a["user"] != src]
    (ok if not wrong else bad)(f"[{label}] all owned by the source account" + (f" (not: {wrong})" if wrong else ""))
    firing = [a["id"] for a in owned if a["triggered"] or a["pending_since"]]
    (ok if not firing else bad)(f"[{label}] none firing or pending" + (f" (firing/pending: {firing}; wait until clear)" if firing else ""))
    s = snap["user_settings"]
    same = src in s and dst in s and s[src]["webhooks"] == s[dst]["webhooks"]
    (ok if same else bad)(f"[{label}] notification URLs identical on both accounts (digest {s.get(dst, {}).get('webhooks')})")
    qh = [x for x in snap["quiet_hours"] if x["user"] in (src, dst)]
    (ok if not qh else bad)(f"[{label}] no quiet hours on either account")
    em = snap["smtp_enabled"] and (s.get(src, {}).get("emails") or s.get(dst, {}).get("emails"))
    (ok if not em else bad)(f"[{label}] e-mail delivery can't change (SMTP {'on' if snap['smtp_enabled'] else 'off'})")


def superuser(action, email, pw=None):
    # Beszel's CLI takes the password as an argument: inside the hub container on Beacon, root-only,
    # for a random password deleted seconds later.
    return subprocess.run(["docker", "exec", CT, "/beszel", "superuser", action, email] + ([pw] if pw else []),
                          capture_output=True, text=True).returncode


def transfer(alert_ids, src, dst, before):
    tmp_email, tmp_pw = f"owner-{secrets.token_hex(4)}@beacon.lan", secrets.token_urlsafe(32)
    if superuser("create", tmp_email, tmp_pw) != 0:
        die("could not create the temporary superuser; nothing changed")
    ok("temporary superuser created")
    done = []
    try:
        st, a = call("POST", "/api/collections/_superusers/auth-with-password", {"identity": tmp_email, "password": tmp_pw})
        if st != 200:
            die(f"temporary superuser login: HTTP {st}; nothing changed")
        T = a["token"]
        orig = {a["id"]: a for a in before["alerts"]}
        # test hook: simulate a failure after N alerts; honoured only on a test copy (BZ_DB set)
        fail_after = int(os.environ.get("BZ_TEST_FAIL_AFTER", "-1")) if "BZ_DB" in os.environ else -1
        try:
            for i in alert_ids:
                if len(done) == fail_after:
                    raise RuntimeError(f"simulated failure after {fail_after} alert(s) (test copy only)")
                st, r = call("PATCH", f"/api/collections/alerts/records/{i}", {"user": dst}, T)
                if st != 200 or r.get("user") != dst:
                    raise RuntimeError(f"alert {i}: HTTP {st}")
                done.append(i)
                o = orig[i]
                diff = [k for k in ("system", "name", "value", "min", "triggered") if r.get(k) != (bool(o[k]) if k == "triggered" else o[k])]
                if diff:
                    raise RuntimeError(f"alert {i}: fields changed: {diff}")
            ok(f"{len(done)} alert(s): owner changed in place")
        except Exception as e:
            print(f"FAIL  {e}; setting {len(done)} changed alert(s) back", flush=True)
            back = 0
            for i in done:
                st, r = call("PATCH", f"/api/collections/alerts/records/{i}", {"user": src}, T)
                back += st == 200 and r.get("user") == src
            print(("ok    " if back == len(done) else "FAIL  ") + f"undo: {back}/{len(done)} set back", flush=True)
            die("transfer aborted")
    finally:
        rc = superuser("delete", tmp_email)
        print(("ok    " if rc == 0 else "FAIL  ") + f"temporary superuser delete (exit {rc})", flush=True)
        now = [r["email"] for r in q("select email from _superusers order by id")]
        if now == before["superusers"]:
            ok(f"superusers equal to the snapshot ({len(now)}); temporary one gone")
        else:
            bad(f"superusers differ from the snapshot: remove by hand: sudo docker exec {CT} /beszel superuser delete <the owner-…@beacon.lan entry>")
        st, _ = call("POST", "/api/collections/_superusers/auth-with-password", {"identity": tmp_email, "password": tmp_pw})
        ok("temporary superuser login refused") if st != 200 else bad("temporary superuser can still log in")


def compare(before, after, alert_ids, dst):
    b = {a["id"]: a for a in before["alerts"]}
    a_ = {a["id"]: a for a in after["alerts"]}
    (ok if set(b) == set(a_) else bad)(f"alert IDs identical ({len(a_)} alerts, none added or removed)")
    changed = []
    for i in b:
        if i not in a_:
            continue
        for k in b[i]:
            if k in ("updated",):
                continue
            want = dst if (k == "user" and i in alert_ids) else b[i][k]
            if a_[i][k] != want:
                changed.append(f"{i}.{k}")
    (ok if not changed else bad)("every alert identical except the owner of the transferred ones" + (f" (differs: {changed})" if changed else ""))
    for k in ("alerts_history", "quiet_hours", "users", "user_settings", "smtp_enabled", "systems", "network_monitors", "fingerprints", "superusers"):
        (ok if before[k] == after[k] else bad)(f"{k} unchanged" + ("" if before[k] == after[k] else ": CHANGED"))
    for t, n in before["counts"].items():
        (ok if after["counts"][t] >= n else bad)(f"{t}: {n} -> {after['counts'][t]} (kept)")


def automation_sees():
    email, pw = automation_creds()
    st, a = call("POST", "/api/collections/users/auth-with-password", {"identity": email, "password": pw})
    if st != 200:
        die(f"automation login: HTTP {st}")
    st, r = call("GET", "/api/collections/alerts/records?perPage=500&fields=id", token=a["token"])
    return {x["id"] for x in r["items"]}


def save(snap, mode, extra):
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    p = os.path.join(STATE, f"{mode}-{time.strftime('%Y%m%d-%H%M%S')}.json")
    with open(p, "w") as f:
        json.dump(dict(snap, **extra), f, indent=1, default=str)
    return p


def last_migration():
    if not os.path.isdir(STATE):
        return None
    m = sorted(f for f in os.listdir(STATE) if f.startswith("migrate-") and f.endswith(".done.json"))
    return os.path.join(STATE, m[-1]) if m else None


def main():
    mode = sys.argv[1] if len(sys.argv) == 2 else ""
    if mode not in ("check", "migrate", "rollback"):
        die("usage: alert_owner.py check|migrate|rollback")
    if os.geteuid() != 0:
        die("run as root")
    os.umask(0o077)
    snap = snapshot()
    pid, aid, a_email = ids(snap)
    mine = [a["id"] for a in snap["alerts"] if a["user"] == pid]
    theirs = [a["id"] for a in snap["alerts"] if a["user"] == aid]
    ok(f"accounts: {PERSONAL} ({pid}) owns {len(mine)} alert(s); {a_email} ({aid}) owns {len(theirs)}")

    if mode == "check":
        if mine:
            preconditions(snap, pid, aid, set(mine), "migrate")
            (ok if len(mine) == EXPECT else bad)(f"[migrate] {len(mine)} alerts to transfer (expected {EXPECT})")
        lm = last_migration()
        if lm:
            rb = set(json.load(open(lm))["transferred"])
            preconditions(snap, aid, pid, rb, "rollback")
        else:
            ok("[rollback] nothing to roll back (no completed migration recorded)")
        st, _ = call("POST", "/api/collections/users/auth-with-password", dict(zip(("identity", "password"), automation_creds())))
        (ok if st == 200 else bad)(f"automation account login (HTTP {st})")
        print("CHECK " + ("FAILED (see FAIL lines)" if FAILS else "PASSED (read-only, nothing changed)"))
        sys.exit(1 if FAILS else 0)

    if mode == "migrate":
        alert_ids, src, dst = mine, pid, aid
        if len(alert_ids) != EXPECT:
            die(f"{len(alert_ids)} alerts owned by {PERSONAL}, expected {EXPECT}; nothing changed")
    else:
        lm = last_migration()
        if not lm:
            die("no completed migration recorded; nothing to roll back")
        alert_ids, src, dst = json.load(open(lm))["transferred"], aid, pid
        ok(f"rolling back the {len(alert_ids)} alert(s) of {os.path.basename(lm)}")
    preconditions(snap, src, dst, set(alert_ids), mode)
    if FAILS:
        die(f"{len(FAILS)} precondition(s) failed; nothing changed")
    path = save(snap, mode, {"transferred": alert_ids, "from": src, "to": dst})
    ok(f"snapshot saved: {path}")

    transfer(alert_ids, src, dst, snap)
    after = snapshot()
    compare(snap, after, set(alert_ids), dst)
    seen = automation_sees()
    if mode == "migrate":
        (ok if set(alert_ids) <= seen else bad)(f"automation account sees all {len(alert_ids)} transferred alerts via the API")
    else:
        (ok if not (set(alert_ids) & seen) else bad)("automation account no longer sees them via the API")
    if FAILS:
        die(f"{len(FAILS)} check(s) failed; snapshot {path}")
    os.replace(path, path[:-5] + ".done.json")
    if mode == "rollback":
        lm = last_migration()
        os.replace(lm, lm.replace(".done.json", ".rolledback.json"))
    print(f"{mode.upper()} DONE")


main()
