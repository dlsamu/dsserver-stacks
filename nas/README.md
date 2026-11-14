# dsnas migration report (overnight 2026-11-13/14)

New NAS: **dsnas**, Synology DS223j, 192.168.68.112, DSM 7.4.1-90080 Update 1, 2 x 4 TB IronWolf, SHR-1, Btrfs.
Old NAS: **DATASERVER**, DS213j, 192.168.68.119, DSM 7.0.1. Treated read-only throughout: mounted read-only
(`ro`, SMB 3.0) on dsnas; no file, setting or account on it was changed by this work.
This report contains no passwords. Credentials live in root/owner-only files on dsserver (`~/.config/nas/`, mode 0600).

**Status: PARTIAL** (family data and media PASS; Replay seeded but not switched; see section 10).

## Follow-up 2026-11-14 afternoon (operational state)

- `scripts/dsnas-check.py` (repeatable, read-only + one round-trip file in `exchange`): **58/58 ok**. Checksums on
  for all shares except `exchange`; hidden flags; share ACLs; snapshot schedules, retention and the newest snapshot
  per share (< 26 h old); SSH and Telnet off; SMB matrix for all 4 accounts x 6 shares (service accounts isolated:
  `replay` and `dsserver-backup` see only their own share, `media` only `media` read-only).
- `exchange`: `family` can write, read back (SHA-256 identical), delete; recycle bin on for users, no snapshots.
  Any household device with the `family` account can use `\\192.168.68.112\exchange` (or `dsnas.rubusdua.net` once local DNS is live).
- Credentials on dsserver: removed (shredded) `~/.config/nas/dataserver.cred` (owner's DATASERVER admin login, no
  longer used) and `~/.config/nas/dsnas-snmp.cred` (Beacon keeps its own root-only copy, which is the live one).
  Kept: `dsnas-setup.cred` (claude-setup, kept for follow-up work) and `dsnas-accounts.cred` (needed for the Replay
  handover and future server backups; move to Bitwarden, then delete). Scratch copies of file lists removed.
- `claude-setup`: kept as requested. SSH stays off. The watchdog on dsnas still **disables** (does not delete) the
  account on 2026-11-15 10:00; it was not extended.
- FTP exposure (after the owner removed the Deco port forwards): from inside, the public IP no longer answers on 21
  or the passive range (80/443 there are the Deco's own web server, certificate `tplinkdeco.net`, HTTP 403). This is
  not conclusive (depends on the Deco's NAT loopback). DATASERVER's log shows the last internet FTP attempt on
  2026-11-10 (attempts came every 1-3 days before, with gaps). A test from outside (mobile data) is still needed.

## 1. Work completed

| Phase | Result |
|---|---|
| 1 Access | DSM API + SSH as the temporary `claude-setup` admin; SSH reachable from the LAN only (firewall); dead-man watchdog on dsnas (see 6) |
| 2 Security | LAN-only firewall, Auto Block, security auto-updates, SMB2/3 only, services off (see 6) |
| 3 Shared folders | 6 shared folders, checksums on 5, recycle bins, 4 non-admin accounts + group `family`; SMB permission matrix tested |
| 4 Migration | Direct NAS-to-NAS copy (dsnas pulls from a read-only SMB mount of DATASERVER; dsserver only orchestrates and verifies; Replay not involved) |
| 5 Verification | Three-way SHA-256 per file (see 4) |
| 6 Replay backups | history seeded to dsnas and verified; not switched (see 8) |
| 7 Monitoring | Beacon: reachability + SNMPv3 health checks, alerting via Beszel -> ntfy; snapshots verified (see 7) |
| 8 FTP exposure | investigated, not fixable without the router (see 6 and 9) |

## 2. Folder structure on dsnas

| Shared folder | Content | Access (SMB) | Checksums | Recycle bin | Snapshots (time, retention) |
|---|---|---|---|---|---|
| `photos` | `Rani/`, `Kjell/`, `Siri/`, `Events/<year>/<yyyy-mm event>/`, `Video/{Leoson,Egna}` | `family` RW | yes | yes (admins only) | 03:00 daily; 14 daily, 8 weekly, 12 monthly, min 5 |
| `family` | `Rani/` (documents), `_review/` | `family` RW | yes | yes (admins only) | 03:10; 14 daily, 8 weekly |
| `media` | `Movies/<genre>/`, `Series/`, `Documentaries/`, `Sport/`, `Music/`, `Audiobooks/`, `Games/<platform>/`, `Books/`, `Tools/`, `_review/` | `family` RO, `media` RO, admins RW | yes | no | 03:20; 7 daily, 4 weekly |
| `replay-backup` (hidden) | `restic/`, `git/` | `replay` RW only | yes | no | 05:00; 14 daily |
| `server-backup` (hidden) | empty, for dsserver/Beacon backups later | `dsserver-backup` RW only | yes | no | 03:30; 14 daily, 8 weekly |
| `exchange` | temporary drop zone | `family` RW | no | yes | none |

Accounts: `family` (the household), `media` (TVs/players, read-only), `replay`, `dsserver-backup`. Passwords:
`~/.config/nas/dsnas-accounts.cred` on dsserver (move them into Bitwarden, see 9).
Review areas (nothing was discarded): `family/_review/DATASERVER-music/` (machine-learning PDFs/notebooks found in
`music`), `media/_review/Movies-news/` (unsorted items in `Movies/news`), `family/_review/DATASERVER-unmapped/` (empty: every file matched a rule).

## 3. Manifest

`manifests/` (git-ignored, contains family file names):

- `manifest.tsv`: one row per migrated file: old path, new path, collection, size, mtime, SHA-256 read during copy, SHA-256 re-read from dsnas disk, status
- `excluded.tsv`: every file deliberately not copied, with the reason
- `emptydirs.tsv`, `issues.tsv` (collisions; empty), `duplicates.tsv`, `replay-restic-intrinsic.txt`
- `*-src.tsv`: the independent source hashes; `compare-*.json`: verification results

The migration database (`state.db`, resumable) is on dsnas in `/volume1/@claude-migration` (root-only).

## 4. Counts, sizes, verification

A file counts as verified only when all three SHA-256 values agree:
1. bytes read from DATASERVER during the copy (computed by the copier),
2. the file re-read from dsnas disk after a cache drop (`verify-dst`),
3. an **independent** read of DATASERVER from dsserver (separate SMB session, tar stream, separate program),

and the sizes match. Completeness: every file the independent read saw must be in the manifest or in `excluded.tsv`.

| Collection | Destination | Files | GiB | 3-way verified | Result |
|---|---|---|---|---|---|
| photos-rani | photos/Rani | 38,294 | 102.41 | 38,294 | PASS |
| photos-kjell | photos/Kjell | 15,098 | 28.35 | 15,098 | PASS |
| photos-events | photos/Events | 923 | 6.50 | 923 | PASS |
| photos-siri | photos/Siri | 259 | 2.99 | 259 | PASS |
| photos-video | photos/Video (Leoson, Egna) | 63 | 29.02 | 63 | PASS |
| family-docs | family/Rani | 7,752 | 24.02 | 7,752 | PASS |
| family-review | family/_review | 103 | 0.12 | 103 | PASS |
| **Family subtotal** | | **62,492** | **193.41** | **62,492** | **PASS** |
| media-movies | media/Movies | 224 | 358.62 | 224 | PASS |
| media-series | media/Series | 372 | 102.52 | 372 | PASS |
| media-sport | media/Sport | 159 | 68.52 | 159 | PASS |
| media-music | media/Music | 1,547 | 53.51 | 1,547 | PASS |
| media-games | media/Games | 123 | 41.58 | 123 | PASS |
| media-docs | media/Documentaries | 6 | 11.89 | 6 | PASS |
| media-audiobooks | media/Audiobooks | 1,259 | 7.18 | 1,259 | PASS |
| media-review | media/_review | 3 | 4.75 | 3 | PASS |
| media-tools | media/Tools | 4 | 0.04 | 4 | PASS |
| media-books | media/Books | 1 | 0.00 | 1 | PASS |
| **Media subtotal** | | **3,698** | **648.61** | **3,698** | **PASS** |
| **Total (family + media)** | | **66,190** | **842.0** | **66,190** | **PASS** |

- Copy failures: 0. Destination collisions: 0 (the copier refuses to overwrite: it links a fully written temp file
  into place, which fails if the name exists). Size or hash mismatches: 0. Files missing from the independent
  check: 0.
- Completeness: the independent read saw 67,018 source files under the migrated folders: 66,293 in the manifest
  (the 103 ML files were read twice), 725 excluded system files (Thumbs.db, .DS_Store), **0 unaccounted**.
- Timestamps: modification times preserved (the copier sets them; the manifest records them).
- Permissions after copy tested over SMB: `family` reads and writes in migrated folders (test folder created and
  removed); `media` is refused on `photos`; the SMB access matrix for all accounts and shares matches section 2.
- Timing: family copy 72 min (00:40-01:52), media copy 135 min (03:45-06:00); dsnas re-read and independent
  hashing afterwards.
- Not recreated: 15 empty folders (`emptydirs.tsv`; e.g. `homes/Axel`, `homes/peter`, empty `Movies/Kids`, `Movies/SciFi`).

## 5. Duplicates, exclusions, unresolved

### Not copied (all still on DATASERVER, listed in `excluded.tsv`)
| What | Files | Size | Why |
|---|---|---|---|
| `Movies/news/Unconfirmed 266614.crdownload` | 1 | 48.0 GiB | unfinished browser download (your decision) |
| `homes/admin/psw.txt` | 1 | < 1 KB | plaintext password file: not opened, not copied |
| `Movies/Tools/github-recovery-codes.txt` | 1 | < 1 KB | plaintext recovery codes: not opened, not copied, and skipped by the independent hashing |
| `Movies/.Trash-1000/` | 442 | ~0 | Linux trash folder (your decision) |
| `Thumbs.db`, `.DS_Store` | 727 | 0.18 GiB | Windows/macOS thumbnail caches |
| `homes/admin/replay/data-backup/`, `dev/` | | | obsolete Replay folders (see 8); `restore-points/locks/` (transient lock files) |
| `dsserver-backups` share | 0 | 0 | empty |

### Duplicates (flagged, nothing deleted)
`manifests/duplicates.tsv` lists every set of byte-identical files (same SHA-256) on dsnas:
**3,434 groups, 3,983 redundant copies, 8.8 GiB**: within `photos` 2,657 (e.g. the wedding "topp 200" selection is
an exact subset, repeated imports in `Rani/Pics` and `Kjell`), between `family/Rani` and `photos/Rani` 860, within
`family` 323, within `media` 143 (mostly "(1)" game copies). De-duplicate later only if you want to; the space gain is small.

### Review areas (decide later)
- `family/_review/DATASERVER-music/`: 103 machine-learning PDFs/notebooks that were stored in the `music` share.
- `media/_review/Movies-news/`: 3 files from `Movies/news` that are neither Replay ROM folders nor known
  platforms (`The Odyssey`, two arcade `.chd` images).

### replay-uploads (investigated)
Two zip files uploaded through Replay: `Best NES Games.zip` -> `media/Games/nes/`, `a500a-games-all.zip` -> `media/Games/amiga/`. Game collections, not backups.

## 6. Security configuration and remaining risks

### dsnas (configured)
| Item | Setting |
|---|---|
| Firewall | Enabled, profile `default`: allow 192.168.68.0/24, then explicit **deny all** (iptables `INPUT_FIREWALL`: lo, established, LAN, DROP). Applied with a 5-minute auto-revert safeguard, then confirmed. dsserver, your PC and Beacon are on the LAN and keep access |
| Internet exposure | QuickConnect off, DDNS none, no router port forwards, UPnP off; DSM only on the LAN |
| Auto Block | on: 10 failed logins in 5 minutes |
| Updates | automatic install of important/security updates (weekly check, Mon 00:45) |
| SMB | minimum SMB2, maximum SMB3; SMB1 refused |
| Off | FTP/FTPS, SFTP, Telnet, NFS, AFP, SNMP v1/v2c, rsync service |
| Verified listening ports | none of 21, 23, 548, 873, 2049 (checked with `netstat` on dsnas) |
| On | SMB, DSM web (5001 HTTPS; 5000/80 HTTP also answer, LAN-only), SNMPv3 (read-only user `beacon-ro`, SHA/AES, for monitoring) SSH was on (LAN-only) during the work and **turned off 2026-11-14 12:28** (port 22 refused) |
| Accounts | your admin account untouched; 4 non-admin service accounts (above); `claude-setup` temporary admin (to delete, see 9) |
| Packages added | Snapshot Replication + its dependency Replication Service only |

**Dead-man safeguard (on dsnas, root-only, `/volume1/@claude-migration/watchdog.sh`).** Unmounts the
DATASERVER read-only mounts if no heartbeat for 45 minutes, and in any case at 2026-11-14 23:30 (before Replay's
nightly backups). On **2026-11-15 10:00 it disables SSH and disables the `claude-setup` account** if they are still
active. It fired once as designed (03:06, while the session was hashing on dsserver) and the mounts were re-created.
The CIFS credential is written to a RAM file only during the `mount` call and deleted immediately.

### Remaining risks
1. **DATASERVER FTP is reachable from the internet.** DATASERVER's own port forwarding/UPnP list is empty and no
   UPnP gateway answers on the LAN, so the exposure must be a **manual port forward (21, passive 55536-55546) or
   DMZ/"exposed host" entry on the Deco**. The log shows 205 refused anonymous logins from the internet.
   I did **not** disable FTP: the account `peter` logged in over FTP from internet addresses (31.209.3.251,
   79.136.23.7) and uploaded ~1 GB on 2025-11-23 and 6.4 MB on 2025-12-10 (preceded by `admin`/`peter` logins from
   192.168.68.120 on the LAN). That looks like deliberate use and is a possible dependency; your decision. See 9.
2. **Plaintext secrets on DATASERVER:** `homes/admin/psw.txt` and `Movies/Tools/github-recovery-codes.txt`. Not copied, not opened. `Movies` is read by many devices.
3. **Every DATASERVER client logs in as `admin`.** dsnas has per-role accounts; clients must be moved to them.
4. **DATASERVER runs DSM 7.0.1 (2022) with end-of-life packages**, SMB1 enabled; its clock is ~1 hour fast.
5. Device 192.168.68.106 (unknown, MAC 68:a4:0e:...) speaks only SMB1; it will not be able to use dsnas.
6. DHCP: DATASERVER's DHCP server is **disabled** (no clients), so no conflict with the Deco; nothing to change.
7. During setup, the SNMP authentication passphrase was printed once in this session's output. Both SNMP keys were rotated immediately; the printed value is no longer valid.
8. The service accounts can still log in to DSM (they are not admins); optionally deny them DSM/application access (Control Panel > Privileges).

## 7. Snapshots and monitoring

### Snapshots (verified)
Schedules and retention are listed in section 2. The first scheduled snapshots exist as Btrfs read-only snapshots
(`btrfs subvolume list -s /volume1`): photos 03:00, family 03:10, media 03:20, server-backup 03:30,
replay-backup 05:00 on 2026-11-14. Retention runs after each snapshot (`RetentionShareSnapshot.sh`, exit 0 in the
log) and the stored policies read back as configured. The photos and family snapshots already contain the complete,
copied family data (copy finished 01:52). Users can browse them via Snapshot Replication or the `#snapshot` folder.

### Monitoring (Beacon -> Beszel -> ntfy on your phone)
| Check | How | Alert |
|---|---|---|
| Reachability | Beszel network monitors on Beacon: ICMP ping, TCP 5001 (DSM), TCP 445 (SMB) | Beszel -> ntfy |
| Disks: health, SMART status, temperature, bad sectors | `dsnas-health.timer` on Beacon every 5 min, SNMPv3 read-only (Synology MIB) | unit fails after 2 consecutive bad results -> Beszel "SystemdFailed" -> ntfy |
| Storage pool/volume state (degraded, crashed), free space < 10 %, system temp > 65 C, disk > 55 C | same | same |

Source: `/srv/stacks/beacon/nasmon/` (deployed to Beacon `/srv/beacon/nasmon`). SNMP credentials only in
Beacon `/etc/dsnas-monitor/snmp.conf` (root 0600). Latest run: `dsnas OK`, disks 28/30 C, 0 bad sectors,
pool normal, volume 76 % free.

**Not tested end-to-end:** I did not provoke a failure to see the phone alert (it would have notified you at night).
Daytime test, 5-10 minutes, see 9.

**Not set up:**
- DSM's own e-mail/push notifications (backup/snapshot failure) via a webhook: the ntfy topic is stored only in
  Beszel's database (`~/ntfy-beacon.txt` does not exist), so I could not configure it without reading it out of Beszel.
- No Beszel agent on DSM (not needed: SNMP covers disks/volume; DSM's packaging makes an agent fragile).
- **SMART test schedule and monthly data scrubbing** are not scheduled yet. DSM only exposes them via the Storage
  Manager wizard (no documented API); 2 minutes by hand, see 9.

## 8. Replay backup migration

Seeded, verified, **not switched** (by design: the switch needs a change on Replay and your approval).

| Item | Result |
|---|---|
| Copied | `homes/admin/replay/restore-points/` -> `replay-backup/restic/` (16,435 files, 268.77 GiB); `.../git-backup/` -> `replay-backup/git/` (44 bundles, 2.42 GiB). Byte-for-byte, timestamps kept, 66 min, 0 failures |
| Not copied | `restore-points/locks/` (empty at copy time; locks are transient), obsolete `data-backup/` and `dev/` (stay on DATASERVER) |
| Source frozen? | Replay was **not** paused (out of scope). The copy ran 10:43-11:49, outside Replay's schedule (00:00-01:30 nightly, Sun 03:30, 1st 04:00). Full listing of the source (16,742 entries, size + mtime) **identical before and after** the copy: the repository did not change |
| dsnas re-read | 16,479 / 16,479 files match the hash taken while copying |
| Git bundles + restic `config` | match an independent read from dsserver (three-way PASS) |
| Restic self-check (file name = SHA-256 of content) | data 16,295 ok, index 66 ok, snapshots 69 ok, keys 1 ok; **3 data packs do not match** |
| Old NAS repository | untouched; still Replay's live repository |

**The 3 non-matching packs are damaged on DATASERVER itself**, not by the copy: two separate re-reads from dsserver
return exactly the bytes that are on dsnas. All three were written on 2026-10-08 at 11:56:13, the last second of a
large upload that ended abruptly, and two have suspiciously round sizes (exactly 12.0 and 11.5 MiB): most likely
truncated packs from an interrupted backup run. Whether any snapshot still needs them can only be decided by restic
(the index is encrypted). This may be related to the weekly `restic check` failing since 2026-10-05.
Details: `manifests/replay-restic-intrinsic.txt`.

### Handover (on Replay, each step with your approval; Replay's own plan is in `replay-nas-dependencies.md` section 6)
0. **Fix the repository on DATASERVER first:** run Replay's check with read-data on the *old* NAS and see what it
   says about the three packs (`restic check --read-data`; if it reports them, `restic repair packs`/`repair index`
   per the restic docs, then a clean `restore-point.sh check`). Do not prune until the check is understood.
1. Pause Replay's four NAS timers (`systemctl stop`, reversible); no deploys during the window.
2. Final sync DATASERVER -> dsnas. Because the repair/prune will have changed and deleted files, re-seed
   `replay-backup/restic/` as a mirror (e.g. empty the folder and copy again, or rsync with `--delete` restricted to
   that folder; needs your explicit OK because it deletes inside the dsnas copy). Re-run the three checks above.
3. From Replay: `restic snapshots --no-lock` and `restic check --read-data` against
   `rclone:<smb>:replay-backup/restic` as user `replay`.
4. Point Replay at dsnas: **share `replay-backup`, paths `restic/` and `git/`, user `replay`** (Replay's defaults
   are share `home`, path `replay/...`, user `admin`, so this is a repo change + deploy on Replay); re-seed
   `restore-nas-pass` and `nas-backup-pass` with the `replay` password (in `~/.config/nas/dsnas-accounts.cred`).
   **Leave `restic-pass` unchanged.**
5. Restart the timers, run each job once, soak 2+ weeks, keep DATASERVER's copy until then.
6. dsnas must be awake 00:00-01:30, Sun 03:30-05:00 and the 1st 04:00-06:00 (HDD hibernation wakes on access; fine).

## 9. Remaining manual actions

1. **Delete the temporary admin `claude-setup` on dsnas** (Control Panel > User). SSH is already off. If you
   don't, the watchdog disables the account on 2026-11-15 10:00 and then exits.
2. **Delete the migration work folder** when you are satisfied: `/volume1/@claude-migration` on dsnas (root-only,
   103 MB: copier, database, logs; no credentials). Needs an admin shell or keep it; harmless.
3. **SMART tests and data scrubbing** (Storage Manager): Storage Pool 1 > ... > *Data Scrubbing* > schedule monthly;
   HDD/SSD > *SMART Test* > schedule quick monthly + extended every 3 months.
4. **Router (Deco app), FTP exposure:** Advanced > NAT Forwarding > Port Forwarding: delete entries for 21 and
   55536-55546 to 192.168.68.119; check that DMZ is off; while there, add an **address reservation for dsnas
   (192.168.68.112)**. Then decide about FTP on DATASERVER (ask whoever uses `peter`; if nobody, disable FTP and the
   `peter` account in DATASERVER's Control Panel).
5. **Passwords:** move the four dsnas account passwords from `~/.config/nas/dsnas-accounts.cred` into Bitwarden;
   move/rotate what is in `psw.txt` and `github-recovery-codes.txt` on DATASERVER, then delete those two files.
6. **Clients:** TVs/players/BAZZITE -> `media` account on `\\192.168.68.112\media`; family devices -> `family`
   (consider one account per person later). The .106 SMB1 device cannot connect to dsnas.
7. **Test the alert path in daytime (5-10 min, I can do it on request):** briefly block Beacon's SNMP access or
   stop the check to see the ntfy notification arrive.
8. **Replay:** handover in section 8.
9. **DATASERVER:** keep it unchanged as the fallback until the Replay switch has soaked; only then make it the
   secondary backup target (separate approval).

## 10. Summary

| Area | Verdict |
|---|---|
| Family photos and documents (62,492 files, 193 GiB) | **PASS**: complete, three-way SHA-256 verified, permissions tested, in snapshots |
| Media (3,698 files, 649 GiB) | **PASS**: complete, three-way SHA-256 verified |
| dsnas security baseline, shares, accounts | **PASS** (temporary admin still to delete) |
| Snapshots | **PASS**: first snapshots taken for all five shares, retention configured |
| Monitoring | **PARTIAL**: checks running and green; alert path not tested end-to-end; SMART/scrub schedules manual |
| Replay backup history | **PARTIAL**: exact seed on dsnas verified; 3 packs damaged at the source; not switched (needs Replay-side work) |
| FTP exposure | **OPEN**: needs the router (your action) |

**Overall: PARTIAL.** Everything the family needs (photos, documents, media) is on dsnas, verified and protected;
DATASERVER is unchanged. What remains is the Replay switch, the router fix and a few manual settings.

## Credentials: move to Bitwarden (owner), then remove from dsserver

`~/.config/nas/dsnas-accounts.cred` (daniel, 0600) holds the four dsnas service-account passwords, one line each
(`family=`, `media=`, `replay=`, `dsserver-backup=`). Nothing on dsserver runs with them automatically; they are
needed by people/devices (family, media), by Replay after its switch (replay) and by the coming server backups
(dsserver-backup, re-entered root-only when that milestone is implemented).

1. In Bitwarden create four **Login** items (folder e.g. "Home infrastructure"):

   | Item name | Username | URI | Notes |
   |---|---|---|---|
   | dsnas - family | `family` | `smb://dsnas.rubusdua.net/` | household devices: photos, family, exchange (rw), media (ro) |
   | dsnas - media | `media` | `smb://dsnas.rubusdua.net/media` | TVs/players, read-only |
   | dsnas - replay | `replay` | `smb://dsnas.rubusdua.net/replay-backup` | Replay restic + git bundles only (see nas/replay-handover.md) |
   | dsnas - dsserver-backup | `dsserver-backup` | `smb://dsnas.rubusdua.net/server-backup` | server backups only |

2. Copy one password at a time in Konsole (prints a single value, no other output):
   `grep '^family=' ~/.config/nas/dsnas-accounts.cred | cut -d= -f2-`
   paste it into the Bitwarden item, then **Ctrl+Shift+K** (clear scrollback). Repeat for `media`, `replay`,
   `dsserver-backup`. Afterwards clear KDE's clipboard history (system tray > Clipboard > Clear history).
3. Check each item once: e.g. open `smb://dsnas.rubusdua.net/exchange` in Dolphin as `family` with the Bitwarden value.
4. Delete the file: `shred -u ~/.config/nas/dsnas-accounts.cred`.
   Afterwards `nas/scripts/dsnas-check.py` runs its SMB matrix only if the file exists (run with `--no-smb`, or
   restore a temporary copy from Bitwarden for a full check and shred it again).

The other secrets stay where they are: `cert-deploy` password `/etc/dsserver-secrets/dsnas-cert-deploy.pw` (root,
used by the timer; Bitwarden copy optional, it can be regenerated), SNMP keys on Beacon `/etc/dsnas-monitor/snmp.conf`.

## Cleanup of the temporary setup access (owner decides when)

State: SSH and Telnet on dsnas are **off**. `claude-setup` (DSM administrator) still exists; the watchdog on dsnas
**disables** it on 2026-11-15 10:00 (it does not delete it) and then exits.

1. When no follow-up work needs it: DSM > Control Panel > User & Group > `claude-setup` > Delete.
2. On dsserver: `shred -u ~/.config/nas/dsnas-setup.cred`. (`nas/scripts/dsm.py` and the API part of
   `dsnas-check.py` then need an administrator login supplied for that run; `cert-deploy` is not reused for that.)
3. Optional, the migration work folder `/volume1/@claude-migration` on dsnas (root-only, ~103 MB: copier, database
   with the migrated file list, logs; no credentials). Without SSH: DSM > Control Panel > Task Scheduler > Create >
   Scheduled Task > User-defined script, user `root`, run once, script `rm -rf /volume1/@claude-migration`; run it,
   then delete the task. (Keeping it is harmless; it documents the migration.)
4. Check: DSM > Control Panel > User & Group shows no `claude-setup`; Terminal & SNMP > SSH still off;
   `dsnas-check.py --no-smb` with an admin login: PASS.
