# Break-glass recovery (dsserver, Beacon, StockPulse)

For the case where a host (or all local infrastructure) is lost. Targets: **RPO 24 h** (nightly backups),
**RTO 2 h** after replacement hardware is available. Measured results: `backup/README.md` "Measurements".

## What you need, and where it lives when everything here is down
| Need | Where (independent of the home infrastructure) |
|---|---|
| This document, all scripts and configuration | GitHub `dlsamu/dsserver-stacks` (private) - and a copy of this file as a Bitwarden secure note "Home infrastructure - recovery" |
| restic repository password, dsserver | Bitwarden "dsserver restic repository" |
| restic repository password, Beacon | Bitwarden "Beacon restic repository" |
| dsnas login for the repositories | Bitwarden "dsnas - dsserver-backup", "dsnas - beacon-backup" |
| dsnas administration | Bitwarden (owner's DSM admin); `https://192.168.68.112:5001` works without DNS or certificates |
| GitHub access from new hardware | owner's GitHub login (Bitwarden) -> add a new deploy key |
| Cloudflare, Healthchecks, Firebase consoles | owner's accounts (Bitwarden); service credentials themselves are inside the encrypted backups |

The backups live on dsnas (`server-backup`, `beacon-backup`), protected by dsnas snapshots (14 daily, 8 weekly,
immutable 7 days once enabled). If dsnas itself is lost: restore dsnas from its own redundancy/second copy first
(roadmap B2/B3), then continue here.

## Restore a host's data (any Linux machine with network access to dsnas)
```bash
sudo apt-get install -y restic cifs-utils
sudo install -d -m 0700 /root/rb && cd /root/rb
# credentials from Bitwarden, typed into root-only files (never on the command line)
sudo sh -c 'umask 077; cat > /root/rb/smb.cred'        # username=dsserver-backup / password=...   (Ctrl+D)
sudo sh -c 'umask 077; cat > /root/rb/restic.pw'       # the repository password                    (Ctrl+D)
sudo mkdir -p /mnt/rb && sudo mount -t cifs //192.168.68.112/server-backup /mnt/rb -o ro,vers=3.1.1,seal,credentials=/root/rb/smb.cred
export RESTIC_REPOSITORY=/mnt/rb/dsserver/restic RESTIC_PASSWORD_FILE=/root/rb/restic.pw
sudo -E restic snapshots                                # pick the snapshot (latest = last night)
sudo -E restic restore latest --target /root/rb/restore --verify
```
(Beacon: share `beacon-backup`, repository `/mnt/rb/beacon/restic`.) Read-only mount: a restore can never damage
the repository. If restic reports a lock, check whether another restore/backup is running before anything else; do
not use `unlock --remove-all`.

## Rebuild dsserver (Debian 13) from the restore
1. Install Debian 13, user `daniel`, network (DHCP reservation 192.168.68.115 is on the Deco).
2. Copy back `/home/daniel/.ssh` (keys) from the restore; `git clone git@github-stacks:dlsamu/dsserver-stacks /srv/stacks`
   (or copy `/srv/stacks` from the restore; it contains the same history).
3. Follow `host/docs/host-config.md` in order: power, SSH, Docker (`03`), users, `/srv` (`06`), delegated sudo
   (`09 install <commit>`), unattended upgrades, health heartbeat, firewall (`10 try/confirm`), Tailscale, Beszel agent.
4. Restore state from `/root/rb/restore` (keep owners/permissions: `cp -a` or `rsync -aHAX`):
   `/etc/dsserver-secrets`, `/etc/stockpulse-secrets`, `/etc/cloudflared`, `/srv/appdata` (Caddy, StockPulse, tunnel).
5. StockPulse database: copy `var/lib/hostbackup/staging/sqlite/stockpulse-history.db` to
   `/srv/appdata/stockpulse/data/history.db` (owner 10010, 0600); first verify it against
   `stockpulse-history.manifest.json` (sha256, `integrity_check`, row counts).
6. `14 build/up` (Caddy), `15 build/up/verify` (StockPulse), `16 up/verify` (tunnel), `17`/`dns/local-dns.sh install`,
   `18 install` (dsnas certificate), `19 install-restic/units-install` (backups; the existing repository is reused:
   restore `/etc/dsserver-secrets/backup` first).
7. StockPulse timers: only those that were enabled before (US); intl/ATH stay disabled (rollout plan).
8. Verify: `15 verify`, `14 verify`, `dns/test-dns.sh`, Beszel shows dsserver up, a manual `19 run-backup`.

## Rebuild Beacon
1. Flash Raspberry Pi OS with `beacon/flash-sd.sh` + cloud-init (beacon/README.md), `ssh beacon` from dsserver.
2. `beacon/scripts/deploy.sh`, Docker (`install-docker.sh`), restore `/etc/beacon-secrets`, `/etc/dsnas-monitor`,
   `/srv/appdata/caddy`, `/srv/appdata/netwatch`.
3. Beszel hub: stop the hub, copy `var/lib/hostbackup/staging/sqlite/beszel-data.db` -> `/srv/appdata/beszel/data.db` and
   `beszel-auxiliary.db` -> `auxiliary.db` (owner 10001; remove stale `-wal`/`-shm`), restore `id_ed25519`, start.
4. Firewall (`firewall/apply.sh try/confirm`), Caddy (`scripts/https.sh up/verify`), local DNS
   (`dns/deploy-beacon.sh install`), nasmon/certwatch/netwatch units, `backup/deploy-beacon.sh install-restic/units-install`.

## Manual repair of a damaged repository (owner decision; never automatic)
1. Stop the timers of that host (`systemctl stop 'hostbackup-*.timer'`).
2. Keep the evidence: the dsnas snapshots of the share already hold earlier states.
3. `restic check --read-data` output decides: follow restic's repair documentation (`repair index`, `repair packs`,
   `repair snapshots --forget`) on the host, then a full check, then a restore drill. Record it here.

## Quarterly manual drill (owner + Claude, from the OTHER machine, only Bitwarden credentials)
Restore dsserver's latest snapshot on Beacon (and Beacon's on dsserver) into a scratch directory with the commands
above, verify the StockPulse DB against its manifest, run the isolated StockPulse test from the restored DB
(`15 test-reset` equivalent with the restored file + `15 run-test us`, pushes disabled), record duration and result:

| Date | From | Snapshot | Restore time | Result |
|---|---|---|---|---|
