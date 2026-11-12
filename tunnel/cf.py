#!/usr/bin/python3 -I
"""Cloudflare API steps for the StockPulse tunnel (called by host/scripts/16-tunnel.sh as root). Stdlib only.

The setup token is read from TOKEN_FILE (root 0600, `CF_API_TOKEN=...`) by this process itself: it never appears
in argv, the environment or output. API error messages are printed (codes/messages only; they contain no secrets).
Allowed e-mail addresses come from a root-only file and are printed masked (d***@example.com).

  cf.py check                                   read-only: token, zone, account, Zero Trust team, tunnel, apps, DNS
  cf.py access-setup                            idempotent: OTP login method, policies, app + /healthz bypass app
  cf.py tunnel-create CREDS_OUT                 create the tunnel (locally managed) and write its credentials file
  cf.py tunnel-id                               print the tunnel id (empty if none)
  cf.py tunnel-status                           connector status as seen by Cloudflare
  cf.py dns-show | dns-switch | dns-rollback    the one record stockpulse.rubusdua.net
  cf.py teardown                                delete Access apps/policies and the tunnel (rollback, step 3)
"""
import base64, json, os, re, secrets, sys, urllib.error, urllib.request

TOKEN_FILE = "/etc/dsserver-secrets/cloudflare-tunnel-setup.env"
EMAILS_FILE = "/etc/dsserver-secrets/stockpulse-access-emails"
ZONE = "rubusdua.net"
HOST = "stockpulse.rubusdua.net"
HEALTH = "/healthz"
LAN_IP = "192.168.68.115"
TUNNEL = "dsserver-apps"
SESSION = "720h"
APP, APP_HEALTH = "StockPulse", "StockPulse healthz (monitoring)"
POL_ALLOW, POL_BYPASS = "StockPulse family (e-mail allow-list)", "StockPulse healthz bypass"
API = "https://api.cloudflare.com/client/v4"


class CfError(Exception):
    pass


def token() -> str:
    with open(TOKEN_FILE) as f:
        for line in f:
            if line.startswith("CF_API_TOKEN="):
                return line.split("=", 1)[1].strip()
    raise CfError(f"no CF_API_TOKEN in {TOKEN_FILE}")


TOK = None


def api(method: str, path: str, body=None):
    global TOK
    TOK = TOK or token()
    req = urllib.request.Request(API + path, method=method, data=None if body is None else json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {TOK}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            d = json.load(r)
    except urllib.error.HTTPError as e:
        try:
            d = json.load(e)
        except Exception:
            raise CfError(f"{method} {path}: HTTP {e.code}")
    if not d.get("success", False):
        errs = "; ".join(f"{x.get('code')}: {x.get('message')}" for x in d.get("errors") or []) or "unknown error"
        raise CfError(f"{method} {path.split('?')[0]}: {errs}")
    return d.get("result")


def mask(e: str) -> str:
    u, _, d = e.partition("@")
    return f"{u[:1]}***@{d}"


def emails() -> list:
    with open(EMAILS_FILE) as f:
        es = [l.strip().lower() for l in f if l.strip() and not l.startswith("#")]
    bad = [e for e in es if not re.fullmatch(r"[^@\s]+@[^@\s]+\.[a-z]{2,}", e)]
    if bad or not 1 <= len(es) <= 10:
        raise CfError(f"{EMAILS_FILE}: need 1-10 valid addresses, one per line ({len(bad)} invalid)")
    return sorted(set(es))


def zone():
    z = api("GET", f"/zones?name={ZONE}")
    if len(z) != 1:
        raise CfError(f"zone {ZONE} not visible to the token")
    return z[0]["id"], z[0]["account"]["id"]


def team(acc):
    try:
        return api("GET", f"/accounts/{acc}/access/organizations")["auth_domain"]
    except (CfError, TypeError, KeyError):
        return None


def find_tunnel(acc):
    ts = api("GET", f"/accounts/{acc}/cfd_tunnel?name={TUNNEL}&is_deleted=false")
    return ts[0] if ts else None


def record(zid):
    rs = api("GET", f"/zones/{zid}/dns_records?name={HOST}")
    if len(rs) > 1:
        raise CfError(f"{len(rs)} records for {HOST}; expected one (left unchanged)")
    return rs[0] if rs else None


def fmt_rec(r):
    return "none" if not r else f"{r['type']} {r['content']} ({'proxied' if r['proxied'] else 'DNS only'})"


def by_name(items, name):
    return next((x for x in items or [] if x.get("name") == name), None)


# ---------------------------------------------------------------------------------------------------------------
def check():
    v = api("GET", "/user/tokens/verify")
    print(f"ok    token status: {v.get('status')}")
    zid, acc = zone()
    print(f"ok    zone {ZONE} visible; account found")
    t = team(acc)
    print(f"ok    Zero Trust team domain: {t}" if t else
          "FAIL  no Zero Trust organisation (dashboard -> Zero Trust: choose a team name, Free plan) or no Access permission")
    tn = find_tunnel(acc)
    print(f"ok    tunnel permission; tunnel '{TUNNEL}': {tn['id'] + ' (' + tn.get('status', '?') + ')' if tn else 'not created yet'}")
    apps = api("GET", f"/accounts/{acc}/access/apps")
    mine = [a["name"] for a in apps or [] if a.get("name") in (APP, APP_HEALTH)]
    print(f"ok    Access apps permission; StockPulse apps: {', '.join(mine) or 'none yet'}")
    print(f"ok    DNS {HOST}: {fmt_rec(record(zid))}")
    if os.path.exists(EMAILS_FILE):
        print(f"ok    allow-list: {', '.join(mask(e) for e in emails())}")
    else:
        print(f"FAIL  {EMAILS_FILE} missing (16-tunnel.sh emails-install)")
    return 0 if t else 1


def upsert_policy(acc, name, decision, include):
    body = {"name": name, "decision": decision, "include": include, "exclude": [], "require": []}
    if decision == "allow":
        body["session_duration"] = SESSION
    cur = by_name(api("GET", f"/accounts/{acc}/access/policies"), name)
    if cur:
        return api("PUT", f"/accounts/{acc}/access/policies/{cur['id']}", body)["id"]
    return api("POST", f"/accounts/{acc}/access/policies", body)["id"]


def upsert_app(acc, name, domain, policy_id, idp):
    body = {"name": name, "type": "self_hosted", "domain": domain, "session_duration": SESSION,
            "allowed_idps": [idp], "auto_redirect_to_identity": True, "app_launcher_visible": False,
            "http_only_cookie_attribute": True, "policies": [{"id": policy_id, "precedence": 1}]}
    cur = by_name(api("GET", f"/accounts/{acc}/access/apps"), name)
    if cur:
        return api("PUT", f"/accounts/{acc}/access/apps/{cur['id']}", body)
    return api("POST", f"/accounts/{acc}/access/apps", body)


def access_setup():
    _, acc = zone()
    t = team(acc)
    if not t:
        raise CfError("no Zero Trust organisation: create it in the dashboard first (see docs/external-access.md)")
    es = emails()
    idps = api("GET", f"/accounts/{acc}/access/identity_providers")
    otp = next((i for i in idps or [] if i.get("type") == "onetimepin"), None)
    if not otp:
        otp = api("POST", f"/accounts/{acc}/access/identity_providers", {"name": "One-time PIN", "type": "onetimepin", "config": {}})
        print("ok    created login method: e-mail one-time PIN")
    else:
        print("ok    login method: e-mail one-time PIN (exists)")
    allow = upsert_policy(acc, POL_ALLOW, "allow", [{"email": {"email": e}} for e in es])
    bypass = upsert_policy(acc, POL_BYPASS, "bypass", [{"everyone": {}}])
    print(f"ok    policies: allow {', '.join(mask(e) for e in es)}; bypass everyone on {HEALTH} only")
    a = upsert_app(acc, APP, HOST, allow, otp["id"])
    h = upsert_app(acc, APP_HEALTH, HOST + HEALTH, bypass, otp["id"])
    print(f"ok    Access app '{a['name']}' -> {a['domain']} (session {a.get('session_duration')}, login at {t})")
    print(f"ok    Access app '{h['name']}' -> {h['domain']} (bypass)")
    return 0


def tunnel_create(out):
    zid, acc = zone()
    if find_tunnel(acc):
        raise CfError(f"tunnel '{TUNNEL}' already exists; its secret cannot be read back. Use the existing "
                      "credentials file, or teardown and create again")
    sec = base64.b64encode(secrets.token_bytes(32)).decode()
    t = api("POST", f"/accounts/{acc}/cfd_tunnel", {"name": TUNNEL, "config_src": "local", "tunnel_secret": sec})
    tmp = out + ".new"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump({"AccountTag": acc, "TunnelID": t["id"], "TunnelSecret": sec}, f)
    os.replace(tmp, out)
    print(f"ok    tunnel '{TUNNEL}' created: {t['id']}; credentials written to {out}")
    return 0


def tunnel_id():
    _, acc = zone()
    t = find_tunnel(acc)
    print(t["id"] if t else "")
    return 0


def tunnel_status():
    _, acc = zone()
    t = find_tunnel(acc)
    if not t:
        print("FAIL  no tunnel"); return 1
    conns = api("GET", f"/accounts/{acc}/cfd_tunnel/{t['id']}/connections") or []
    n = sum(len(c.get("conns") or []) for c in conns)
    cols = sorted({x.get("colo_name") for c in conns for x in c.get("conns") or []})
    st = t.get("status")
    print(("ok    " if st == "healthy" and n else "FAIL  ") + f"tunnel {t['id']}: {st}, {n} connection(s) {' '.join(cols)}")
    return 0 if st == "healthy" and n else 1


def dns_show():
    zid, _ = zone()
    print(f"{HOST}: {fmt_rec(record(zid))}")
    return 0


def put_record(zid, cur, body):
    if cur and cur["type"] == body["type"]:
        return api("PATCH", f"/zones/{zid}/dns_records/{cur['id']}", body)
    try:  # type change in place (one call, no gap)
        return api("PATCH", f"/zones/{zid}/dns_records/{cur['id']}", body) if cur else api("POST", f"/zones/{zid}/dns_records", body)
    except CfError as e:
        print(f"note  in-place type change refused ({e}); replacing the record (a few seconds without it)")
        api("DELETE", f"/zones/{zid}/dns_records/{cur['id']}")
        return api("POST", f"/zones/{zid}/dns_records", body)


def dns_switch():
    zid, acc = zone()
    t = find_tunnel(acc)
    if not t:
        raise CfError("no tunnel")
    if not by_name(api("GET", f"/accounts/{acc}/access/apps"), APP):
        raise CfError("Access app missing: refusing to publish the name without its login policy (access-setup first)")
    target = f"{t['id']}.cfargotunnel.com"
    cur = record(zid)
    if cur and cur["type"] == "CNAME" and cur["content"] == target and cur["proxied"]:
        print(f"ok    {HOST} already -> tunnel"); return 0
    r = put_record(zid, cur, {"type": "CNAME", "name": HOST, "content": target, "proxied": True, "ttl": 1,
                              "comment": "StockPulse via Cloudflare Tunnel + Access (16-tunnel.sh); rollback: dns-rollback"})
    print(f"ok    {HOST}: {fmt_rec(cur)} -> {fmt_rec(r)}")
    return 0


def dns_rollback():
    zid, _ = zone()
    cur = record(zid)
    if cur and cur["type"] == "A" and cur["content"] == LAN_IP and not cur["proxied"]:
        print(f"ok    {HOST} already A {LAN_IP} (DNS only)"); return 0
    r = put_record(zid, cur, {"type": "A", "name": HOST, "content": LAN_IP, "proxied": False, "ttl": 1,
                              "comment": "dsserver LAN HTTPS (proxy/Caddyfile); DNS only"})
    print(f"ok    {HOST}: {fmt_rec(cur)} -> {fmt_rec(r)}")
    return 0


def teardown():
    zid, acc = zone()
    cur = record(zid)
    if cur and cur["type"] == "CNAME":
        raise CfError("DNS still points to the tunnel: dns-rollback first")
    apps = api("GET", f"/accounts/{acc}/access/apps")
    for n in (APP_HEALTH, APP):
        a = by_name(apps, n)
        if a:
            api("DELETE", f"/accounts/{acc}/access/apps/{a['id']}"); print(f"ok    deleted Access app '{n}'")
    pols = api("GET", f"/accounts/{acc}/access/policies")
    for n in (POL_BYPASS, POL_ALLOW):
        p = by_name(pols, n)
        if p:
            api("DELETE", f"/accounts/{acc}/access/policies/{p['id']}"); print(f"ok    deleted policy '{n}'")
    t = find_tunnel(acc)
    if t:
        api("DELETE", f"/accounts/{acc}/cfd_tunnel/{t['id']}"); print(f"ok    deleted tunnel {t['id']}")
    return 0


def main():
    cmds = {"check": check, "access-setup": access_setup, "tunnel-id": tunnel_id, "tunnel-status": tunnel_status,
            "dns-show": dns_show, "dns-switch": dns_switch, "dns-rollback": dns_rollback, "teardown": teardown}
    a = sys.argv[1:]
    try:
        if len(a) == 2 and a[0] == "tunnel-create":
            return tunnel_create(a[1])
        if len(a) == 1 and a[0] in cmds:
            return cmds[a[0]]()
    except CfError as e:
        print(f"FAIL  {e}"); return 1
    except OSError as e:
        print(f"FAIL  {type(e).__name__}: {e}"); return 1
    print(__doc__); return 2


if __name__ == "__main__":
    sys.exit(main())
