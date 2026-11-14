#!/usr/bin/env python3
"""Healthchecks.io checks for hostbackup jobs (one per host and job, cron schedule = the systemd timer, tz
Europe/Stockholm). Run on dsserver as root (delegated through host/scripts/19-backup.sh).
  hc_setup.py sync          create/update the checks (unique by name) and write the ping URLs:
                            dsserver /etc/dsserver-secrets/backup/healthchecks.json, Beacon via ssh (root 0600)
  hc_setup.py test-missed   create a temporary check (period 60 s, grace 60 s), ping once, wait until Healthchecks
                            reports it "down" (= the missed-run alert, sent by e-mail), then delete it
The project API key (read-write) is read from /etc/dsserver-secrets/backup/healthchecks-api-key and never printed."""
import json, os, re, subprocess, sys, time, tomllib, urllib.request
HERE = os.path.dirname(os.path.abspath(__file__))
KEY = open("/etc/dsserver-secrets/backup/healthchecks-api-key").read().strip()
API = "https://healthchecks.io/api/v3"
GRACE = {"backup": 5 * 3600, "check": 8 * 3600, "fullcheck": 14 * 3600, "prune": 6 * 3600, "drill": 6 * 3600}
DOW = {"Mon": 1, "Tue": 2, "Wed": 3, "Thu": 4, "Fri": 5, "Sat": 6, "Sun": 0}

def api(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"X-Api-Key": KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as r:
        raw = r.read(); return json.loads(raw) if raw else {}

def cron(cal):
    """systemd OnCalendar subset used in hosts/*.toml -> cron."""
    m = re.fullmatch(r"(?:(Mon|Tue|Wed|Thu|Fri|Sat|Sun) )?\*-\*-(\*|\d\d) (\d\d):(\d\d)", cal)
    if not m: raise SystemExit(f"unsupported OnCalendar {cal!r}")
    dow, dom, hh, mm = m.groups()
    return f"{int(mm)} {int(hh)} {'*' if dom == '*' else int(dom)} * {DOW[dow] if dow else '*'}"

def sync():
    for host in ("dsserver", "beacon"):
        conf = tomllib.load(open(f"{HERE}/hosts/{host}.toml", "rb"))
        urls = {}
        for job, cal in conf["schedule"].items():
            name = f"{host} hostbackup {job}"
            r = api("POST", "/checks/", {"name": name, "slug": f"{host}-hostbackup-{job}", "tags": f"hostbackup {host}",
                                         "desc": f"restic {job} of {host} to dsnas (/srv/stacks/backup/README.md)",
                                         "schedule": cron(cal), "tz": "Europe/Stockholm", "grace": GRACE[job],
                                         "channels": "*", "unique": ["name"]})
            urls[job] = r["ping_url"]
            print(f"ok    {name:32} cron '{cron(cal)}' grace {GRACE[job]//3600} h")
        data = json.dumps(urls)
        if host == "dsserver":
            fd = os.open("/etc/dsserver-secrets/backup/healthchecks.json.new", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            os.write(fd, data.encode()); os.close(fd)
            os.replace("/etc/dsserver-secrets/backup/healthchecks.json.new", "/etc/dsserver-secrets/backup/healthchecks.json")
        else:
            r = subprocess.run(["sudo", "-u", "daniel", "ssh", "beacon",
                                "sudo sh -c 'umask 077; cat > /etc/beacon-secrets/backup/healthchecks.json.new && "
                                "mv /etc/beacon-secrets/backup/healthchecks.json.new /etc/beacon-secrets/backup/healthchecks.json'"],
                               input=data, text=True, capture_output=True)
            if r.returncode != 0: raise SystemExit(f"could not write Beacon's healthchecks.json: {r.stderr.strip()[:200]}")
        print(f"ok    {host}: {len(urls)} ping URLs stored root-only")

def test_missed():
    c = api("POST", "/checks/", {"name": "hostbackup missed-run TEST (auto-deleted)", "timeout": 60, "grace": 60,
                                 "channels": "*", "tags": "test"})
    try:
        urllib.request.urlopen(urllib.request.Request(c["ping_url"], data=b"test", method="POST"), timeout=15).read()
        t0 = time.time(); print("info  pinged once; waiting for Healthchecks to mark it down (~2-3 min)")
        while time.time() - t0 < 420:
            time.sleep(20)
            st = api("GET", f"/checks/{c['uuid']}")["status"]
            if st == "down":
                print(f"ok    missed run detected: status 'down' after {time.time()-t0:.0f} s (alert e-mail sent)"); return
        raise SystemExit("FAILED: check never went down")
    finally:
        time.sleep(5); api("DELETE", f"/checks/{c['uuid']}"); print("ok    temporary check deleted")

if __name__ == "__main__":
    {"sync": sync, "test-missed": test_missed}.get(sys.argv[1] if len(sys.argv) > 1 else "", lambda: print(__doc__))()
