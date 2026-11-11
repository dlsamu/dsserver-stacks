#!/usr/bin/python3 -I
"""Check Beszel through the HTTPS proxy. Stdlib only; prints no secrets.

  https_check.py NAME [--ip IP] [--port 443] [--insecure] [--login] [--min-days 14]

--ip      connect to this address instead of resolving NAME (SNI and Host stay NAME)
--insecure  skip certificate verification (only for the internal-CA proxy test)
--live    with --login: subscribe to "systems" (the dashboard's live view) and wait for a pushed update
--login   also sign in as the automation account (needs root on Beacon: /root/beszel-automation/credentials)

Checks: name resolution, TLS certificate (public trust chain, hostname, days left), dashboard page,
/api/health, live updates (server-sent events arrive unbuffered), WebSocket upgrade of the agent
endpoint (the hub's own answer arrives, not a proxy error), optionally login + an authenticated read.
"""
import argparse, http.client, json, os, socket, ssl, sys, time

FAILS = []
def ok(m): print("ok    " + m, flush=True)
def bad(m): print("FAIL  " + m, flush=True); FAILS.append(m)


class Conn(http.client.HTTPSConnection):
    def __init__(self, name, ip, port, ctx):
        super().__init__(name, port, context=ctx, timeout=10)
        self.ip = ip
    def connect(self):
        s = socket.create_connection((self.ip, self.port), self.timeout)
        self.sock = self._context.wrap_socket(s, server_hostname=self.host)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("name"); p.add_argument("--ip"); p.add_argument("--port", type=int, default=443)
    p.add_argument("--insecure", action="store_true"); p.add_argument("--login", action="store_true")
    p.add_argument("--min-days", type=int, default=14)
    p.add_argument("--live", action="store_true", help="with --login: wait for a pushed metrics update (up to 90 s)")
    a = p.parse_args()

    if a.ip:
        ip = a.ip
        print(f"info  connecting to {ip} (name resolution not tested)")
    else:
        try:
            ips = sorted({i[4][0] for i in socket.getaddrinfo(a.name, a.port, socket.AF_INET, socket.SOCK_STREAM)})
            ip = ips[0]
            ok(f"{a.name} resolves to {', '.join(ips)}")
        except OSError as e:
            bad(f"{a.name} does not resolve: {e}"); return finish()

    ctx = ssl.create_default_context()
    if a.insecure:
        ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
    conn = lambda: Conn(a.name, ip, a.port, ctx)

    # TLS + certificate
    try:
        c = conn(); c.connect()
        if not a.insecure:
            cert = c.sock.getpeercert()
            days = (ssl.cert_time_to_seconds(cert["notAfter"]) - time.time()) / 86400
            issuer = dict(x[0] for x in cert["issuer"])
            ok(f"certificate trusted, matches {a.name}; issuer {issuer.get('organizationName')} "
               f"{issuer.get('commonName')}; {c.sock.version()}")
            (ok if days >= a.min_days else bad)(f"certificate valid {days:.0f} more days (expires {cert['notAfter']})")
        else:
            print(f"info  certificate NOT verified (--insecure); {c.sock.version()}")
        c.close()
    except (ssl.SSLError, OSError) as e:
        bad(f"TLS to {a.name} via {ip}:{a.port}: {e}"); return finish()

    def req(method, path, body=None, headers=None):
        c = conn()
        c.request(method, path, body=None if body is None else json.dumps(body),
                  headers={"Content-Type": "application/json", **(headers or {})})
        r = c.getresponse(); data = r.read(); c.close()
        return r.status, r.getheader("Content-Type", ""), data

    st, ct, body = req("GET", "/")
    (ok if st == 200 and b"<html" in body.lower() else bad)(f"dashboard page: HTTP {st} {ct.split(';')[0]}")
    st, _, body = req("GET", "/api/health")
    (ok if st == 200 else bad)(f"/api/health: HTTP {st}")

    # Server-sent events (PocketBase realtime): the first event must arrive promptly through the proxy.
    try:
        c = conn(); c.request("GET", "/api/realtime", headers={"Accept": "text/event-stream"})
        r = c.getresponse(); t0 = time.time(); first = r.readline()
        okay = r.status == 200 and "event-stream" in (r.getheader("Content-Type") or "") and first.startswith(b"id:")
        (ok if okay else bad)(f"live updates (SSE): HTTP {r.status}, first event after {time.time()-t0:.1f}s")
        c.close()
    except (OSError, socket.timeout) as e:
        bad(f"live updates (SSE): {e}")

    # WebSocket upgrade of the agent endpoint, without credentials: the hub must answer itself
    # (it refuses an unauthenticated agent with 400, as on :8090 directly); 502/504 would mean the proxy
    # broke the upgrade. The full test is a real agent connecting through HTTPS (README "HTTPS").
    st, _, body = req("GET", "/api/beszel/agent-connect", headers={
        "Connection": "Upgrade", "Upgrade": "websocket", "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ=="})
    (ok if st in (101, 400, 401) else bad)(f"agent WebSocket endpoint answers through the proxy: HTTP {st}")

    if a.login:
        try:
            d = dict(l.rstrip("\n").split("=", 1) for l in open("/root/beszel-automation/credentials") if "=" in l)
        except OSError as e:
            bad(f"login: cannot read the automation credentials ({e.strerror})"); return finish()
        st, _, body = req("POST", "/api/collections/users/auth-with-password",
                          {"identity": d["email"], "password": d["password"]})
        if st != 200:
            bad(f"login as {d['email']}: HTTP {st}"); return finish()
        token = json.loads(body)["token"]
        ok(f"login as {d['email']} over HTTPS: HTTP 200")
        st, _, body = req("GET", "/api/collections/systems/records?fields=name,status", headers={"Authorization": token})
        items = json.loads(body).get("items", []) if st == 200 else []
        (ok if st == 200 and items else bad)(
            f"authenticated read: HTTP {st}, systems " + ", ".join(f"{i['name']}={i['status']}" for i in items))
        if a.live:
            live(conn, token)
    return finish()


def live(conn, token):
    """The dashboard's live metrics: authenticated realtime subscription; an agent update must arrive."""
    c = conn(); c.timeout = 100
    c.request("GET", "/api/realtime", headers={"Accept": "text/event-stream"})
    r = c.getresponse(); cid = None
    while cid is None:
        l = r.readline()
        if l.startswith(b"data:"):
            cid = json.loads(l[5:])["clientId"]
    c2 = conn(); c2.request("POST", "/api/realtime", body=json.dumps({"clientId": cid, "subscriptions": ["systems"]}),
                            headers={"Content-Type": "application/json", "Authorization": token})
    st = c2.getresponse().status; c2.close()
    if st != 204:
        bad(f"live metrics: subscribe HTTP {st}"); return
    t0 = time.time(); ev = None
    try:
        while time.time() - t0 < 90:
            l = r.readline()
            if l.startswith(b"event:systems"):
                ev = l
            elif ev and l.startswith(b"data:"):
                d = json.loads(l[5:]); rec = d.get("record", {})
                ok(f"live metrics pushed over HTTPS after {time.time()-t0:.0f}s: {rec.get('name')} {d.get('action')}, "
                   f"cpu {rec.get('info', {}).get('cpu')}%")
                c.close(); return
    except (OSError, socket.timeout):
        pass
    bad("live metrics: no system update within 90 s"); c.close()


def finish():
    print("HTTPS CHECK PASSED" if not FAILS else f"HTTPS CHECK FAILED ({len(FAILS)})")
    sys.exit(1 if FAILS else 0)


main()
