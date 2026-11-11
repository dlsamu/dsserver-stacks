#!/usr/bin/python3 -I
"""Beszel REST API client for automation. Runs ON BEACON as root (via `ssh beacon sudo ...`);
called by /srv/stacks/beacon/scripts/bz on dsserver.

  beszel_api.py METHOD PATH      request body (JSON), if any, on stdin
  beszel_api.py test-notify      send Beszel's test notification to this account's own webhook URL(s)

- Logs in as the dedicated automation account (role "user", not a superuser) with the password in
  /root/beszel-automation/credentials (root 0600; written by bootstrap_automation.py). The password
  never leaves Beacon and is never in a command line.
- A fresh short-lived session token is obtained for every call, kept in memory only, and dropped.
- Talks to the hub on 127.0.0.1:8090 only.
- Output is redacted: tokens, passwords, fingerprints, notification URLs (ntfy topic) and
  Healthchecks URLs are replaced, so responses are safe to show.
Stdlib only.
"""
import json, re, sys, urllib.error, urllib.request

HUB = "http://127.0.0.1:8090"
CRED = "/root/beszel-automation/credentials"
SECRET_KEYS = {"token", "tokenKey", "password", "passwordConfirm", "oldPassword", "fingerprint"}


def creds():
    d = {}
    with open(CRED) as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("=")
            if k:
                d[k] = v
    return d["email"], d["password"]


def call(method, path, body=None, token=None):
    req = urllib.request.Request(HUB + path, method=method,
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except ValueError:
            return e.code, {"message": raw.decode(errors="replace")[:300]}


def redact_str(s):
    # notification (shoutrrr) URLs such as ntfy://host/<topic>: keep scheme + host. http(s) is left alone.
    s = re.sub(r"\b((?!https?://)[a-z][a-z0-9+.-]*://[^/\s\"]+/)[^?\s\"]+", r"\1<redacted>", s)
    return re.sub(r"(hc-ping\.com/)[^\s\"]+", r"\1<redacted>", s)


def redact(o):
    if isinstance(o, dict):
        return {k: ("<redacted>" if k in SECRET_KEYS and v not in (None, "") else redact(v)) for k, v in o.items()}
    if isinstance(o, list):
        return [redact(v) for v in o]
    if isinstance(o, str):
        return redact_str(o)
    return o


def login():
    email, pw = creds()
    st, auth = call("POST", "/api/collections/users/auth-with-password", {"identity": email, "password": pw})
    if st != 200:
        sys.exit(f"login failed: HTTP {st} {redact(auth)}")
    return auth["token"]


def test_notify():
    t = login()
    st, us = call("GET", "/api/collections/user_settings/records", token=t)
    hooks = [h for r in us.get("items", []) for h in (r.get("settings") or {}).get("webhooks") or []]
    if not hooks:
        sys.exit("this account has no notification URL")
    for h in hooks:
        st, r = call("POST", "/api/beszel/test-notification", {"url": h}, t)
        print(redact_str(h), "->", "sent" if st == 200 and r == {"err": False} else f"FAILED HTTP {st} {redact(r)}")


def main():
    if sys.argv[1:] == ["test-notify"]:
        return test_notify()
    if len(sys.argv) != 3 or sys.argv[1] not in ("GET", "POST", "PATCH", "DELETE") or not sys.argv[2].startswith("/api/"):
        sys.exit("usage: beszel_api.py GET|POST|PATCH|DELETE /api/... (JSON body on stdin)")
    method, path = sys.argv[1], sys.argv[2]
    data = sys.stdin.read() if method in ("POST", "PATCH") else ""
    body = json.loads(data) if data.strip() else None
    st, res = call(method, path, body, login())
    print(json.dumps(redact(res), indent=1))
    if st >= 300:
        sys.exit(f"HTTP {st}")


main()
