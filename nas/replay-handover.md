# Replay -> dsnas handover (for Claude on Replay, with the owner's approval per step)

Written on dsserver 2026-11-14. Replay's own dependency analysis: Replay `~/Downloads/replay-nas-dependencies.md`
(sections 4-7). This file gives the dsnas side: what exists, what was verified, and what remains. Nothing on Replay
was changed from dsserver; Replay still backs up to DATASERVER.

## Target on dsnas (ready)

| Item | Value |
|---|---|
| NAS | dsnas, Synology DS223j, DSM 7.4.1, `192.168.68.112`; name `dsnas.rubusdua.net` via the LAN resolvers (Beacon .121, dsserver .115; no public record, so keep the IP as fallback, e.g. `NAS_HOST` fallback) |
| Protocol | SMB2/SMB3 only (SMB1 refused); LAN-only firewall |
| Share | `replay-backup` (hidden, not browsable; Btrfs data checksums; **no recycle bin**) |
| Paths | `restic/` = restic repository (Replay's `restore-points/`), `git/` = git bundles (Replay's `git-backup/`) |
| Account | `replay` (non-admin; access to `replay-backup` only, read/write; denied everywhere else) |
| Password | on dsserver `~/.config/nas/dsnas-accounts.cred` (`replay=`); the owner moves it to Bitwarden and types it when re-seeding Replay's `restore-nas-pass` / `nas-backup-pass` |
| Snapshots | `replay-backup` daily 05:00, 14 daily kept (protects against deletion/ransomware; outside Replay's 00:00-01:30 window) |
| Capacity | 3.5 TB volume, ~1.1 TB used |

Replay defaults are share `home`, path `replay/...`, user `admin`: switching needs a repo change + deploy on Replay
(share `replay-backup`, paths `restic` / `git`, user `replay`). **`restic-pass` stays unchanged.**

## Seed already on dsnas (2026-11-14 10:43-11:49)
- Byte-for-byte copy of DATASERVER `homes/admin/replay/restore-points/` (16,435 files, 268.77 GiB) and
  `git-backup/` (44 bundles, 2.42 GiB); `locks/` (empty at the time), obsolete `data-backup/` and `dev/` not copied.
- DATASERVER listing (16,742 entries, size + mtime) identical before and after the copy (Replay did not write).
- Every file re-read from dsnas disk matches the hash taken while copying; git bundles and `config` match an
  independent read from dsserver.
- Restic self-check (file name = SHA-256 of content): data 16,295 ok, index 66, snapshots 69, keys 1 ok;
  **3 data packs do not match, and they are identical on DATASERVER** (damaged at the source, not by the copy):
  - `data/3b/3bcff06410882da1e265b9961c733aecfcdc43dea1da422b50a71b27102fa448` 12,582,912 bytes
  - `data/53/53d94f942e0dfb1e915f99cc7bf1965ff5728f83d203a7b486d8c9eba0d3bfa8` 12,058,624 bytes
  - `data/ae/aec16a170b2088146b41cf1af8c3ab616cbc6d328517666d8a7b8bbdd45a6670` 3,039,422 bytes
  all written 2026-10-08 11:56:13 (DATASERVER clock, ~1 h fast), the last second of a large upload: most likely
  truncated packs from an interrupted backup run; possibly related to the weekly check failing since 2026-10-05.

## Remaining steps (Replay side unless noted)
0. **Repair on the old NAS first:** `restic check --read-data` against DATASERVER. If it reports the three packs:
   follow restic's repair procedure (`restic repair index`, `restic repair snapshots` as restic advises; then a
   clean `restore-point.sh check`). No prune until the check output is understood. Owner approval for any repair.
1. Pause Replay's four NAS timers (reversible `systemctl stop`); no deploys during the window.
2. **Final sync DATASERVER -> dsnas as a mirror**, e.g. from Replay (it already has rclone and both credentials once
   seeded): `rclone sync <old>:home/replay/restore-points <new>:replay-backup/restic` and the same for `git-backup`
   -> `git`, excluding `locks/`. The repair/prune will have deleted and rewritten files, and the dsnas seed must not
   keep stale packs. `sync` deletes inside the dsnas copy only: needs the owner's explicit OK. (The 05:00 snapshot
   of `replay-backup` keeps the seed recoverable for 14 days.)
3. Verify from Replay: `restic snapshots --no-lock` and `restic check --read-data` against the dsnas repository.
4. Switch Replay to dsnas (share/paths/user above), re-seed the two NAS password credentials, deploy.
5. Restart the timers, run each job once (expect: a new snapshot, check ok), soak 2+ weeks before DATASERVER's copy
   is retired (owner approval). Rollback until then: redeploy the previous commit (old NAS untouched).

## Not affected
dsnas already serves the family, media and other shares; the Replay work touches only `replay-backup`. Replay's ROM
import tools still read `Movies/news/{pc,snes}` on DATASERVER; their dsnas copies are in `media/Games/{pc,snes}`
(read-only for the `media` and `family` accounts) if the import tools are ever moved.
