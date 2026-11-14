#!/usr/bin/env python3
"""Generate and install the hostbackup systemd units for this host from hosts/<host>.toml [schedule].
Usage (root): install-units.py <path-of-hostbackup.py-as-installed>   (prints what it did)
Units: hostbackup@.service (template, instance = job) + hostbackup-<job>.timer per job; Persistent=true so a run
missed while the host was off happens at the next boot (and Healthchecks still notices if it never happens)."""
import os, subprocess, sys, tomllib
prog = sys.argv[1]
host = os.uname().nodename.split(".")[0]
conf = tomllib.load(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "hosts", f"{host}.toml"), "rb"))
U = "/etc/systemd/system"
service = f"""[Unit]
Description=hostbackup %i (restic to dsnas; backup/README.md)
After=network-online.target docker.service
Wants=network-online.target

[Service]
# exec, not oneshot: Beszel's agent ignores failed oneshot units, and a failure must reach SystemdFailed -> ntfy.
Type=exec
ExecStart=/usr/bin/python3 -I {prog} %i
RuntimeMaxSec=12h
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
PrivateTmp=yes
NoNewPrivileges=yes
"""
changed = []
def put(path, text):
    old = open(path).read() if os.path.exists(path) else None
    if old != text:
        open(path, "w").write(text); os.chmod(path, 0o644); changed.append(os.path.basename(path))
put(f"{U}/hostbackup@.service", service)
for job, cal in conf["schedule"].items():
    put(f"{U}/hostbackup-{job}.timer", f"""[Unit]
Description=hostbackup {job} schedule

[Timer]
OnCalendar={cal}
Persistent=true
Unit=hostbackup@{job}.service

[Install]
WantedBy=timers.target
""")
subprocess.run(["systemctl", "daemon-reload"], check=True)
for job in conf["schedule"]:
    subprocess.run(["systemctl", "enable", "--now", f"hostbackup-{job}.timer"], check=True, capture_output=True)
print("changed:", ", ".join(changed) or "nothing")
print(subprocess.run(["systemctl", "list-timers", "hostbackup-*", "--no-pager"], capture_output=True, text=True).stdout)
