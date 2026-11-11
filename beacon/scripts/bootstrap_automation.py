#!/usr/bin/python3 -I
"""ONE-TIME bootstrap of the Beszel automation account. Runs ON BEACON as root; started by YOU
from dsserver with  bash /srv/stacks/beacon/scripts/setup-automation.sh  (README "Automation (API)").

Creating a Beszel user needs PocketBase superuser rights (the users collection has no create rule;
Beszel offers no other way). To avoid a permanent superuser, this script:
  1. snapshots the existing configuration READ-ONLY from the hub database (alerts, users,
     notification settings, systems, network checks, superusers, history counts),
  2. generates the automation password -> /root/beszel-automation/credentials (root 0600),
  3. creates a TEMPORARY superuser with a random password (Beszel's own `beszel superuser create`),
  4. as that superuser, creates ONLY:
       - user automation@beacon.lan (role "user", verified), and
       - that user's own notification settings (the existing webhook URLs copied, e-mail off),
  5. deletes the temporary superuser in a `finally` block (success or failure), then VERIFIES the
     removal (database: the superuser list equals the snapshot; API: the temporary login fails),
  6. compares the snapshot again: existing alerts (all 13), your account, existing notification
     settings, systems, network checks and history must be unchanged (it stops with FAILED if not),
  7. checks the automation login.
It does not read your password, log in as you, or create/change/delete any alert. No secret is printed.
"""
import hashlib, json, os, secrets, sqlite3, subprocess, sys, urllib.error, urllib.request

HUB = "http://127.0.0.1:8090"
DB = "file:/srv/appdata/beszel/data.db?mode=ro"
DIR = "/root/beszel-automation"
CRED = DIR + "/credentials"
EMAIL = "automation@beacon.lan"
CT = "beszel-hub"
FAILS = []


def ok(msg): print("ok    " + msg, flush=True)
def bad(msg): print("FAIL  " + msg, flush=True); FAILS.append(msg)
def die(msg): raise SystemExit("FAILED: " + msg)


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


def q(sql):
    c = sqlite3.connect(DB, uri=True)
    try:
        return c.execute(sql).fetchall()
    finally:
        c.close()


def snapshot(exclude_user_email=None):
    """Read-only. Values are compared as digests; nothing secret is printed."""
    users = q("select id, email, role, verified, password, tokenKey, updated from users order by id")
    if exclude_user_email:
        users = [u for u in users if u[1] != exclude_user_email]
    ids = tuple(u[0] for u in users)
    keep = lambda rows, col=1: [r for r in rows if r[col] in ids]
    s = {
        "alerts": q("select id, user, system, name, value, min, created from alerts order by id"),
        "users": users,
        "user_settings": keep(q("select id, user, settings, updated from user_settings order by id")),
        "systems": q("select id, name, host, port, users from systems order by id"),
        "network_monitors": q("select id, system, protocol, target, port, interval, enabled, server, skipTlsVerify from network_monitors order by id"),
        "superusers": q("select id, email from _superusers order by id"),
        "fingerprints": q("select id, system, token from fingerprints order by id"),
    }
    counts = {t: q(f"select count(*) from {t}")[0][0] for t in ("system_stats", "container_stats", "alerts_history")}
    return s, counts


def digest(v):
    return hashlib.sha256(json.dumps(v, sort_keys=True, default=str).encode()).hexdigest()[:12]


def superuser(action, email, pw=None):
    # Beszel's CLI takes the password as an argument: it runs inside the hub container on Beacon,
    # visible to root only, for a random password that is deleted seconds later.
    r = subprocess.run(["docker", "exec", CT, "/beszel", "superuser", action, email] + ([pw] if pw else []),
                       capture_output=True, text=True)
    return r.returncode


def main():
    if sys.argv[1:]:
        die("usage: bootstrap_automation.py   (no options)")
    if os.geteuid() != 0:
        die("run as root")
    os.umask(0o077)
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    if os.path.exists(CRED):
        die(f"{CRED} exists: already bootstrapped (README 'Automation: revoke' to start over)")
    if q(f"select count(*) from users where email = '{EMAIL}'")[0][0]:
        die(f"{EMAIL} already exists in Beszel but {CRED} is missing (README 'Automation: revoke')")

    before, counts0 = snapshot()
    ok(f"snapshot: {len(before['alerts'])} alerts, {len(before['users'])} user(s), {len(before['systems'])} systems, "
       f"{len(before['network_monitors'])} network checks, {len(before['superusers'])} superuser(s)")
    if len(before["alerts"]) != 13:
        die(f"expected 13 alerts, found {len(before['alerts'])}; nothing changed")

    pw = secrets.token_urlsafe(32)
    tmp_email = f"bootstrap-{secrets.token_hex(4)}@beacon.lan"
    tmp_pw = secrets.token_urlsafe(32)
    uid = None
    if superuser("create", tmp_email, tmp_pw) != 0:
        die("could not create the temporary superuser; nothing changed")
    ok("temporary superuser created")
    try:
        st, a = call("POST", "/api/collections/_superusers/auth-with-password", {"identity": tmp_email, "password": tmp_pw})
        if st != 200:
            die(f"temporary superuser login: HTTP {st}")
        T = a["token"]
        st, u = call("POST", "/api/collections/users/records", {
            "email": EMAIL, "password": pw, "passwordConfirm": pw, "role": "user", "verified": True, "emailVisibility": False}, T)
        if st != 200:
            die(f"create {EMAIL}: HTTP {st} {u.get('message')}")
        uid = u["id"]
        with open(CRED + ".new", "w") as f:
            f.write(f"email={EMAIL}\npassword={pw}\n")
        os.replace(CRED + ".new", CRED)
        ok(f"user {EMAIL} created (id {uid}, role user); password in {CRED} (root 0600)")

        # The new account's own notification settings (the hook on create fills in its e-mail address,
        # so the settings are written again afterwards). Existing settings are only read.
        hooks = []
        for r in before["user_settings"]:
            for h in (json.loads(r[2] or "{}").get("webhooks") or []):
                if h not in hooks:
                    hooks.append(h)
        st, s = call("POST", "/api/collections/user_settings/records", {"user": uid, "settings": {"chartTime": "1h"}}, T)
        if st != 200:
            die(f"create the automation account's notification settings: HTTP {st}")
        st, s = call("PATCH", f"/api/collections/user_settings/records/{s['id']}",
                     {"settings": {"chartTime": "1h", "emails": [], "webhooks": hooks}}, T)
        if st != 200:
            die(f"write the automation account's notification settings: HTTP {st}")
        ok(f"automation account's own notification settings: {len(hooks)} webhook URL(s) (copied), e-mail off")
    finally:
        rc = superuser("delete", tmp_email)
        print(("ok    " if rc == 0 else "FAIL  ") + f"temporary superuser delete (exit {rc})", flush=True)
        if os.path.exists(CRED + ".new"):
            os.remove(CRED + ".new")
        # explicit verification of the removal, also when something above failed
        su_now = q("select id, email from _superusers order by id")
        if su_now == before["superusers"] and not any(e == tmp_email for _, e in su_now):
            ok(f"superusers back to the snapshot ({len(su_now)}); temporary one gone")
        else:
            bad("superuser list differs from the snapshot: remove it by hand: "
                "sudo docker exec beszel-hub /beszel superuser delete <email shown in the dashboard /_/>")
        st, _ = call("POST", "/api/collections/_superusers/auth-with-password", {"identity": tmp_email, "password": tmp_pw})
        ok("temporary superuser login refused") if st != 200 else bad("temporary superuser can still log in")

    after, counts1 = snapshot(exclude_user_email=EMAIL)
    for k in before:
        (ok if before[k] == after[k] else bad)(f"{k}: unchanged ({len(after[k])}, digest {digest(after[k])})"
                                              if before[k] == after[k] else f"{k}: CHANGED")
    for t in counts0:
        (ok if counts1[t] >= counts0[t] else bad)(f"{t}: {counts0[t]} -> {counts1[t]} records (kept)")

    st, a = call("POST", "/api/collections/users/auth-with-password", {"identity": EMAIL, "password": pw})
    (ok if st == 200 and a["record"]["role"] == "user" else bad)(f"automation account login: HTTP {st}")
    if FAILS:
        die(f"{len(FAILS)} check(s) failed (see FAIL lines)")
    print("BOOTSTRAP DONE")


main()
