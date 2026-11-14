#!/usr/bin/env python3
"""Minimal DNS query tool (stdlib only, for hosts without dig).
Usage: dnsq.py SERVER NAME [TYPE] [--tcp]   TYPE: A (default), AAAA, PTR, TXT, SOA, CNAME
Prints: RCODE then one line per answer record (type and data), e.g. 'NOERROR' / 'A 192.168.68.112'.
Exit 0 if a response arrived (any RCODE), 2 on timeout/error."""
import socket, struct, sys, random, ipaddress
TYPES = {"A": 1, "NS": 2, "CNAME": 5, "SOA": 6, "PTR": 12, "TXT": 16, "AAAA": 28}
RCODES = {0: "NOERROR", 1: "FORMERR", 2: "SERVFAIL", 3: "NXDOMAIN", 4: "NOTIMP", 5: "REFUSED"}
def qname(n): return b"".join(bytes([len(p)]) + p.encode() for p in n.rstrip(".").split(".")) + b"\0"
def rname(msg, off):
    labels, jumped, end = [], False, off
    while True:
        l = msg[off]
        if l & 0xC0 == 0xC0:
            if not jumped: end = off + 2
            off = struct.unpack("!H", msg[off:off+2])[0] & 0x3FFF; jumped = True; continue
        if l == 0:
            if not jumped: end = off + 1
            return ".".join(labels), end
        labels.append(msg[off+1:off+1+l].decode(errors="replace")); off += l + 1
def query(server, name, rtype="A", tcp=False, timeout=3.0):
    if rtype == "PTR" and name.replace(".", "").isdigit():
        name = ipaddress.ip_address(name).reverse_pointer
    tid = random.randint(0, 65535)
    pkt = struct.pack("!HHHHHH", tid, 0x0100, 1, 0, 0, 0) + qname(name) + struct.pack("!HH", TYPES[rtype], 1)
    fam = socket.AF_INET6 if ":" in server else socket.AF_INET
    with socket.socket(fam, socket.SOCK_STREAM if tcp else socket.SOCK_DGRAM) as s:
        s.settimeout(timeout)
        if tcp:
            s.connect((server, 53)); s.sendall(struct.pack("!H", len(pkt)) + pkt)
            ln = struct.unpack("!H", s.recv(2))[0]; msg = b""
            while len(msg) < ln: msg += s.recv(ln - len(msg))
        else:
            s.sendto(pkt, (server, 53)); msg = s.recv(4096)
    rid, flags, qd, an, ns, ar = struct.unpack("!HHHHHH", msg[:12])
    if rid != tid: raise RuntimeError("id mismatch")
    off = 12
    for _ in range(qd): _, off = rname(msg, off); off += 4
    out = []
    for _ in range(an):
        _, off = rname(msg, off); t, c, ttl, rl = struct.unpack("!HHIH", msg[off:off+10]); off += 10; rd = msg[off:off+rl]
        if t == 1: data = socket.inet_ntop(socket.AF_INET, rd)
        elif t == 28: data = socket.inet_ntop(socket.AF_INET6, rd)
        elif t in (5, 12, 2): data = rname(msg, off)[0]
        elif t == 16: data = rd[1:1+rd[0]].decode(errors="replace")
        else: data = rd.hex()
        out.append((next((k for k, v in TYPES.items() if v == t), str(t)), data)); off += rl
    return RCODES.get(flags & 0xF, str(flags & 0xF)), out
if __name__ == "__main__":
    a = [x for x in sys.argv[1:] if not x.startswith("--")]
    try:
        rc, ans = query(a[0], a[1], a[2].upper() if len(a) > 2 else "A", "--tcp" in sys.argv)
    except Exception as e:
        print(f"ERROR {e}"); sys.exit(2)
    print(rc)
    for t, d in ans: print(t, d)
