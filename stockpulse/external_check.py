#!/usr/bin/python3 -I
"""StockPulse external check: the public path phone -> Cloudflare -> Access -> tunnel -> Caddy -> app, from dsserver.
Run every minute by stockpulse-external.timer via `15-stockpulse.sh external-check` (root, stdlib + dig + curl).

Each probe is independent of caches: the name is resolved fresh through PUBLIC resolvers (1.1.1.1, then 9.9.9.9;
never the Deco, never a kept-alive connection: every probe is a new curl process pinned to that answer).
A probe passes only if ALL hold:
  dns      the public answer is a public address (a LAN address = the public path is not in place)
  health   https://<host>/healthz -> 200, body "ok", header "server: cloudflare" (went through Cloudflare + tunnel)
  access   https://<host>/latest/us without a login -> 30x to https://*.cloudflareaccess.com/ (reports still protected)

Alarm with hysteresis (one alert and one recovery per incident, no flapping):
  FAIL_AFTER consecutive failed probes  -> exit 10: the caller starts stockpulse-external-alarm.service (fails, stays failed)
  RECOVER_AFTER consecutive good probes -> exit 11: the caller clears it (systemctl reset-failed)
  otherwise exit 0 (no change). State: <state>/external-history.json (last 20 probes), <state>/external-alarm.

  external_check.py --state DIR [--host H] [--simulate ok|fail] [--now EPOCH]
  external_check.py --state DIR --summary          (for the alarm unit's log: the recent probes and what to do)
"""
import argparse, ipaddress, json, os, subprocess, sys, time, urllib.parse

HOST = "stockpulse.rubusdua.net"
RESOLVERS = ("1.1.1.1", "9.9.9.9")
FAIL_AFTER, RECOVER_AFTER, KEEP = 3, 2, 20
EXIT_ALARM, EXIT_CLEAR = 10, 11


def resolve(host):
    for r in RESOLVERS:
        try:
            out = subprocess.run(["dig", "+short", "+time=3", "+tries=1", "A", host, f"@{r}"],
                                 capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.TimeoutExpired):
            continue
        ips = [l for l in out.split() if l.count(".") == 3 and l.replace(".", "").isdigit()]
        if ips:
            return ips[0], r
    return None, None


def curl(host, ip, path):
    """-> (http_code, server_header, redirect_url, body). New process = new connection, pinned to ip."""
    try:
        p = subprocess.run(["curl", "-s", "-q", "--max-time", "15", "--connect-timeout", "8", "--resolve", f"{host}:443:{ip}",
                            "-D", "/dev/stderr", "-w", "\n%{http_code} %{redirect_url}", f"https://{host}{path}"],
                           capture_output=True, text=True, timeout=25)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 0, "", "", type(e).__name__
    body, _, tail = p.stdout.rpartition("\n")
    code, _, redirect = tail.partition(" ")
    server = next((l.split(":", 1)[1].strip() for l in p.stderr.splitlines() if l.lower().startswith("server:")), "")
    return int(code or 0), server.lower(), redirect.strip(), body


def probe(host):
    """-> (ok, reason). reason names the first failing layer, so the alert says where to look."""
    ip, via = resolve(host)
    if not ip:
        return False, f"dns: no answer for {host} from {' / '.join(RESOLVERS)} (dsserver internet or Cloudflare DNS)"
    if not ipaddress.ip_address(ip).is_global:
        return False, f"dns: {host} resolves publicly to {ip} (not Cloudflare: DNS rolled back or changed?)"
    code, server, _, body = curl(host, ip, "/healthz")
    if code != 200 or body.strip() != "ok":
        hint = {530: "tunnel down (connector stopped/unhealthy)", 502: "tunnel up, origin (Caddy/app) not answering",
                0: "no HTTPS answer (dsserver internet?)"}.get(code, "unexpected answer")
        return False, f"health: /healthz via {ip} -> HTTP {code} ({hint})"
    if server != "cloudflare":
        return False, f"health: /healthz answered by '{server}', not Cloudflare (not the public path)"
    code, _, redirect, _ = curl(host, ip, "/latest/us")
    login = urllib.parse.urlsplit(redirect)
    if not (300 <= code < 400 and login.scheme == "https" and (login.hostname or "").endswith(".cloudflareaccess.com")):
        return False, f"access: /latest/us without login -> HTTP {code} {redirect[:60]} (expected Access login: PROTECTION?)"
    return True, f"ok via {ip} (resolver {via}): healthz 200 through Cloudflare, reports behind Access"


def load(path):
    try:
        with open(path) as f:
            h = json.load(f)
        return h if isinstance(h, list) else []
    except (OSError, ValueError):
        return []


def save(path, h):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(h[-KEEP:], f)
    os.replace(tmp, path)


def decide(history, alarm_on):
    """Pure hysteresis: EXIT_ALARM, EXIT_CLEAR or 0."""
    last = [p["ok"] for p in history]
    if not alarm_on and len(last) >= FAIL_AFTER and not any(last[-FAIL_AFTER:]):
        return EXIT_ALARM
    if alarm_on and len(last) >= RECOVER_AFTER and all(last[-RECOVER_AFTER:]):
        return EXIT_CLEAR
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True)
    ap.add_argument("--host", default=HOST)
    ap.add_argument("--simulate", choices=("ok", "fail"))
    ap.add_argument("--now", type=float)
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args()
    hist_path, alarm = os.path.join(a.state, "external-history.json"), os.path.join(a.state, "external-alarm")
    h = load(hist_path)

    if a.summary:
        print(f"StockPulse EXTERNAL ACCESS FAILED: {FAIL_AFTER} probes in a row could not use https://{a.host} from the internet.")
        for p in h[-6:]:
            print(f"  {time.strftime('%H:%M:%S', time.localtime(p['t']))}  {'ok  ' if p['ok'] else 'FAIL'}  {p['reason']}")
        print("  what to check: `16-tunnel.sh status` (connector), `16-tunnel.sh verify`, Cloudflare dashboard (tunnel, Access, DNS).")
        print(f"  clears automatically after {RECOVER_AFTER} good probes in a row.")
        return 0

    test_flag = os.path.exists(os.path.join(a.state, "external-fail-test"))
    if a.simulate:
        ok, reason = a.simulate == "ok", f"simulated {a.simulate}"
    elif test_flag:
        ok, reason = False, "deliberate test failure (state/external-fail-test present; `15 external-test-clear`)"
    else:
        ok, reason = probe(a.host)
    h.append({"t": a.now or time.time(), "ok": ok, "reason": reason})
    save(hist_path, h)
    print(("ok    " if ok else "FAIL  ") + reason)

    d = decide(h, os.path.exists(alarm))
    if d == EXIT_ALARM:
        open(alarm, "w").close()
        print(f"ALARM: {FAIL_AFTER} failed probes in a row")
    elif d == EXIT_CLEAR:
        os.remove(alarm)
        print(f"RECOVERED: {RECOVER_AFTER} good probes in a row")
    return d


if __name__ == "__main__":
    sys.exit(main())
