# Break-glass recovery (dsserver, Beacon, StockPulse)

For the loss of one host (or of both servers). Targets: **RPO 24 h** (nightly backups), **RTO 2 h** after
replacement hardware is available. Measured results: `backup/README.md` "Measurements".

Every section is marked **TESTED** (with date and how) or **NOT TESTED** (instructions derived from the setup
scripts; follow them carefully and record the outcome here).

## Scope
- Covered: loss of dsserver, of Beacon, or of both, while **dsnas is intact**.
- **Not covered by B1: loss of dsnas** (fire, theft, both disks, ransomware with admin access). Then the server
  backups are gone too. Covered later by B2 (second copy on DATASERVER, after Replay's migration) and B3 (off-site).
- dsnas snapshots (`server-backup`, `beacon-backup`: 14 daily + 8 weekly) protect against a host deleting or
  corrupting its own repository. **They are not immutable**: the DS223j's DSM offers no immutable snapshots
  (checked 2026-11-14), so a DSM administrator can delete them.

## What you need, and where it is when the home infrastructure is down
| Need | Independent location |
|---|---|
| This document, all scripts, configuration and history | GitHub `dlsamu/dsserver-stacks` (private), plus this file as a Bitwarden secure note "Home infrastructure - recovery" |
| restic repository passwords (dsserver, Beacon) | Bitwarden "dsserver restic repository", "Beacon restic repository" |
| dsnas logins for the repositories | Bitwarden "dsnas - dsserver-backup", "dsnas - beacon-backup" |
| dsnas administration | Bitwarden (DSM admin); `https://192.168.68.112:5001` works without DNS or valid certificates |
| GitHub, Cloudflare, Healthchecks, Firebase, Tailscale consoles | owner's accounts in Bitwarden; service credentials themselves are inside the encrypted backups |

## 1. Restore a host's backup onto any Linux machine (TESTED 2026-11-14)
Tested by `backup/recovery-test.sh`, which executes the lines of the block below exactly as written (only the two
interactive credential lines are replaced by files prepared from the same secrets), cross-machine: Beacon's
repository restored on dsserver and dsserver's repository restored on Beacon. Results: backup/README.md.

The share is mounted **read-only**, so a restore can never modify the repository. restic must then be run with
`--no-lock`: without it, restic keeps retrying to create its lock file on the read-only mount and appears to hang
(observed: still retrying after 60 s).

<!-- RESTORE-BEGIN -->
```bash
sudo -i                                    # a root shell for everything below (root's home is not readable otherwise)
apt-get install -y restic cifs-utils
install -d -m 0700 /root/rb /root/rb/restore
umask 077
cat > /root/rb/smb.cred                    # type:  username=dsserver-backup  (Beacon: beacon-backup)  <Enter>  password=<from Bitwarden>  <Enter>, then Ctrl+D
cat > /root/rb/restic.pw                   # type the repository password from Bitwarden <Enter>, then Ctrl+D
: "${SHARE:=server-backup}" "${REPO:=dsserver/restic}"     # Beacon: run  SHARE=beacon-backup REPO=beacon/restic  first
mkdir -p /mnt/rb
mount -t cifs "//192.168.68.112/$SHARE" /mnt/rb -o ro,vers=3.1.1,seal,credentials=/root/rb/smb.cred
export RESTIC_REPOSITORY="/mnt/rb/$REPO" RESTIC_PASSWORD_FILE=/root/rb/restic.pw RESTIC_CACHE_DIR=/root/rb/cache
restic --no-lock snapshots
restic --no-lock restore latest --target /root/rb/restore --verify
```
<!-- RESTORE-END -->

The restore is in `/root/rb/restore/` with original owners and permissions. Check the databases before using them:
<!-- VERIFY-BEGIN -->
```bash
for m in /root/rb/restore/var/lib/hostbackup/staging/sqlite/*.manifest.json; do
  python3 -I -c 'import sys, json, hashlib, sqlite3
m = json.load(open(sys.argv[1])); db = sys.argv[1].replace(".manifest.json", ".db")
assert hashlib.sha256(open(db, "rb").read()).hexdigest() == m["sha256"], "sha256"
c = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
assert c.execute("pragma integrity_check").fetchone()[0] == "ok", "integrity"
assert {t: c.execute(f"select count(*) from \"{t}\"").fetchone()[0] for t in m["tables"]} == m["tables"], "rows"
print("ok", m["name"], "matches its manifest")' "$m"
done
```
<!-- VERIFY-END -->

When done (credentials are shredded, the restored copy removed unless you still need it):
<!-- CLEANUP-BEGIN -->
```bash
umount /mnt/rb
shred -u /root/rb/smb.cred /root/rb/restic.pw
rm -rf /root/rb
```
<!-- CLEANUP-END -->

If restic reports a lock on a read-write mount: find out whether a backup job is running (`systemctl status
'hostbackup@*'` on the owning host) before anything else. Never use `unlock --remove-all`.

## 2. Rebuild dsserver (Debian 13) - NOT TESTED as a whole
Does not need Beacon (Beacon only monitors dsserver). Needs: new hardware, Debian 13 installer, GitHub, Bitwarden, dsnas.
1. Install Debian 13 with user `daniel`; the Deco reservation gives it 192.168.68.115.
2. Section 1 (restore dsserver's latest backup to `/root/rb/restore`) and verify the databases.
3. `install -d -m 0700 -o daniel -g daniel /home/daniel/.ssh` and copy back `/root/rb/restore/home/daniel/.ssh`
   (`cp -a`), then `git clone git@github-stacks:dlsamu/dsserver-stacks /srv/stacks` (or `cp -a` it from the restore).
4. Run `host/docs/host-config.md` in order: power, SSH, Docker (`03`), users (`04`), `/srv` (`06`), delegated sudo
   (`09 install <commit>`), unattended upgrades (`07`), heartbeat (`08`), firewall (`10 try`/`confirm`), Tailscale (`11`).
5. Restore state with owners and permissions (`cp -a`): `/etc/dsserver-secrets`, `/etc/stockpulse-secrets`,
   `/etc/cloudflared`, `/srv/appdata` (Caddy, StockPulse data/reports, tunnel).
6. StockPulse database: `install -m 0600 -o 10010 -g 10010 /root/rb/restore/var/lib/hostbackup/staging/sqlite/stockpulse-history.db /srv/appdata/stockpulse/data/history.db`
   (after the manifest check above).
7. `14 build`/`up`, `15 build`/`up`/`verify`, `16 up`/`verify`, local DNS (`dns/local-dns.sh install`), `18 install`,
   Beszel agent (`13`), backups (`19 install-restic`, restore `/etc/dsserver-secrets/backup`, `19 units-install`;
   the existing repository and its identity files are reused).
8. StockPulse timers: only those enabled before (US). intl/ATH stay disabled (rollout plan unchanged).
9. Verify: `15 verify`, `14 verify`, `dns/test-dns.sh`, Beszel shows dsserver, `19 run-backup`, `19 run-drill`.

## 3. Rebuild Beacon (Raspberry Pi 5) - NOT TESTED as a whole
Does not need dsserver: everything comes from GitHub and Bitwarden; any computer can flash the SD card.
1. Flash Raspberry Pi OS Lite with the settings in `beacon/cloud-init` (beacon/README.md; `flash-sd.sh` automates it
   on a Linux machine), boot, log in.
2. On Beacon: `sudo apt-get install -y git` and clone the repository over HTTPS with the owner's GitHub login
   (`git clone https://github.com/dlsamu/dsserver-stacks /root/stacks`); then
   `sudo rsync -a /root/stacks/beacon/ /srv/beacon/` (what `beacon/scripts/deploy.sh` does from dsserver).
3. Section 1 on Beacon itself (`SHARE=beacon-backup REPO=beacon/restic`), verify the databases.
4. Restore with `cp -a`: `/etc/beacon-secrets`, `/etc/dsnas-monitor`, `/srv/appdata/caddy`, `/srv/appdata/netwatch`
   (`netwatch.db` from `staging/sqlite/netwatch.db`), `/root/.ssh` if present.
5. Docker (`beacon/scripts/install-docker.sh`), Beszel hub: copy `staging/sqlite/beszel-data.db` -> `/srv/appdata/beszel/data.db`
   and `beszel-auxiliary.db` -> `auxiliary.db`, `id_ed25519` from the restore, owner 10001, no stale `-wal`/`-shm`;
   start the hub (`docker compose -f /srv/beacon/compose/beszel/compose.yaml up -d`).
6. Firewall (`/srv/beacon/firewall/apply.sh try` then `confirm`), Caddy (`beacon/README.md` HTTPS), local DNS
   (`dns/local-dns.sh install` from a copy of `dns/`), nasmon / certwatch / netwatch units, backups (restic +
   cifs-utils, `/etc/beacon-secrets/backup` restored, `backup/install-units.py`).

## 4. Damaged repository (owner decision; never automatic) - NOT TESTED
Rule: **repairs are first done and verified on a separate copy; the production repository is changed only after
that copy passes.**
1. Stop that host's backup timers: `systemctl stop 'hostbackup-*.timer'`.
2. Copy the repository off the share read-only: mount as in section 1 (ro), `cp -a /mnt/rb/<repo> /var/tmp/repo-copy`.
3. On the copy: `restic -r /var/tmp/repo-copy check --read-data` -> follow restic's repair documentation
   (`repair index`, `repair packs`, `repair snapshots --forget`) -> `check --read-data` again -> restore a snapshot
   from the copy and verify the databases (section 1, VERIFY).
4. Only when the copy passes: repeat exactly the same repair commands on the production repository (read-write
   mount), then a full check and `19 run-drill`; record it here. The dsnas snapshots keep the pre-repair state.
5. Restart the timers.

## 5. Quarterly manual drill (owner + Claude) - first run TESTED 2026-11-14 (automated cross-machine test)
Restore dsserver's repository on Beacon and Beacon's on dsserver with section 1, using only the Bitwarden
credentials, verify the databases, and for StockPulse run the isolated test against the restored DB
(`15 test-reset`-like copy into the test environment + `15 run-test us`, pushes disabled). Record:

| Date | Restore of | On | Snapshot | Restore time | Result |
|---|---|---|---|---|---|
