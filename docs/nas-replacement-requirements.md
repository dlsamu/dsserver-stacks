# Replacement NAS: requirements

Status: **requirements only.** A replacement NAS has been ordered (2026-11-10). It has not been delivered, installed or configured. All NAS integration, backup configuration and migration work for dsserver waits until the replacement has passed the acceptance criteria below.

## Hardware: pending confirmation
| Item | Value |
|---|---|
| NAS model | **Pending confirmation:** record from the delivered unit or invoice, not from the order |
| Drive model ×2 | **Pending confirmation:** model, capacity and serial numbers of the delivered drives |
| DSM version installed | Pending: record after setup; it must be a version that still receives security updates |
| UPS | Not yet chosen (see R4) |

## The existing NAS (DATASERVER) is off limits
- DATASERVER (Synology, about 2013) is running a **critical family-photo backup to Replay**.
- **Do not access, probe, mount, configure, update, or otherwise interact with DATASERVER or Replay** from dsserver or from automation. That includes test logins: Synology Auto Block can ban an IP after failed logins.
- **Do not modify or dismantle** DATASERVER, and leave it untouched while the replacement is being set up.
- Later, DATASERVER **may** serve as a secondary, non-critical backup destination. It must never become a required dependency.
- The 2026-11-09 investigation of DATASERVER as a restic target (read-only, no logins) is **suspended**. Its findings: SFTP closed, SMB 2.0.2–3.0.2 with signing not required, plain FTP open, and an old DSM. Those findings are why this replacement exists. They don't apply to the new NAS.

## R1. Purpose
1. Simple, reliable network storage.
2. **No** Docker, media transcoding or application hosting on the NAS.
3. Serves files to Replay, dsserver, the Raspberry Pis and the Windows computers.
4. **No essential service may depend on the NAS being available for normal operation.** dsserver services, logins and the Git workflow must keep working while the NAS is off. Only backups may wait for it, and a missed backup must raise an alert.

## R2. Storage
1. Two new, NAS-rated drives.
2. Storage pool: **SHR with one-drive fault tolerance** (for two drives this is a mirror).
3. Volume filesystem: **Btrfs**.
4. **Data checksums enabled** on every important shared folder: photos, the dsserver backups and personal files. On Synology this can only be enabled when the shared folder is **created**, so set it then.
5. **Periodic data-integrity checks (data scrubbing)** on a schedule. Suggested: monthly, outside the backup window.
6. **Snapshots** of the important shared folders, with reasonable retention. Suggested starting point: daily snapshots kept 14 days and weekly snapshots kept 8 weeks. To be decided once capacity is known. Snapshots of the dsserver backup folder are what make those backups recoverable even if dsserver is compromised (see R5.3).
7. **Monitoring:** drive health (S.M.A.R.T.), temperatures, capacity and storage-pool status, all with notifications (R4.3).

## R3. Security
1. **Dedicated, least-privilege service accounts:** one per client role, for example `dsserver-backup`, a separate account for Replay, and personal accounts. Service accounts aren't administrators and have no access to other shares.
2. **Separate shared folders and permissions** for personal files, Replay and dsserver backups. No account except the NAS administrator can read across them.
3. **Nothing exposed to the internet:** no QuickConnect, no port forwarding, no UPnP, no DDNS, no public certificates needed.
4. **Secure, supported SMB:** minimum SMB 2 with SMB 3 preferred, **SMB 1 off**, and encryption or signing **required** where the clients support it.
5. **Credentials stay out of Git.** NAS passwords are entered only by a person (in DSM or a local terminal) or stored in root-only files on the client. The repository records account and share **names** only.
6. **Minimal install:** only the packages and services needed. FTP, AFP, NFS, WebDAV, rsync and SSH stay off unless a documented requirement needs them (for example SFTP for restic, see R5.2). Auto Block stays on. The administrator account isn't used for day-to-day access.
7. A fixed address: a DHCP reservation in the Deco for the NAS's MAC address.

## R4. Reliability
1. **Power-loss recovery:** the NAS powers on again by itself when power returns. Configure it, then test it.
2. **Evaluate a compatible USB UPS** with automatic safe shutdown of the NAS. Optionally the NAS can also act as a network UPS server for dsserver. Decide after the evaluation.
3. **Failure notifications** for drive, pool, scrub, snapshot, backup and UPS events, sent to the same channel dsserver uses. Test them before relying on them.
4. **Important data has independent off-device backups.** The NAS's redundancy (SHR) is not a backup.

## R5. Backups
1. **Family photographs:** verified copies on **Replay** and on **Google Drive**. "Verified" means a documented check that file counts and checksums match, not just that a job finished.
2. **dsserver:** encrypted, versioned backups, preferably **restic**. The protocol (SFTP or SMB 3) is chosen when the new NAS is set up.
3. Replay and dsserver backups are **kept apart**: separate shared folders, separate accounts, and neither can delete the other's data.
4. **Retention and integrity checks are defined and scheduled.** For dsserver this means restic `forget`/`prune` rules, `check` with gradual full data reads, and NAS snapshots of the backup folder.
5. **Recovery is straightforward** both for single files and for a complete rebuild. The steps are written in `RECOVERY.md` and were tested by a real restore.
6. The **restic repository password is stored offline** (password manager), because a backup that can't be decrypted is lost.
7. DATASERVER may later hold a **secondary, non-critical** copy. Nothing may require it.

## R6. Migration (from DATASERVER, later)
1. **Do not modify or dismantle the original NAS.** It stays untouched during the initial setup of the replacement.
2. Plan the migration **only after** the new NAS has passed the hardware and filesystem checks (acceptance 1–2).
3. **Migrate over Ethernet**, wired on both ends.
4. **Preserve** the relevant directory structures and timestamps.
5. **Verify data integrity** (file counts plus checksums against the source) **before** retiring any role of the old storage.
6. The migration must not interfere with the Replay backup. Schedule it after that backup has finished and been verified.

## Acceptance criteria
The replacement is accepted only when every item is ticked, with date and evidence recorded below.

| # | Criterion | Result |
|---|---|---|
| 1 | Both drives pass the initial health checks: S.M.A.R.T. plus an extended test | pending |
| 2 | SHR redundancy and Btrfs checksums verified: pool healthy with one-drive tolerance, checksums enabled on the important shares, first scrub clean | pending |
| 3 | File-sharing permissions tested: each account can reach exactly its own shares and is refused elsewhere | pending |
| 4 | Test data copied and verified with checksums | pending |
| 5 | Snapshots taken and a restore from a snapshot tested | pending |
| 6 | Backup notifications and failure notifications tested, including a deliberate failure | pending |
| 7 | Recovery procedures documented (NAS rebuild, dsserver restore) | pending |

## Next steps (only after delivery)
1. Record the actual NAS and drive models above.
2. Set up the NAS following R2–R4, and complete acceptance items 1–3.
3. Design the dsserver backup (protocol, accounts, schedule, alerts) as its own approved phase.
4. Plan the migration from DATASERVER (R6) as a separate phase.
