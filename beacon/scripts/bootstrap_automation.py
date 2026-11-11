#!/usr/bin/python3 -I
"""ONE-TIME bootstrap of the Beszel automation account. Runs ON BEACON as root; started by YOU
from dsserver with  bash /srv/stacks/beacon/scripts/setup-automation.sh  (see README "Automation").

Creating a Beszel user needs PocketBase superuser rights (the users collection has no create rule).
To avoid a permanent superuser, this script:
  1. generates the automation password and stores it in /root/beszel-automation/credentials (0600),
  2. creates a TEMPORARY superuser with a random password (Beszel's own `beszel superuser create`),
  3. as that superuser: creates user automation@beacon.lan (role "user", verified) and its
     notification settings (a copy of the existing notification URLs, emails off),
  4. with --migrate-alerts: copies every alert of the existing dashboard account(s) to the
     automation account (same system, type, threshold, duration), checks the copy, then deletes the
     originals, so alerts can be managed by the API and are still sent once, to the same ntfy topic,
  5. deletes the temporary superuser (also on any error) and checks the automation login.
It never reads, changes or logs in as your personal account. No secret is printed.
"""
import json, os, secrets, subprocess, sys, urllib.request, urllib.error

HUB = "http://127.0.0.1:8090"
DIR = "/root/beszel-automation"
CRED = DIR + "/credentials"
EMAIL = "automation@beacon.lan"
CT = "beszel-hub"


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


def ok(msg): print("ok    " + msg, flush=True)
def die(msg): raise SystemExit("FAILED: " + msg)


def superuser(action, email, pw=None):
    # Beszel's CLI takes the password as an argument; this runs inside the hub container on Beacon,
    # visible to root only, for a password that is deleted seconds later.
    args = ["docker", "exec", CT, "/beszel", "superuser", action, email] + ([pw] if pw else [])
    r = subprocess.run(args, capture_output=True, text=True)
    if r.returncode != 0:
        die(f"superuser {action}: exit {r.returncode}")


def main():
    migrate = sys.argv[1:] == ["--migrate-alerts"]
    if sys.argv[1:] not in ([], ["--migrate-alerts"]):
        die("usage: bootstrap_automation.py [--migrate-alerts]")
    if os.geteuid() != 0:
        die("run as root")

    os.umask(0o077)
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    if os.path.exists(CRED):
        die(f"{CRED} already exists: the account was bootstrapped before (to redo: see README 'Revoke')")
    pw = secrets.token_urlsafe(32)
    with open(CRED + ".new", "w") as f:
        f.write(f"email={EMAIL}\npassword={pw}\n")

    tmp_email = f"bootstrap-{secrets.token_hex(4)}@beacon.lan"
    tmp_pw = secrets.token_urlsafe(32)
    superuser("create", tmp_email, tmp_pw)
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
        os.replace(CRED + ".new", CRED)
        ok(f"user {EMAIL} created (id {uid}, role user); password in {CRED} (root 0600)")

        # notification settings: same webhook URLs as the existing account(s), no email
        st, us = call("GET", "/api/collections/user_settings/records?perPage=200", token=T)
        hooks = []
        for r in us["items"]:
            for h in (r.get("settings") or {}).get("webhooks") or []:
                if h not in hooks:
                    hooks.append(h)
        st, s = call("POST", "/api/collections/user_settings/records", {"user": uid, "settings": {"chartTime": "1h"}}, T)
        if st != 200:
            die(f"create user_settings: HTTP {st}")
        # the create hook fills in the account's e-mail address; replace the settings afterwards
        st, s = call("PATCH", f"/api/collections/user_settings/records/{s['id']}", {"settings": {"chartTime": "1h", "emails": [], "webhooks": hooks}}, T)
        if st != 200:
            die(f"update user_settings: HTTP {st}")
        ok(f"notification settings: {len(hooks)} webhook URL(s) copied, e-mail off")

        if migrate:
            st, al = call("GET", "/api/collections/alerts/records?perPage=500", token=T)
            old = [x for x in al["items"] if x["user"] != uid]
            keep = ("system", "name", "value", "min")
            made = []
            for x in old:
                st, n = call("POST", "/api/collections/alerts/records", dict({k: x[k] for k in keep}, user=uid), T)
                if st != 200:
                    for m in made:
                        call("DELETE", f"/api/collections/alerts/records/{m}", token=T)
                    die(f"copy alert {x['name']}: HTTP {st}; copies removed again, originals untouched")
                made.append(n["id"])
            st, al = call("GET", f"/api/collections/alerts/records?perPage=500&filter=(user%3D%27{uid}%27)", token=T)
            got = sorted((x["system"], x["name"], x["value"], x["min"]) for x in al["items"])
            want = sorted((x["system"], x["name"], x["value"], x["min"]) for x in old)
            if got != want:
                die("copied alerts differ from the originals; originals untouched")
            for x in old:
                call("DELETE", f"/api/collections/alerts/records/{x['id']}", token=T)
            st, al = call("GET", "/api/collections/alerts/records?perPage=500", token=T)
            left = [x for x in al["items"] if x["user"] != uid]
            if left:
                die(f"{len(left)} original alert(s) could not be deleted")
            ok(f"{len(old)} alert(s) moved to {EMAIL} (identical system/type/threshold/duration)")
    finally:
        superuser("delete", tmp_email)
        ok("temporary superuser deleted")
        if os.path.exists(CRED + ".new"):
            os.remove(CRED + ".new")

    st, a = call("POST", "/api/collections/users/auth-with-password", {"identity": EMAIL, "password": pw})
    if st != 200 or a["record"]["role"] != "user":
        die(f"automation login check: HTTP {st}")
    ok("automation account login works (role user)")
    print("BOOTSTRAP DONE")


main()
