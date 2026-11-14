#!/usr/bin/env python3
"""Operational check of dsnas (read-only, plus one small round-trip file in `exchange`).
Usage: python3 -I dsnas-check.py [--no-smb]
Needs: ~/.config/nas/dsnas-setup.cred (DSM admin, for read-only API calls) and ~/.config/nas/dsnas-accounts.cred
(service-account passwords, for SMB tests). Prints no secrets. Exit 1 if any check fails."""
import os, sys, json, time, hashlib, subprocess, tempfile, datetime
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dsm import DSM

HOST = "192.168.68.112"
# intended state (report section 2)
SHARES = {  # name: (checksums, hidden, snapshot hour:min, retention advPolicyType bits, daily, weekly, monthly)
    "photos":        (True,  False, (3, 0),  29, 14, 8, 12),
    "family":        (True,  False, (3, 10), 13, 14, 8, 0),
    "media":         (True,  False, (3, 20), 13, 7, 4, 0),
    "replay-backup": (True,  True,  (5, 0),  5,  14, 0, 0),
    "server-backup": (True,  True,  (3, 30), 13, 14, 8, 0),
    "exchange":      (False, False, None,    None, 0, 0, 0),
}
# cert-deploy (dedicated admin for certificate import, docs/internal-https.md) is explicitly denied every share.
PERMS = {
    "photos":        {"cert-deploy": "NA", "@administrators": "RW", "@family": "RW"},
    "family":        {"cert-deploy": "NA", "@administrators": "RW", "@family": "RW"},
    "media":         {"cert-deploy": "NA", "@administrators": "RW", "@family": "RO", "media": "RO"},
    "replay-backup": {"cert-deploy": "NA", "@administrators": "RW", "replay": "RW"},
    "server-backup": {"cert-deploy": "NA", "@administrators": "RW", "dsserver-backup": "RW"},
    "exchange":      {"cert-deploy": "NA", "@administrators": "RW", "@family": "RW"},
}
# SMB matrix: account -> share -> expected ("RW" | "RO" | "NA")
SMB = {
    "family":          {"photos": "RW", "family": "RW", "media": "RO", "exchange": "RW", "replay-backup": "NA", "server-backup": "NA"},
    "media":           {"photos": "NA", "family": "NA", "media": "RO", "exchange": "NA", "replay-backup": "NA", "server-backup": "NA"},
    "replay":          {"photos": "NA", "family": "NA", "media": "NA", "exchange": "NA", "replay-backup": "RW", "server-backup": "NA"},
    "dsserver-backup": {"photos": "NA", "family": "NA", "media": "NA", "exchange": "NA", "replay-backup": "NA", "server-backup": "RW"},
}
fails = []
def check(ok, msg):
    print(("ok   " if ok else "FAIL ") + msg)
    if not ok: fails.append(msg)

def api_checks():
    with DSM(HOST) as d:
        for name, (cow, hidden, snap, bits, dly, wk, mon) in SHARES.items():
            g = d.call("SYNO.Core.Share", 1, "get", name=name, additional='["enable_share_cow","hidden"]')["data"]
            check(g.get("enable_share_cow") == cow, f"{name}: data checksums {'on' if cow else 'off'}")
            check(bool(g.get("hidden")) == hidden, f"{name}: hidden={hidden}")
            got = {}
            for t in ("local_user", "local_group"):
                r = d.call("SYNO.Core.Share.Permission", 1, "list", name=name, user_group_type=t, offset=0, limit=200, action="enum")
                for x in r["data"]["items"]:
                    p = "RW" if x.get("is_writable") else "RO" if x.get("is_readonly") else "NA" if x.get("is_deny") else None
                    if p: got[("@" if t == "local_group" else "") + x["name"]] = p
            check(got == PERMS[name], f"{name}: share permissions {got}")
            if snap is None:
                continue
            s = d.call("SYNO.Core.Share.Snapshot", 1, "get_schedule", name=name)["data"]
            sc = s.get("schedule", {})
            check(s.get("enable_snapshot_schedule") and (sc.get("hour"), sc.get("min")) == snap and sc.get("week_name") == "0,1,2,3,4,5,6",
                  f"{name}: daily snapshot schedule {snap[0]:02d}:{snap[1]:02d}")
            r = d.call("SYNO.DisasterRecovery.Retention", 1, "get", type="Share", name=name)["data"]
            check((r.get("policyType"), r.get("advPolicyType"), r.get("advDaily"), r.get("advWeekly"), r.get("advMonthly")) == (128, bits, dly, wk, mon),
                  f"{name}: retention daily {dly} weekly {wk} monthly {mon}")
            snaps = d.call("SYNO.Core.Share.Snapshot", 2, "list", name=name, additional='["desc","lock","schedule_snapshot"]')["data"]["snapshots"]
            times = sorted(x["time"] for x in snaps)
            if times:
                last = datetime.datetime.strptime(times[-1].split("-", 1)[1], "%Y.%m.%d-%H.%M.%S")
                age_h = (datetime.datetime.now() - last).total_seconds() / 3600
                check(age_h < 26, f"{name}: {len(times)} snapshot(s), newest {last:%Y-%m-%d %H:%M} ({age_h:.1f} h old)")
            else:
                check(False, f"{name}: no snapshots")
        t = d.call("SYNO.Core.Terminal", 3, "get")["data"]
        check(not t["enable_ssh"] and not t["enable_telnet"], f"SSH {'on' if t['enable_ssh'] else 'off'}, Telnet {'on' if t['enable_telnet'] else 'off'}")

def smb_try(acct, pw, share, write):
    with tempfile.TemporaryDirectory() as td:
        auth = os.path.join(td, "a"); fd = os.open(auth, os.O_WRONLY | os.O_CREAT, 0o600)
        os.write(fd, f"username={acct}\npassword={pw}\n".encode()); os.close(fd)
        base = ["smbclient", "-A", auth, "-m", "SMB3", f"//{HOST}/{share}"]
        r = subprocess.run(base + ["-c", "ls"], capture_output=True, text=True, timeout=60)
        if r.returncode != 0:
            return "NA"
        if not write:
            return "R?"
        name = f".dsnas-check-{acct}-{os.getpid()}"
        src = os.path.join(td, "src"); dst = os.path.join(td, "dst")
        data = os.urandom(256 * 1024); open(src, "wb").write(data)
        r = subprocess.run(base + ["-c", f'put "{src}" "{name}"'], capture_output=True, text=True, timeout=60)
        if r.returncode != 0 or "NT_STATUS" in r.stdout + r.stderr:
            return "RO"
        subprocess.run(base + ["-c", f'get "{name}" "{dst}"'], capture_output=True, text=True, timeout=60)
        same = os.path.exists(dst) and hashlib.sha256(open(dst, "rb").read()).digest() == hashlib.sha256(data).digest()
        subprocess.run(base + ["-c", f'del "{name}"'], capture_output=True, text=True, timeout=60)
        # exchange has a recycle bin: remove our test file from it as well
        subprocess.run(base + ["-c", f'del "#recycle/{name}"'], capture_output=True, text=True, timeout=60)
        gone = "NT_STATUS_NO_SUCH_FILE" in subprocess.run(base + ["-c", f'ls "{name}"'], capture_output=True, text=True, timeout=60).stdout
        return "RW" if same and gone else "RW-BROKEN"

def smb_checks():
    pw = dict(l.rstrip("\n").split("=", 1) for l in open(os.path.expanduser("~/.config/nas/dsnas-accounts.cred")) if "=" in l)
    for acct, row in SMB.items():
        for share, want in row.items():
            # write tests only where we expect write access and where a temp file is harmless (exchange); elsewhere read-level only
            write = want == "RW" and share == "exchange"
            got = smb_try(acct, pw[acct], share, write)
            if want == "RW" and not write:
                got = "RW" if got == "R?" else got   # write access on these shares is proven by the ACL check above
            elif want == "RO":
                got = "RO" if got == "R?" else got
            check(got == want, f"SMB {acct:15} -> {share:13} expected {want}, got {got}")
    del pw

if __name__ == "__main__":
    api_checks()
    if "--no-smb" in sys.argv:
        pass
    elif not os.path.exists(os.path.expanduser("~/.config/nas/dsnas-accounts.cred")):
        print("info SMB matrix skipped: ~/.config/nas/dsnas-accounts.cred not present (passwords are in Bitwarden)")
    else:
        smb_checks()
    print(f"\n{'PASS' if not fails else 'FAIL'}: {len(fails)} failure(s)")
    sys.exit(1 if fails else 0)
