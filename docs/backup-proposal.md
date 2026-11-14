# Proposal B1: off-device server backups to dsnas (for review, 2026-11-14)

Scope: dsserver, Beacon, StockPulse (database + history + reports), infrastructure configuration and tooling, and the
secrets needed to rebuild, encrypted. Primary destination: dsnas. Later: DATASERVER as a second copy (roadmap B2,
only after Replay's migration is verified) and off-site (B3).

The measure of success is **a restore that has been done**, not a backup that has run.

## 1. Lessons from Replay (what went wrong there, and the rule here)

| Replay finding (nas/replay-handover.md, replay-nas-dependencies.md) | Rule for B1 |
|---|---|
| The weekly integrity check failed 5 times in a row (since 2026-10-05) and nobody noticed for 5 weeks | Every job alerts on failure (ntfy) **and** an external dead-man check alerts when success is missing (Healthchecks.io), so silence is also an alert |
| Retention/prune ran only inside the check: a failing check also stopped retention | Backup, check, prune and restore drill are **separate jobs** with separate alerts; none depends on another's success |
| The check and the monthly drill ran at the same time and fought over the restic lock | All repository jobs of a host run **serialized** through one lock (flock); fixed, non-overlapping schedule |
| Three packs were left truncated by an interrupted upload, detected only by our copy's content check | `restic check` (structure) after every backup; `--read-data-subset` weekly; full `--read-data` monthly, run **on dsnas-local speed** from the host; interruptions (`RuntimeMaxSec`, network) are expected and repaired, never silently tolerated |
| Repository written by the NAS `admin` account over SMB | Dedicated non-admin account **per host**, access to its own folder only |
| Repository password held only in host-bound (TPM) credentials | Password also in **Bitwarden** (break-glass); a restore is drilled from a *different* machine using only Bitwarden |
| Restore procedure existed but restore points were never independently proven | Automated restore drill (monthly) + documented, timed manual drill (quarterly) |

## 2. Design

**Tool: restic 0.18** (Debian `restic` package on both hosts; same tool the household already knows from Replay).
Client-side encryption (AES-256), deduplication, `check --read-data`, snapshots with tags. One repository **per
host**, each with its own password (a leak affects one host only).

**Destination:** dsnas share `server-backup` (exists: Btrfs checksums, hidden, no recycle bin, snapshots 03:30
daily 14 / weekly 8):

```
server-backup/
  dsserver/restic/   account dsserver-backup (exists)   RW only here
  beacon/restic/     account beacon-backup (new)         RW only here
```

**Transport (decision needed, recommendation first):**

| | A. SMB3 mount per job (recommended) | B. SFTP on dsnas |
|---|---|---|
| New service on dsnas | none (SMB already serves the LAN) | DSM SFTP service = port 22 open again (terminal SSH can stay off, but it is sshd) |
| Setup | kernel CIFS mount at job start (`vers=3.1.1`, `seal` = encrypted + signed, `soft`, timeouts), unmount at end; credentials root-only | user homes + key auth per account in DSM |
| Atomicity | restic `local` backend over CIFS; partial files from interrupted runs are caught by the post-backup `check` + weekly data check and repaired | restic sftp uploads to a temp name and renames |
| Moving parts | mount options, one credentials file | DSM SFTP config, homes, authorized_keys |

**Protection against a compromised host:** a host can delete its own repository over SMB. Defence: dsnas Btrfs
snapshots of `server-backup` (taken by dsnas, not deletable by the backup accounts) keep 14 daily + 8 weekly
versions. Option to check: DSM 7.2+ *immutable snapshots* (WORM lock for N days) if the DS223j supports them.

**What is backed up**

| Host | Included | Excluded / how |
|---|---|---|
| dsserver | `/etc` (incl. `/etc/dsserver-secrets`, `/etc/stockpulse-secrets`, `/etc/cloudflared`), `/srv/stacks` (also on GitHub), `/srv/appdata` (Caddy certs/ACME account, StockPulse `data/` incl. the daily integrity-checked SQLite copies, `reports/`, tunnel state), `/usr/local/lib/dsserver-admin` (delegation snapshot), `/home/daniel` config essentials (`~/.ssh`, `~/.config/nas` while it exists, dotfiles), package list (`dpkg --get-selections`), Docker image list | live `history.db` (the consistent copy is the 03:15 SQLite backup + a fresh `sqlite3 .backup` right before restic), Docker images/layers (rebuilt from the repo), caches, `/home/axel` (dev data on GitHub; **owner decides**) |
| Beacon | `/etc` (incl. `/etc/beacon-secrets`, SNMP config, Beszel automation credentials), `/srv/beacon`, `/srv/appdata/beszel` (via a consistent copy from `scripts/backup-hub.sh`), `/srv/appdata/netwatch`, `/srv/appdata/caddy`, package list | OS image (rebuilt with `beacon/flash-sd.sh` + cloud-init) |

**Secrets:** all host secrets travel inside the encrypted repositories. The four things needed to start a restore
on new hardware live in **Bitwarden**: the two restic repository passwords, the `dsserver-backup` and
`beacon-backup` SMB passwords. A `docs/recovery.md` (break-glass) lists the exact bare-metal steps.

**Jobs per host** (systemd `Type=exec` units so Beszel sees failures; all repository jobs share one `flock`):

| Job | When | What | Alert |
|---|---|---|---|
| backup | dsserver 04:00, Beacon 04:20 | fresh SQLite copy (dsserver) / hub backup (Beacon), `restic backup`, then `restic check` (no data read) | unit failure -> Beszel SystemdFailed -> ntfy; success ping -> Healthchecks (period 1 d, grace 6 h -> e-mail) |
| check | Sunday 05:00 | `restic check --read-data-subset=20%` (whole repo every ~5 weeks) | unit failure + Healthchecks (weekly) |
| full check | 1st of month 05:00 | `restic check --read-data` | unit failure |
| prune | Saturday 05:00 | `restic forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune` | unit failure + Healthchecks (weekly) |
| restore drill | 15th of month 05:30 | restore the latest snapshot's `/etc`, `/srv/stacks` and StockPulse DB into a temp dir; compare file hashes with the snapshot, `sqlite3 PRAGMA integrity_check` + row counts vs. the live DB, `git fsck` of the restored repo; delete the temp dir | unit failure |
| freshness | every 5 min (existing `dsserver-health` heartbeat) | newest successful backup older than 26 h -> health code `backup-stale` | existing heartbeat -> Healthchecks e-mail |

dsnas snapshot of `server-backup` moves from 03:30 to **05:45** so it captures the finished nightly backups.

**Quarterly manual drill (owner + Claude, ~30 min):** from Beacon (dsserver's repo) and dsserver (Beacon's repo),
using only Bitwarden: list snapshots, restore `/srv/stacks` + StockPulse DB, verify, record the time it took in
`docs/recovery.md`.

## 3. Implementation plan (each step tested, documented, committed)

1. **Owner:** create DSM account `beacon-backup` (same pattern as the others) or approve that Claude does it via the
   DSM UI steps; create folders `server-backup/dsserver`, `server-backup/beacon` with per-account permissions.
2. Install `restic` (Debian package) on dsserver (delegated script `19-backup.sh`) and Beacon.
3. Repository passwords generated on each host (root 0600); **owner copies them into Bitwarden before the first
   backup counts as done**. SMB passwords re-entered root-only via the established staged-file pattern.
4. `init`, first backup, `check --read-data`, first restore drill (automated) on each host.
5. Units + timers, Healthchecks checks (owner creates two checks, or one per job type), `dsserver-health` code.
6. Alert drills (simulated failure + missed run) with the owner watching the phone and e-mail.
7. Break-glass `docs/recovery.md` and the first quarterly manual drill from the *other* machine.

Effort: ~1 session for dsserver + Beacon, plus the owner's 3 short UI/Bitwarden steps.

## 4. Decisions for the owner
1. Transport A (SMB3 mount) or B (SFTP).
2. Retention 14 daily / 8 weekly / 12 monthly (proposed) or different.
3. `/home/axel` in or out (and whether Axel is told what is backed up).
4. Healthchecks: one check per host for the nightly backup (proposed) + one weekly for check/prune.
5. Whether to check DSM immutable snapshots for `server-backup`.

## Out of scope here (roadmap order)
B2 DATASERVER as versioned secondary copy (after Replay's migration is verified) · B3 off-site for family data ·
N2 physical network monitoring · N3/N4 Replay and Kjell on demand · O3 container observability.
StockPulse rollout commitments are unchanged (intl/ATH timers stay disabled until their own acceptance).
