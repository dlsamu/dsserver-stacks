#!/usr/bin/env python3
"""dsnas (Synology DS223j) health check, run on Beacon by dsnas-health.timer every 5 minutes.

Reads the Synology MIB over SNMPv3 (read-only user, authPriv; credentials only in /etc/dsnas-monitor/snmp.conf,
root 0600, never on the command line). Two consecutive failed runs -> exit 1 -> the unit fails -> Beszel's
"Failed systemd service" alert (beacon) -> ntfy. One bad run alone only logs (avoids alerts on a single blip).
Reachability itself is also covered by Beszel network monitors (ping, TCP 5001, TCP 445).
"""
import json, os, subprocess, sys, time

HOST = "192.168.68.112"
STATE = os.environ.get("STATE_DIRECTORY", "/var/lib/dsnas-health") + "/state.json"
ENV = dict(os.environ, SNMPCONFPATH="/etc/dsnas-monitor")
SYN = "1.3.6.1.4.1.6574"
RAID_BAD = {11: "degraded", 12: "crashed", 21: "unknown"}
RAID_NAMES = {1: "normal", 2: "repairing", 3: "migrating", 4: "expanding", 6: "creating", 7: "syncing",
              8: "parity checking", 13: "data scrubbing"}
MIN_FREE_PCT, MAX_DISK_C, MAX_SYS_C = 10.0, 55, 65


def walk(oid):
    out = subprocess.run(["snmpwalk", "-On", "-Oqv", "-t", "5", "-r", "2", HOST, oid], env=ENV,
                         capture_output=True, text=True, timeout=60)
    if out.returncode != 0 or not out.stdout.strip():
        raise RuntimeError(f"SNMP walk {oid} failed: {out.stderr.strip()[:200]}")
    return [v.strip().strip('"') for v in out.stdout.splitlines()]


def check():
    problems, info = [], {}
    sysst, temp, power = walk(f"{SYN}.1.1.0")[0], int(walk(f"{SYN}.1.2.0")[0]), walk(f"{SYN}.1.3.0")[0]
    fans = walk(f"{SYN}.1.4")
    info["system_temp_c"] = temp
    if sysst != "1": problems.append(f"system status {sysst} (not normal)")
    if power != "1": problems.append(f"power status {power} (not normal)")
    if any(f != "1" for f in fans): problems.append(f"fan status {fans}")
    if temp > MAX_SYS_C: problems.append(f"system temperature {temp} C")
    names, status, temps = walk(f"{SYN}.2.1.1.2"), walk(f"{SYN}.2.1.1.5"), walk(f"{SYN}.2.1.1.6")
    bad, health = walk(f"{SYN}.2.1.1.9"), walk(f"{SYN}.2.1.1.13")
    if len(names) != 2: problems.append(f"expected 2 disks, found {len(names)}")
    for i, n in enumerate(names):
        info[n] = {"status": status[i], "health": health[i], "temp_c": int(temps[i]), "bad_sectors": int(bad[i])}
        if status[i] != "1": problems.append(f"{n} status {status[i]} (not normal)")
        if health[i] != "1": problems.append(f"{n} health {health[i]} (1=normal 2=warning 3=critical 4=failing)")
        if int(bad[i]) > 0: problems.append(f"{n} has {bad[i]} bad sectors")
        if int(temps[i]) > MAX_DISK_C: problems.append(f"{n} temperature {temps[i]} C")
    rn, rs = walk(f"{SYN}.3.1.1.2"), [int(x) for x in walk(f"{SYN}.3.1.1.3")]
    free, total = [int(x) for x in walk(f"{SYN}.3.1.1.4")], [int(x) for x in walk(f"{SYN}.3.1.1.5")]
    for i, n in enumerate(rn):
        info[n] = {"status": RAID_NAMES.get(rs[i], str(rs[i]))}
        if rs[i] in RAID_BAD: problems.append(f"{n} is {RAID_BAD[rs[i]]}")
        if n.startswith("Volume") and total[i]:
            pct = 100.0 * free[i] / total[i]
            info[n]["free_pct"] = round(pct, 1)
            if pct < MIN_FREE_PCT: problems.append(f"{n} only {pct:.1f}% free")
    if not any(n.startswith("Storage Pool") for n in rn): problems.append("no storage pool reported")
    return problems, info


def main():
    try:
        problems, info = check()
    except Exception as e:
        problems, info = [f"cannot read dsnas health: {e}"], {}
    try:
        prev = json.load(open(STATE)).get("consecutive_failures", 0)
    except Exception:
        prev = 0
    fails = prev + 1 if problems else 0
    os.makedirs(os.path.dirname(STATE), exist_ok=True)
    json.dump({"time": time.strftime("%F %T"), "consecutive_failures": fails, "problems": problems, "info": info},
              open(STATE, "w"), indent=1)
    if problems:
        print(f"dsnas: {len(problems)} problem(s), run {fails} in a row: " + "; ".join(problems))
        sys.exit(1 if fails >= 2 else 0)
    print("dsnas OK " + json.dumps(info, separators=(",", ":")))


if __name__ == "__main__":
    main()
