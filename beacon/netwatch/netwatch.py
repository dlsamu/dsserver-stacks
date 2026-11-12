#!/usr/bin/python3 -I
"""netwatch: long-term network outage history for Beacon, built from Beszel's own network checks.

Beszel keeps 1-minute check results for one hour only. `collect` (systemd timer, every 30 min, as root on
Beacon) copies them from the hub's local API into /srv/appdata/netwatch/netwatch.db (kept 180 days); `report`
turns them into classified incidents and latency/loss trends. It probes nothing itself and sends no
notifications (alerts stay with Beszel -> ntfy), so it adds no network load and no notification storms.

  netwatch.py collect                     fetch the last 70 min of 1-minute results (idempotent)
  netwatch.py report [--days N] [--all]   incidents (default 7 days); --all includes 1-minute blips
  netwatch.py trend [--days N]            per day and check: samples, loss %, average response
  netwatch.py status                      last collection, rows, checks and their roles

Classification of a failing minute (first match wins; every failing check is listed too):
  no data            no result at all (Beacon, its agent or the hub was down: Beacon is blind)
  LAN/gateway        Deco gateway 192.168.68.1 does not answer ping (or Beacon's own link is down)
  internet (WAN)     gateway ok, 1.1.1.1 and 9.9.9.9 both lost
  DNS upstream       pings ok, DNS fails through the Deco AND through 9.9.9.9
  Deco DNS           only DNS through the Deco fails
  public DNS 9.9.9.9 only DNS through 9.9.9.9 fails
  single WAN path    only one of 1.1.1.1 / 9.9.9.9 lost (provider/path problem, internet mostly fine)
  external HTTPS     pings and DNS ok, an external HTTPS check fails (that site, or TLS/HTTP filtering)
  dsserver down      dsserver does not answer ping (host, its network link or LAN)
  dsserver HTTPS     dsserver pings, but TCP 443 (Caddy) refuses/times out
  StockPulse web     dsserver HTTPS reachable, StockPulse /healthz fails (since 2026-11-12 checked over the
                    internet: Cloudflare -> tunnel -> Caddy -> app; tunnel down shows up here)
Stdlib only. The automation account's password is read from /root/beszel-automation/credentials and never printed.
"""
import argparse, json, os, sqlite3, sys, time, urllib.error, urllib.parse, urllib.request
from datetime import datetime

HUB = "http://127.0.0.1:8090"
CRED = "/root/beszel-automation/credentials"
DB = os.environ.get("NETWATCH_DB", "/srv/appdata/netwatch/netwatch.db")
KEEP_DAYS = 180
MIN = 60_000

# (role, protocol, target, port, server) -> how a Beszel check is interpreted. Unknown checks get role "other".
ROLES = [
    ("gateway",       "icmp", "192.168.68.1", None, None),
    ("wan_cf",        "icmp", "1.1.1.1", None, None),
    ("wan_q9",        "icmp", "9.9.9.9", None, None),
    ("dns_local",     "dns", None, None, "192.168.68.1"),
    ("dns_public",    "dns", None, None, "9.9.9.9"),
    ("https_debian",  "http", "https://deb.debian.org/", None, None),
    ("https_google",  "http", "https://www.google.com/generate_204", None, None),
    ("dsserver_icmp", "icmp", "192.168.68.115", None, None),
    ("dsserver_tcp",  "tcp", "192.168.68.115", 443, None),
    ("stockpulse",    "http", "https://stockpulse.rubusdua.net/healthz", None, None),
]


def role_of(m: dict) -> str:
    for role, proto, target, port, server in ROLES:
        if (m.get("protocol") == proto and (target is None or m.get("target") == target)
                and (port is None or int(m.get("port") or 0) == port)
                and (server is None or (m.get("server") or "") == server)):
            return role
    return "other"


def classify(failing: set, known: set) -> str:
    """Primary class of one minute. failing/known: roles with a failed / any result in that minute."""
    if not known:
        return "no data"
    f = failing
    if "gateway" in f:
        return "LAN/gateway"
    if {"wan_cf", "wan_q9"} <= f:
        return "internet (WAN)"
    if {"dns_local", "dns_public"} <= f:
        return "DNS upstream"
    if "dns_local" in f:
        return "Deco DNS"
    if "dns_public" in f:
        return "public DNS 9.9.9.9"
    if f & {"wan_cf", "wan_q9"}:
        return "single WAN path"
    if f & {"https_debian", "https_google"}:
        return "external HTTPS"
    if "dsserver_icmp" in f:
        return "dsserver down"
    if "dsserver_tcp" in f:
        return "dsserver HTTPS"
    if "stockpulse" in f:
        return "StockPulse web"
    if f:
        return "other check"
    return "ok"


# ── storage ──────────────────────────────────────────────────────────────────

def db() -> sqlite3.Connection:
    c = sqlite3.connect(DB)
    c.executescript("""
        create table if not exists minute(monitor text, ts integer, success integer, total integer, res_avg integer,
                                          primary key(monitor, ts));
        create table if not exists monitor(id text primary key, role text, protocol text, target text, port integer,
                                           server text, interval integer, enabled integer, seen integer);
        create table if not exists meta(k text primary key, v text);
    """)
    return c


# ── hub API ──────────────────────────────────────────────────────────────────

def api(path: str, token: str | None = None, body: dict | None = None):
    req = urllib.request.Request(HUB + path, method="POST" if body is not None else "GET",
                                 data=None if body is None else json.dumps(body).encode())
    req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", token)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read())


def login() -> str:
    d = {}
    with open(CRED) as f:
        for line in f:
            k, _, v = line.rstrip("\n").partition("=")
            d[k] = v
    try:
        return api("/api/collections/users/auth-with-password", body={"identity": d["email"], "password": d["password"]})["token"]
    except urllib.error.HTTPError as e:
        sys.exit(f"login failed: HTTP {e.code}")


def collect():
    t = login()
    mons = api("/api/collections/network_monitors/records?perPage=500", t)["items"]
    since = int(time.time() * 1000) - 70 * MIN
    rows, page = [], 1
    while True:
        q = urllib.parse.quote(f"type='1m' && created>={since}")
        r = api(f"/api/collections/network_monitor_stats/records?perPage=500&page={page}&sort=created&filter={q}", t)
        rows += r["items"]
        if page >= r.get("totalPages", 1):
            break
        page += 1
    c = db()
    now = int(time.time() * 1000)
    with c:
        c.execute("update monitor set enabled = 0")      # checks deleted in Beszel stay listed as disabled
        for m in mons:
            c.execute("insert or replace into monitor values(?,?,?,?,?,?,?,?,?)",
                      (m["id"], role_of(m), m.get("protocol"), m.get("target"), int(m.get("port") or 0),
                       m.get("server") or "", int(m.get("interval") or 60), int(bool(m.get("enabled"))), now))
        for s in rows:
            tot, ok = int(s.get("total_count") or 0), int(s.get("success_count") or 0)
            if tot <= 0:
                continue
            avg = int((s.get("res_sum") or 0) / ok) if ok else None
            c.execute("insert or replace into minute values(?,?,?,?,?)", (s["monitor"], int(s["created"]) // MIN * MIN, ok, tot, avg))
        c.execute("delete from minute where ts < ?", (now - KEEP_DAYS * 86400_000,))
        c.execute("insert or replace into meta values('last_collect', ?)", (str(now),))
    print(f"netwatch: {len(rows)} one-minute results from {len(mons)} checks stored")


# ── analysis ─────────────────────────────────────────────────────────────────

def minutes(c, start: int, end: int):
    """{minute: (failing roles, known roles)}; a result covers its check's interval (5-min DNS/HTTPS checks)."""
    mon = {i: (r, iv) for i, r, iv in c.execute("select id, role, interval from monitor")}
    state: dict[int, tuple[set, set]] = {}
    for m, ts, ok, tot in c.execute("select monitor, ts, success, total from minute where ts >= ? and ts < ? order by ts",
                                    (start - 10 * MIN, end)):
        role, iv = mon.get(m, ("other", 60))
        for k in range(max(1, iv // 60)):
            t = ts + k * MIN
            if start <= t < end:
                f, kn = state.setdefault(t, (set(), set()))
                kn.add(role)
                if ok < tot:
                    f.add(role)
    return state


def incidents(c, start: int, end: int, merge_gap: int = 2):
    st = minutes(c, start, end)
    out, cur = [], None
    first = min(st) if st else start
    for t in range(first // MIN * MIN, end // MIN * MIN, MIN):
        f, kn = st.get(t, (set(), set()))
        cls = classify(f, kn)
        if cls == "ok":
            continue
        if cur and cur["cls"] == cls and t - cur["end"] <= (merge_gap + 1) * MIN:
            cur["end"] = t
            cur["roles"] |= f
        else:
            cur = {"cls": cls, "start": t, "end": t, "roles": set(f)}
            out.append(cur)
    return out


def fmt(ms: int) -> str:
    return datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M")


def report(days: int, show_all: bool):
    c = db()
    newest = c.execute("select max(ts) from minute").fetchone()[0]
    end = (newest + MIN) if newest else int(time.time() * 1000)   # stop at the newest collected minute, not "now"
    inc = incidents(c, end - days * 86400_000, end)
    shown = [i for i in inc if show_all or (i["end"] - i["start"]) // MIN + 1 >= 2]
    last = c.execute("select v from meta where k='last_collect'").fetchone()
    print(f"netwatch incidents, last {days} day(s); data collected up to {fmt(int(last[0])) if last else 'never'}"
          f"{'' if show_all else '; 1-minute blips hidden (--all shows them)'}")
    print(f"{'start':16}  {'end':16}  {'min':>4}  {'class':20}  failing checks")
    for i in shown:
        d = (i["end"] - i["start"]) // MIN + 1
        print(f"{fmt(i['start'])}  {fmt(i['end'] + MIN)}  {d:4d}  {i['cls']:20}  {', '.join(sorted(i['roles'])) or '-'}")
    tot = {}
    for i in inc:
        tot[i["cls"]] = tot.get(i["cls"], 0) + (i["end"] - i["start"]) // MIN + 1
    print("total minutes per class: " + (", ".join(f"{k} {v}" for k, v in sorted(tot.items(), key=lambda kv: -kv[1])) or "none"))


def trend(days: int):
    c = db()
    since = int(time.time() * 1000) - days * 86400_000
    q = """select date(ts/1000,'unixepoch','localtime') d, m.role, m.target, sum(total), sum(total-success),
                  avg(res_avg) from minute x join monitor m on m.id = x.monitor where ts >= ?
           group by d, m.role order by d, m.role"""
    print(f"{'day':10}  {'check':14}  {'samples':>7}  {'loss %':>6}  {'avg ms':>7}")
    for d, role, target, tot, lost, avg in c.execute(q, (since,)):
        print(f"{d:10}  {role:14}  {tot:7d}  {100 * lost / tot:6.2f}  {(avg or 0) / 1000:7.1f}")


def status():
    c = db()
    last = c.execute("select v from meta where k='last_collect'").fetchone()
    n, lo = c.execute("select count(*), min(ts) from minute").fetchone()
    print(f"last collect: {fmt(int(last[0])) if last else 'never'}; {n} one-minute rows since {fmt(lo) if lo else '-'}; db {DB}")
    for i, role, p, t, port, srv, iv, en in c.execute("select id, role, protocol, target, port, server, interval, enabled from monitor order by role"):
        print(f"  {role:14} {i}  {p:4} {t}{':' + str(port) if port else ''}{' via ' + srv if srv else ''}  every {iv}s{'' if en else '  (disabled)'}")


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["collect", "report", "trend", "status"])
    p.add_argument("--days", type=int, default=7)
    p.add_argument("--all", action="store_true")
    a = p.parse_args()
    if a.mode == "collect":
        collect()
    elif a.mode == "report":
        report(a.days, a.all)
    elif a.mode == "trend":
        trend(a.days)
    else:
        status()


if __name__ == "__main__":
    main()
