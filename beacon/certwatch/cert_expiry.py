#!/usr/bin/env python3
"""Certificate check for the internal HTTPS names, run on Beacon (independent of dsserver, which renews them).
For each name: connect to its LAN address (no DNS dependency), validate chain + hostname against the system CA store,
require >= MIN_DAYS left. Exit 1 on any certificate problem -> unit fails -> Beszel SystemdFailed (beacon) -> ntfy.
A host that does not answer at all is reported but not counted: reachability has its own alerts (Beszel Status),
so one outage does not raise two alerts. Design: /srv/stacks/docs/internal-https.md."""
import socket, ssl, sys, time
import os
MIN_DAYS = 21
SIMULATE = "/etc/beacon-certwatch/simulate-expiry"   # alert drill: root creates it -> every certificate counts as expiring
if os.path.exists(SIMULATE):
    MIN_DAYS = 400
    print(f"SIMULATION: threshold raised to {MIN_DAYS} days (alert drill; remove {SIMULATE})")
TARGETS = [  # (name, address, port)
    ("dsnas.rubusdua.net", "192.168.68.112", 443),
    ("dsserver.rubusdua.net", "192.168.68.115", 443),
    ("beacon.rubusdua.net", "127.0.0.1", 443),
]
problems = []
for name, addr, port in TARGETS:
    try:
        sock = socket.create_connection((addr, port), 10)
    except OSError as e:
        print(f"skip  {name}: {addr}:{port} not reachable ({e.__class__.__name__}); reachability is alerted elsewhere")
        continue
    try:
        with ssl.create_default_context().wrap_socket(sock, server_hostname=name) as t:
            c = t.getpeercert()
        days = (ssl.cert_time_to_seconds(c["notAfter"]) - time.time()) / 86400
        issuer = dict(x[0] for x in c["issuer"]).get("commonName")
        line = f"{name}: trusted ({issuer}), {days:.0f} days left"
        if days < MIN_DAYS:
            problems.append(f"{name} expires in {days:.0f} days (renewal or deployment is failing)")
            print("FAIL  " + line)
        else:
            print("ok    " + line)
    except ssl.SSLCertVerificationError as e:
        problems.append(f"{name}: certificate not trusted ({e.verify_message})"); print(f"FAIL  {name}: {e.verify_message}")
    except (OSError, ssl.SSLError) as e:
        problems.append(f"{name}: TLS error {e.__class__.__name__}"); print(f"FAIL  {name}: TLS error {e}")
if problems:
    print("PROBLEMS: " + "; ".join(problems)); sys.exit(1)
