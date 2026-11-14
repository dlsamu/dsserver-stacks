# hostbackup: off-device backups of dsserver and Beacon to dsnas (milestone B1)

Approved 2026-11-14 (proposal `docs/backup-proposal.md` + owner amendments 1-14). One encrypted restic repository
per host on dsnas over SMB3; separate, individually monitored jobs; integrity-gated retention; automated restore
drills. Break-glass recovery: [`docs/recovery.md`](../docs/recovery.md).

| | dsserver | Beacon |
|---|---|---|
| Share / account | `server-backup` / `dsserver-backup` | `beacon-backup` / `beacon-backup` |
| Repository | `server-backup/dsserver/restic` | `beacon-backup/beacon/restic` |
| Destination marker | `server-backup/dsserver/DESTINATION.json` | `beacon-backup/beacon/DESTINATION.json` |
| Secrets (root 0600) | `/etc/dsserver-secrets/backup/` | `/etc/beacon-secrets/backup/` |
| Program | `/usr/local/lib/dsserver-admin/backup/hostbackup.py` (delegated snapshot) | `/srv/hostbackup/hostbackup.py` |
| Operate | `sudo -n /usr/local/lib/dsserver-admin/host/scripts/19-backup.sh <step>` | `bash /srv/stacks/backup/deploy-beacon.sh <step>` |

Secrets directory: `restic.pw` (repository password; **also in Bitwarden**), `smb.cred` (dsnas login; also in
Bitwarden), `destination-id` + `repo-id` (identity checks), `healthchecks.json` (ping URLs).

## Jobs and schedule

| Job | dsserver | Beacon | What | Healthchecks grace |
|---|---|---|---|---|
| backup | daily 02:15 | daily 02:45 | consistent SQLite copies + manifests, system manifest, `restic backup`, `restic check` (structure), size metrics | 5 h |
| check | Sun 04:00 | Sun 04:20 | `restic check --read-data-subset=K/5`, K = ISO week mod 5 + 1: deterministic rotation, all data every 5 weeks | 8 h |
| fullcheck | 1st 04:30 | 1st 05:00 | `restic check --read-data` | 14 h |
| prune | Sat 04:00 | Sat 04:20 | `forget --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --prune` **only if integrity is ok** | 6 h |
| drill | 15th 04:45 | 15th 05:15 | restore + verify (below) | 6 h |
| dsnas snapshot | 05:45 (`server-backup`) | 05:50 (`beacon-backup`) | Btrfs snapshot, 14 daily + 8 weekly; immutable (WORM) 7 days once enabled | - |

Each job is `hostbackup@<job>.service` (`Type=exec`, so a failure reaches Beszel SystemdFailed -> ntfy) started by
`hostbackup-<job>.timer` (`Persistent=true`: a run missed while the host was off happens at boot), and pings its own
Healthchecks check (start / success / fail): a run that never happens is an alert too (e-mail).

## Rules (enforced in `hostbackup.py`)
- **Destination identity before every operation:** the mount must be CIFS from `//192.168.68.112/<share>`, the
  destination marker id must match `destination-id`, and the repository id (`restic cat config`) must match
  `repo-id`. Otherwise the job aborts. The mount point must be empty when unmounted; the repository path is always
  inside the mount: **no local fallback** exists.
- Mount: `vers=3.1.1,seal` (SMB3 encryption + signing), `soft` (I/O errors instead of hangs), mounted per job and
  unmounted afterwards.
- **Exit 3 (incomplete snapshot) and every other non-zero exit are failures.**
- **Integrity state** (`/var/lib/hostbackup/state.json`): `unknown` (initial, after an interrupted write, after a
  prune) -> `ok` (after a passing `check`/`fullcheck`) -> `compromised` (a check found errors, exit 1). **Prune is
  refused** unless the state is `ok`, a data check passed within 9 days and a structure check passes right before.
  A refused prune is a failure (alert), nothing is deleted.
- **Never** `restic unlock` and **never** `restic repair` automatically; lock contention waits (`--retry-lock 15m`)
  and then fails. Repairs are a manual, owner-approved procedure (docs/recovery.md).
- All repository jobs of a host are serialized by one `flock` (wait up to 4 h); fixed start times are not trusted to
  prevent overlap.

## Consistency
- **Databases are never read live into the repository.** Each SQLite database is copied with SQLite's online backup
  API into `/var/lib/hostbackup/staging/sqlite/<name>.db`, checked (`integrity_check`), and described in
  `<name>.manifest.json` (sha256, size, per-table row counts, schema hash). The live files are excluded.
  dsserver: StockPulse `history.db`. Beacon: Beszel `data.db` + `auxiliary.db` (without stopping the hub), netwatch.
- Other stateful data is file-based and written atomically by its service: Caddy certificates/ACME accounts,
  cloudflared credentials, StockPulse reports and its own daily DB copies, Beszel's key, nasmon/netwatch state.
- `system-manifest.json`: enabled units, `dpkg --get-selections` (+ hash), git HEADs, Docker images.
- **dsnas snapshots vs. running jobs:** restic writes data packs before the index and the snapshot record last, and
  `prune` writes new packs/index before deleting old ones, so a snapshot of the share taken at any moment contains a
  usable repository (at worst with unreferenced data). The 05:45/05:50 snapshot times only reduce that case.

## Restore drill (monthly, automated)
Restores the latest snapshot's `/etc`, `/srv/stacks` (dsserver) / `/srv/beacon` (Beacon), StockPulse reports and
the staging area into `/var/lib/hostbackup/drill/` with `restic restore --verify`, then checks:
1. owner, group, permissions and size of every restored file/dir == the snapshot listing;
2. each restored database == its manifest (sha256, `integrity_check`, row counts) - the live database is never touched;
3. `git fsck` of the restored `/srv/stacks`, HEAD == manifest;
4. every locally defined enabled unit has its unit file and enablement link in the restored `/etc`;
5. dsserver: the StockPulse production image opens the restored DB copy as uid 10010 with **no network and no
   notification key**, runs `integrity_check`, counts runs and performs a write transaction (rolled back).
The drill directory is deleted afterwards. Quarterly manual drill: docs/recovery.md.

## What is backed up
| dsserver | Beacon |
|---|---|
| `/etc` (incl. `/etc/dsserver-secrets`, `/etc/stockpulse-secrets`, `/etc/cloudflared`), `/srv/stacks`, `/srv/appdata` (Caddy, StockPulse data/reports, tunnel), `/usr/local/lib/dsserver-admin`, `/home`, `/root`, staging | `/etc` (incl. `/etc/beacon-secrets`, `/etc/dsnas-monitor`), `/srv/beacon`, `/srv/local-dns`, `/srv/appdata` (Beszel, netwatch, Caddy), `/home`, `/root`, staging |

Excluded (`excludes/`): caches, trash, live DB files (copied consistently instead), the StockPulse test
environment, obsolete/temporary credentials and migration artifacts (`~/.config/nas`, `~/nas-migration`,
`~/beacon-backups`, old handover/debug archives), KDE clipboard history, Claude Code program files, login token and
session transcripts, build artifacts, and `/home/axel` **until Axel agrees** (`include_axel` in
`hosts/dsserver.toml`; dependency/build directories stay excluded when it is included).

## Tests (`tests/test_hostbackup.py`, disposable repository)
Normal backup/check/drill/prune; restic killed mid-backup; prune refused while integrity unknown/compromised; exit
3; wrong destination marker; share unavailable (no local writes); lock held; recovery via full check. Missed run:
`19-backup.sh hc-test-missed` (temporary Healthchecks check goes "down"). Results: below.

## Measurements
(filled in from `/var/lib/hostbackup/metrics.jsonl` after the first runs)
