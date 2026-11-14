# dsnas monitoring (Beacon -> Beszel -> ntfy)

dsnas has two independent collectors, both reporting to Beacon:

1. **Beszel agent on dsnas** (SynoCommunity package "Beszel Agent" 0.21.1-3, installed 2026-11-14 by the owner via
   Package Center; built by SynoCommunity from the upstream henrygd/beszel source tag for `rtd1619b`).
   Runs as the unprivileged package user (DSM default; **not** changed to root). Listening mode: the hub on Beacon
   connects to `192.168.68.112:45876` and authenticates with the hub's SSH key (the agent only accepts that key).
   Configuration (set in the install wizard): `KEY=<hub public key>`, `EXTRA_FILESYSTEMS=/volume1`, no SMART devices.
   Beszel system `dsnas` (id `zsr6hzrri2il39f`). Updates: Package Center (Community); keep the agent version in step
   with the hub (`beacon/scripts/update-beszel.sh`).
2. **SNMPv3 health check on Beacon** (`beacon/nasmon/`, `dsnas-health.timer`, every 5 min, `Type=exec` since
   2026-11-14 so Beszel sees its failures (a failed `oneshot` was invisible), read-only user,
   Synology MIB). Owns everything storage/disk-specific. Only SNMP sees SMART-derived disk health, so no root
   privileges are needed for the agent.

Port 45876 is open to the LAN by dsnas's firewall (allow 192.168.68.0/24); only the hub's key is accepted.

## What is collected, shown and alerted

| Metric | Collected by | Visible in Beszel | Alert (ntfy) |
|---|---|---|---|
| Availability, uptime | agent (hub connection) | yes, system `dsnas` | **Status down > 5 min** (dsnas) |
| CPU, load average | agent | yes | no (a NAS is often busy; no useful threshold) |
| Memory | agent | yes | **> 90 % for 15 min** (dsnas) |
| Network throughput (eth0) | agent | yes | no |
| DSM system partition usage | agent | yes (Disk) | no (SNMP checks the data volume) |
| `/volume1` usage + I/O | agent (`EXTRA_FILESYSTEMS`, shown as `dm-1`) | yes (extra filesystem) | via SNMP: < 10 % free |
| CPU temperature | agent (`cpu-thermal`) | yes | via SNMP: system > 65 C |
| Storage pool + volume status (degraded/crashed) | SNMP | no (journal + state file on Beacon) | **SystemdFailed** on beacon (2 consecutive bad runs) |
| Per-drive health status, temperature, bad sectors | SNMP | no | same (drive > 55 C, bad sectors > 0, health != normal) |
| HTTPS certificate of `dsnas.rubusdua.net` (trust, hostname, < 21 days) | Beacon `cert-expiry.timer` (6 h) | no | SystemdFailed (beacon) |
| SMB service (tcp 445) | Beszel network monitor run by Beacon's agent | yes (under system `beacon`) | NetworkMonitorLoss (beacon): > 20 % loss over 1 h |
| SMART *test* results/schedule | not available via SNMP or the unprivileged agent | no | no (DSM's own notification; see below) |
| Snapshot success/age | `nas/scripts/dsnas-check.py` (manual, needs a DSM admin login) | no | no (pending) |
| Backup job status/freshness | none yet (no backup jobs exist on dsnas yet) | no | no (pending, with the backup design) |

**One outage, one alert:** if dsnas is unreachable, only the Beszel `dsnas` Status alert fires (after 5 min). The
SNMP check notices that dsnas does not answer on 5001/445 and does not count it as a failure (changed 2026-11-14), and
the ICMP and TCP 5001 monitors that duplicated the Status alert were removed. The SMB 445 monitor stays as a service
check (it alerts later, on 1-hour loss, and also covers "NAS up but SMB down").

## Pending
- SMART tests (weekly quick, monthly extended per drive) and monthly data scrubbing were scheduled by the owner on
  2026-11-14 (first runs next month). Their *results* are not monitored automatically yet (roadmap NM1); options:
  DSM can e-mail (Gmail as SMTP is not used in this setup) or push via a webhook; an ntfy webhook needs the topic,
  which lives only in Beszel's settings.
- Snapshot freshness and future backup-job freshness as an alerting check (needs a least-privilege way to read
  them; DSM has no read-only admin role, so not done yet).
- End-to-end alert test with the owner watching the phone (see the session plan: stop the agent package for
  ~6 min -> Status alert -> start -> recovery).
