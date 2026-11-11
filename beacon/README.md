# Beacon — home monitoring appliance

Raspberry Pi 5 (8 GB), Raspberry Pi OS Lite 64-bit (Debian 13 trixie), 128 GB microSD, wired Ethernet with DHCP: `beacon.local` / **192.168.68.121**. Headless. Runs **Beszel 0.21.1**: the hub on Beacon, agents on monitored hosts. Everything is reproducible from this directory (`/srv/stacks/beacon` on dsserver, deployed to `/srv/beacon` on Beacon).

## Architecture

```
 phone (ntfy app) <── ntfy.sh <── Beszel alerts ──┐          Healthchecks.io ──email──> Gmail
                                                  │            ▲ check "beacon"   ▲ check "dsserver-host"
 browser (LAN) ──http :8090──> Beacon: Beszel hub (Docker) ─────┘ (hub heartbeat)  │ (dsserver-health, A2)
                                 ▲   ▲   network checks run by Beacon's agent      │
          WebSocket (outbound)   │   │                                             │
     Beacon agent (native) ──────┘   └────── dsserver agent (native) ──────────────┘ dsserver
          │ docker stats                          │ docker stats
          ▼                                       ▼
     socket-proxy (allowlist)                socket-proxy (allowlist)
```

| Piece | Where | Notes |
|---|---|---|
| Hub (dashboard, history, alerts) | Beacon, Docker Compose `compose/beszel`, host network, port 8090 | Image pinned by digest. Non-root (uid 10001), read-only root filesystem, no capabilities, 512 MB limit, Docker healthcheck, `local` log driver 3 × 10 MB, `restart: unless-stopped` |
| Hub data | Beacon `/srv/appdata/beszel` (0700, uid 10001) | PocketBase: users, systems, alerts, tokens, metrics. Retention is fixed by Beszel at about 30 days (1-minute to 8-hour tiers), a few MB |
| Agent | native `beszel-agent.service` on each host (`agent/`) | Release tarball with pinned SHA-256 (the upstream `.deb` and install script add the user to the `docker` group, so they are not used). User `beszel`, not in the docker, disk or sudo groups; sandboxed; `DISABLE_SSH=true`, so it opens no port; connects **out** to the hub |
| Docker metrics | `compose/socket-proxy` (wollomatic/socket-proxy 1.13.2) on each Docker host | Allows only `GET /version`, `/info`, `/containers/json`, `/containers/<id>/stats`. Everything else is refused (403/405), including inspect (environment variables), logs, archive/export, exec and every write. The socket `/run/beszel-docker/docker.sock` sits in a 0750 directory owned by uid 64001 and group `beszel`, so only the agent can open it. No network, read-only, no capabilities |
| Firewall | Beacon, native nftables `firewall/` (`beacon-firewall.service`) | Incoming dropped by default; SSH 22, hub 8090 and mDNS allowed from 192.168.68.0/24 only. `nftables.service` stays disabled (its config flushes Docker's rules) |
| OS | native | unattended-upgrades (Debian + Raspberry Pi archive), no automatic reboot; sshd key-only, `AllowUsers daniel`; journald capped at 500 MB; memory cgroup enabled (`cgroup_enable=memory` in `cmdline.txt`, needed for container memory figures and limits) |
| API automation | `scripts/bz` on dsserver → `beszel_api.py` on Beacon, account `automation@beacon.lan` (role user) | See "Automation (API)" |
| Detecting a dead Beacon | the hub's built-in heartbeat (POST every 60 s) → Healthchecks.io check `beacon` (period 5 min, grace 10 min) → email | **Active** since 2026-11-11 08:11; set with `scripts/set-heartbeat.sh` |

## Access
- Dashboard: **http://beacon.local:8090** (or http://192.168.68.121:8090), home LAN only. Login `admin@beacon.lan`; the password is in your password manager (Bitwarden) only. The plaintext copies on dsserver and Beacon were deleted on 2026-11-11. Forgotten: see Recovery.
- SSH: `ssh beacon` from dsserver (key `~/.ssh/beacon_admin`, passwordless sudo on Beacon).
- Not reachable from the internet or the tailnet.

## What is monitored
| System | What | How |
|---|---|---|
| **beacon** | CPU, load, memory, swap, disk usage and I/O, temperatures, network, systemd services, containers (health, CPU, memory) | local agent |
| **dsserver** | the same, plus its Docker containers (through its own socket proxy) | native agent, installed 2026-11-11 with `host/scripts/13-beszel-agent.sh install` (delegated sudo, see host-config §11). Connects out to 192.168.68.121:8090; dsserver's firewall unchanged |
| Home network | Deco gateway 192.168.68.1 (ping, 60 s); dsserver 192.168.68.115 (ping, 60 s); internet 1.1.1.1 (ping, 60 s); DNS through the Deco (`deb.debian.org` via 192.168.68.1, 5 min); HTTPS https://deb.debian.org/ (5 min) | Beszel network monitors, run by Beacon's agent |
| Disk health (dsserver) | SMART | stays with smartd and the dsserver heartbeat (A2). Beszel's SMART needs disk-group or root access |

## Alerts (sent to the ntfy topic in `~/ntfy-beacon.txt`, server ntfy.sh)
Owned by the automation account and managed with `bz` (see "Automation (API)"): e.g. `bz alerts`, `bz set-alert dsserver Disk 85 10`.
Notification URL (Dashboard → Settings → Notifications): `ntfy://ntfy.sh/<topic>` with **no** `?title=`, so Beszel's own titles come through, e.g. "dsserver disk usage above threshold" / "… below threshold": machine name plus problem or recovery.
| Alert | Systems | Fires when |
|---|---|---|
| Status | beacon, dsserver | down for 5 min |
| Disk | both | above 85 % averaged over 10 min |
| Memory | both | above 90 % over 15 min |
| Temperature | both | above 75 °C over 10 min |
| Failed systemd service | both | any, for 5 min |
| Container unhealthy | both | for 5 min |
| Network monitor loss | beacon's 5 checks | above 20 % loss over the last hour |

Each alert sends a recovery message when it clears. Beszel can't announce that Beacon or the hub itself is gone; that's the Healthchecks heartbeat (email). During an internet outage ntfy can't deliver; Healthchecks then misses both heartbeats (dsserver and beacon) and emails once the connection returns.

## Everyday operations (run on dsserver)
| Task | Command |
|---|---|
| Deploy config changes | `bash /srv/stacks/beacon/scripts/deploy.sh` (rsync to Beacon, then `compose up -d`; only changed containers are recreated) |
| Update Beszel | Read the release notes, then `bash /srv/stacks/beacon/scripts/update-beszel.sh <version>`. It re-pins the image digest and agent checksums from Docker Hub/GitHub, shows the diff, backs up, deploys the hub and Beacon's agent, and prints the steps for dsserver's agent (commit, refresh the delegated-sudo snapshot with `09-delegated-sudo.sh install <commit>` in Konsole, then `sudo -n /usr/local/lib/dsserver-admin/host/scripts/13-beszel-agent.sh install` and `verify`). There are no automatic application updates |
| Back up hub data | `bash /srv/stacks/beacon/scripts/backup-hub.sh` → `~/beacon-backups/` (keeps 10; stops the hub for about 10 s). Done automatically before updates; otherwise monthly is enough (losing metric history is acceptable; settings and tokens matter) |
| Status | `ssh beacon 'sudo docker ps; systemctl status beszel-agent beacon-firewall --no-pager'`; dsserver: `sudo -n /usr/local/lib/dsserver-admin/host/scripts/13-beszel-agent.sh status` (or `verify`) |
| Logs | `ssh beacon 'sudo docker logs --tail 100 beszel-hub; journalctl -u beszel-agent -n 50'` |
| Firewall change | edit `firewall/beacon-firewall.nft`, `deploy.sh`, then on Beacon `sudo /srv/beacon/firewall/apply.sh try`, test a **new** SSH connection, `apply.sh confirm` (otherwise it's removed automatically after 5 min) |
| OS updates | automatic. Reboot when `/var/run/reboot-required` exists: `ssh beacon sudo systemctl reboot` (everything comes back by itself) |
| Bootloader | Beacon runs the May 2025 EEPROM; 2026-10-30 is available. When convenient: `ssh beacon 'sudo rpi-eeprom-update -a && sudo systemctl reboot'` |

`docker stop` and `docker kill` count as deliberate stops (no automatic restart); start again with `deploy.sh`. Crashes and reboots recover automatically (tested).

## Adding another machine
**Linux host with an agent**
1. Dashboard → **Add System**: enter the name, keep the default port, and copy the **token** and the hub's **public key** shown in the dialog.
2. On that machine, create an env file (root, 0600) with: `HUB_URL=http://192.168.68.121:8090`, `TOKEN=<token>`, `KEY="<public key>"`, `SYSTEM_NAME=<name>`, and either `DOCKER_HOST=unix:///run/beszel-docker/docker.sock` (Docker hosts) or `DOCKER_HOST=` (no Docker).
3. Copy `agent/` (and `compose/socket-proxy/` for Docker hosts) to it and run `sudo bash install-agent.sh <env-file> [--with-docker-proxy]`.
4. Dashboard → the system's bell icon: switch on the same alerts as above.

**Other cases**
- **Father's laptop** (remote): first put Beacon on the tailnet and allow 8090 on `tailscale0` in `beacon-firewall.nft`; then the agent uses Beacon's tailnet address as `HUB_URL`. No Status alert (it's often off).
- **New Synology NAS:** reachability first (ping and TCP 5001 network monitors on beacon), plus DSM's own notifications for disks, pools and scrubs. The Synology Beszel package is optional later.
- **Replay and devices you don't want to touch:** a ping or TCP network monitor only, no agent, and no Status alert for devices that are normally off.

## Automation (API)
Claude (or you) administers Beszel from dsserver with **`bash /srv/stacks/beacon/scripts/bz <command>`**, through Beszel's own REST API (PocketBase). No dashboard, no extra service or port.

| Item | Setting |
|---|---|
| Identity | `automation@beacon.lan`, Beszel role **`user`** (not `admin`, not a PocketBase superuser). Created 2026-11-11 by `scripts/setup-automation.sh` → `bootstrap_automation.py` |
| Why `user` is enough | non-`readonly` users may create/change/delete systems, agent tokens and network checks and read all metrics; `admin` only adds heartbeat status and config export. ntfy.sh is a public address, so its alerts are delivered for a `user`-role owner too |
| Reaching all systems | hub env `SHARE_ALL_SYSTEMS=true` (`compose/beszel/compose.yaml`): every signed-in account may see/manage every system. Only two accounts exist (yours and automation) |
| Credential | random password in **`/root/beszel-automation/credentials`** on Beacon (root 0600, dir 0700). Never copied to dsserver, Git, logs or chat; never in a command line |
| Each call | `bz` runs `ssh beacon sudo python3 -I /srv/beacon/scripts/beszel_api.py METHOD PATH` (body on stdin). It logs in, uses the session token once in memory, and drops it (nothing cached). Hub on 127.0.0.1:8090 only |
| Output | tokens, passwords, agent fingerprints, notification URLs (the ntfy topic) and Healthchecks URLs are replaced by `<redacted>` |
| Notifications of its own alerts | the account has its own notification settings: a copy of the ntfy URL, e-mail off |

**Commands:** `systems`, `alerts`, `monitors`, `set-alert SYSTEM TYPE VALUE MIN`, `del-alert SYSTEM TYPE`, `add-system NAME HOST` (writes `~/.beszel-agent-NAME.env`, 0600, for the agent installer), `remove-system NAME --yes`, `pause NAME`, `resume NAME`, `test-notify`, `api METHOD /api/...` (anything else in the [PocketBase API](https://pocketbase.io/docs/api-records/); body on stdin).

**Limits:**
- **Alert ownership (since 2026-11-11 10:00):** all 13 alert rules are owned by **`automation@beacon.lan`**, so `bz alerts`, `set-alert` and `del-alert` manage them. They were transferred **in place** with `scripts/alert-ownership.sh migrate`: the same records and IDs, thresholds, durations and state, and alert history untouched. A temporary superuser was used and removed, and its removal verified. The snapshot is in `/root/beszel-automation/alert-ownership/` on Beacon. They notify the ntfy URL in the **automation account's** settings, a copy of yours. If the topic ever changes, change it there too: `bz api PATCH /api/collections/user_settings/records/<id>`. In the dashboard your account no longer shows them in the bell dialogs; history from before the transfer stays with your account.
- **Rollback** (all 13 back to your account, same IDs; temporary superuser again, removed and verified; refuses while an alert is firing): `bash /srv/stacks/beacon/scripts/alert-ownership.sh rollback` → `ROLLBACK DONE`. Read-only state check: `... alert-ownership.sh check`. **Run the rollback before revoking the automation account**: deleting the account deletes the alerts it owns.
- Your notification settings and account can't be changed by it (by design); creating or deleting **accounts** needs a superuser (Beszel has no other mechanism).
- Heartbeat status/test and config export need role `admin` (not granted).

**Rotate the password** (Beacon, root): needs a temporary superuser like the bootstrap: simplest is revoke + bootstrap again (below); alerts owned by the automation account would be lost, so list them first (`bz alerts`).

**Revoke:** 0. First `alert-ownership.sh rollback` (see above). 1. Dashboard → `http://beacon.local:8090/_/` (your login) → Collections → *users* → `automation@beacon.lan` → Delete (this ends all its sessions and deletes its own alerts and notification settings). 2. `ssh beacon 'sudo rm -r /root/beszel-automation'`. 3. Optional: remove `SHARE_ALL_SYSTEMS` from `compose/beszel/compose.yaml` and run `scripts/deploy.sh`. To start over afterwards: `bash /srv/stacks/beacon/scripts/setup-automation.sh`.

**Bootstrap safety (how the account was made):** a temporary superuser with a random password is created with Beszel's CLI, used for the account and its notification settings only, deleted in a `finally` block and verified gone (superuser list equal to the snapshot; its login refused). A read-only snapshot of alerts, your account, notification settings, systems, network checks, agent tokens and history counts is compared before/after.

## HTTPS (https://beacon.rubusdua.net)
Design, Cloudflare token and DNS setup: [docs/https.md](../docs/https.md). Caddy (container `caddy`, host network,
443/tcp from the LAN) proxies to the hub on 127.0.0.1:8090; certificate from Let's Encrypt via DNS-01, renewed automatically.
Run on dsserver: `bash /srv/stacks/beacon/scripts/https.sh build|test-local|token-install|token-check|up|verify|status|down`.
The existing http://192.168.68.121:8090 path stays until the approved cutover; break-glass: `ssh -L 8090:127.0.0.1:8090 beacon`.
Secret: `/etc/beacon-secrets/cloudflare.env` (root 0600). Data: `/srv/appdata/caddy`.

## Recovery
| Situation | What to do |
|---|---|
| Hub or proxy crashed | Nothing: Docker restarts it (tested, ~2 s) |
| Agent crashed | Nothing: systemd restarts it (tested, ~10 s, on both hosts) |
| dsserver agent or proxy misbehaving | `sudo -n /usr/local/lib/dsserver-admin/host/scripts/13-beszel-agent.sh verify`; reinstall in place with `... 13-beszel-agent.sh install` (uses `/etc/beszel-agent/env`). Removal (by hand, root): `systemctl disable --now beszel-agent; docker compose -p beszel-socket-proxy down; rm /etc/systemd/system/beszel-agent.service /etc/tmpfiles.d/beszel-docker.conf /usr/local/bin/beszel-agent; rm -r /etc/beszel-agent /var/lib/beszel-agent; deluser beszel` |
| Beacon hangs or is unreachable | Power-cycle it (tested headless boot: SSH back in ~15 s, all services start) |
| **microSD failed** | 1. New card in the USB reader on dsserver. 2. `sudo bash /srv/stacks/beacon/flash-sd.sh /srv/stacks/beacon/images/2026-10-06-raspios-trixie-arm64-lite.img.xz` (or a newer image: update the pinned hash and device size in the script). 3. Boot. Remove the old line from `~/.ssh/known_hosts_beacon`, connect once with `ssh -o StrictHostKeyChecking=accept-new beacon`, and compare the fingerprint with `ssh beacon ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. 4. `ssh beacon 'sudo bash -s' < /srv/stacks/beacon/setup-base.sh`, then reboot (memory cgroup). 5. `ssh beacon 'sudo bash -s' < /srv/stacks/beacon/scripts/install-docker.sh`. 6. `bash /srv/stacks/beacon/scripts/deploy.sh`. 7. Firewall: `apply.sh try`, test, `confirm`. 8. **Restore** the newest backup (below). 9. Beacon's agent: create a new token for system *beacon* (Dashboard → system → settings), write its env file, run `install-agent.sh ... --with-docker-proxy`. 10. `set-heartbeat.sh` again. Agents on other hosts reconnect by themselves (same hub key, from the backup) |
| **Restore hub data** | `scp ~/beacon-backups/<newest>.tar.gz beacon:/tmp/b.tgz`, then `ssh beacon 'sudo docker stop beszel-hub; sudo rm -rf /srv/appdata/beszel; sudo tar -C /srv/appdata -xzf /tmp/b.tgz; sudo chown -R 10001:10001 /srv/appdata/beszel; sudo docker start beszel-hub; rm /tmp/b.tgz'` (tested 2026-11-10 into a temporary hub: healthy, users intact) |
| Forgotten dashboard password | `ssh beacon 'sudo docker exec beszel-hub /beszel superuser upsert admin@beacon.lan <new password>'`, log in at http://beacon.local:8090/_/ and reset the user's password there |

## Secrets (none in Git)
| Secret | Where |
|---|---|
| Dashboard admin password | your password manager only |
| ntfy topic (works like a password) | `~/ntfy-beacon.txt` (dsserver, 0600) and inside the hub database |
| Agent tokens | `/etc/beszel-agent/env` on each host (root 0600); the staging copy on dsserver was deleted after install |
| Healthchecks ping URL | `/srv/beacon/compose/beszel/hub.env` on Beacon (root 0600), written by `scripts/set-heartbeat.sh` |
| Hub private key | `/srv/appdata/beszel/id_ed25519` and the backups in `~/beacon-backups/` (0700) |

## Install history
- 2026-11-10: flashed with `flash-sd.sh` (Pi OS Lite 2026-10-06; SHA-256 and GPG verified; read-back compared). First boot via cloud-init (`done`; harmless warning about a missing `cc_netplan_nm_patch` module). Host key ED25519 `SHA256:418PbwFoGJ9+lZdnllHq0NLDFNOKr86v76L8KIDB8hs`. Admin key `SHA256:FUeaboVVG1shD6LYcaBEbHi0qHNHwzHEB8cPmJNlIaM` (no passphrase).
- 2026-11-10 23:00: 40 updates applied, kernel 6.18.60, reboot verified.
- 2026-11-10 23:20–23:50: Docker 29.9.3 (official repository), firewall, Beszel hub, agent and socket proxy, alerts, network monitors, ntfy; memory cgroup enabled (reboot).
- 2026-11-11 08:06: ntfy test alert + recovery; phone delivery of the alert confirmed by you.
- 2026-11-11 08:11: Healthchecks heartbeat enabled (`set-heartbeat.sh`); check `beacon` green (confirmed by you).
- 2026-11-11 08:27: dsserver agent 0.21.1 + socket proxy installed (`13-beszel-agent.sh install`), system resumed in Beszel. Admin password moved to Bitwarden; plaintext files deleted.
- 2026-11-11 09:21: ntfy titles fixed; Beacon outage detection and dsserver alert/recovery tested.
- 2026-11-11 09:37–09:48: `SHARE_ALL_SYSTEMS=true` (hub recreated); automation account bootstrapped by you (`BOOTSTRAP DONE`) and tested through the API.
- 2026-11-11 10:00: 13 alerts transferred to the automation account (`alert-ownership.sh migrate`, approved by you).

## Verification
**Tested 2026-11-10 (Beacon):**
- hub health, admin login, API
- firewall: new SSH, hub and ping from the LAN work; a closed port is dropped; the 5-minute automatic revert was armed and cancelled
- socket proxy: the 4 allowed endpoints return 200; inspect, logs, archive, export, images, events and versioned paths return 403; HEAD, POST, PUT and DELETE return 405; only the `beszel` group can open the socket
- Beacon metrics, temperatures, services and containers (including memory after enabling the memory cgroup); all 5 network monitors (0 % loss)
- a real alert (disk threshold lowered to 1 %) fired in 56 s and recovered
- history kept across two hub recreations and a reboot; backup, and restore into a temporary hub
- crash recovery: hub and proxy SIGKILL → Docker restart in ~2 s; agent SIGKILL → systemd restart ~10 s; reconnect
- reboot: SSH back in ~15 s, all units active, firewall loaded, agent reconnected (it started 2 s before the proxy and still got container data, so no start-order dependency is needed)

**Tested 2026-11-11:**
- **phone:** the Beacon disk test alert (08:06) arrived in the ntfy app (confirmed by you); its recovery (08:11) reached ntfy.sh
- **heartbeat:** the hub POSTs every 60 s; Healthchecks check `beacon` green
- **dsserver agent** (`13-beszel-agent.sh verify`, 23 checks passed): service active and enabled, runs as `beszel` (groups: beszel only), no listening port, connected to the hub; env file root 0600; proxy running with `unless-stopped`; `/run/beszel-docker` 64001:beszel 0750 and recreated at boot by tmpfiles; the allowlist through the proxy as user `beszel`: version/info/containers/stats 200, inspect/logs/images/events 403, POST/DELETE 405; `nobody` cannot reach the socket. No other container existed or was touched
- **dsserver in Beszel:** up, with CPU, memory (31 GB), disk usage and I/O, network (eno1, tailscale0), 12 temperature sensors, 61 systemd services (0 failed) and the proxy container's CPU/memory
- **dsserver alert:** disk threshold lowered to 1 % at 08:32:14 → ntfy 08:32:49; restored to 85 %/10 min → recovery 08:39:49 (both seen on ntfy.sh). All 13 rules back at their values, none firing
- **dsserver crash recovery** (`13-beszel-agent.sh test-recovery`): agent SIGKILL → restarted by systemd in 11 s and reconnected; proxy SIGKILL → restarted by Docker in < 1 s (restart count 0 → 1), allowlist unchanged, container data continued
- **after the tests:** no failed units on either host; dsserver firewall, Tailscale, Docker and the A2 heartbeat unchanged and active; Beacon heartbeat still sending

**Tested 2026-11-11, API automation (all against the running hub):**
- credential dir/file on Beacon root 0700/0600; accounts: yours (`admin`) + `automation@beacon.lan` (`user`, verified); 1 superuser (yours; the temporary one is gone)
- read: own account, `systems` (both up, live CPU/mem/disk), `monitors` (5 checks), containers, systemd services (108 records), hub info, own notification settings (redacted)
- refused as intended: your alerts are invisible to it (0 listed); `/api/beszel/heartbeat-status` → 403
- write: created alert dsserver CPU 99 %/60 min (owner automation) → listed → changed to 95 % → deleted → gone
- the 13 existing alerts: all still owned by your account, none firing, content digest identical before and after (`fa8d7ea715cc`); alert history unchanged (4)
- `bz test-notify` → Beszel "Test Alert" reached ntfy.sh 09:46:34
- afterwards: both systems up; `13-beszel-agent.sh verify` passed; no failed units on either host; hub healthy, 0 error lines; heartbeat still every 60 s (09:46:39, 09:47:44)

**Tested 2026-11-11 10:00–10:04, alert ownership transfer (production):**
- rehearsed first on a throwaway copy of the hub (127.0.0.1:18090, notifications disabled): an injected failure after 5 alerts was undone 5/5 with the superuser removed; migrate; the automation account edited a transferred alert (single and bulk) but couldn't give one away; rollback restored all 13 unchanged
- preflight `check` passed: 13 alerts owned by you, none firing; notification URL digests identical; no quiet hours; SMTP off; `SHARE_ALL_SYSTEMS=true`
- `migrate`: 13 owners changed in place; temporary superuser deleted (exit 0), superusers back to 1, its login refused; same alert IDs and every field except the owner unchanged; history, accounts, notification settings, systems, network checks and agent tokens unchanged; metrics kept (338 → 338); the automation account sees all 13 → `MIGRATE DONE`
- afterwards: `bz alerts` lists all 13 with their values; both systems up; dsserver `verify` passed; no failed units on either host; hub healthy, 0 error lines
- **alert test through the API** on the original record `v193rsr5mek62lk`: `bz set-alert dsserver Disk 1 1` at 10:01:04 → ntfy 10:01:47 *"dsserver disk usage above threshold"*; `bz set-alert dsserver Disk 85 10` → 10:02:47 *"dsserver disk usage below threshold"* (both arrived on your phone, confirmed by you)
- final: all 13 alerts identical to the pre-migration snapshot except the owner; your account (role, password hash, token key, last change) unchanged; 1 superuser; heartbeat still every 60 s (10:03:04, 10:03:44)

**Start at boot (dsserver), checked but not rebooted:** `beszel-agent.service` enabled (multi-user.target, `Restart=always`), `docker.service` enabled, proxy `restart: unless-stopped`, tmpfiles entry recreates `/run/beszel-docker` before Docker starts. The same set-up survived a real reboot on Beacon.

**Not tested:**
- a real Beszel Status/down alert (an agent's machine off for > 5 min)
- a dsserver reboot

**Tested 2026-11-11, final reliability tests:**
- **Notification titles:** `?title=Beacon` removed from the ntfy URL (by you, in the dashboard; topic unchanged). dsserver disk threshold set to 1 %/1 min → ntfy 09:14:01 *"dsserver disk usage above threshold"* (arrived on your phone); restored to 85 %/10 min → 09:21:01 *"dsserver disk usage below threshold"*
- **Beacon outage detection:** only `beszel-hub` stopped 08:52:00 (last heartbeat 08:51:57), Beacon, SSH, agents, proxy and firewall kept running. Expected "down" at last ping + 5 min period + 10 min grace ≈ 09:07. Healthchecks' **down email received** (confirmed by you, by 09:10). Hub started 09:10:01, healthy 09:10:07; Beacon agent reconnected 09:10:10, dsserver by 09:11:01; first heartbeat 09:11:01; Healthchecks' **up email received** (confirmed by you). History intact (oldest records from 2026-11-10 22:50 kept, new ones continue); no Beszel alert fired during or after the outage
- **After the tests:** both systems up; all 13 rules at their values, none firing; `13-beszel-agent.sh verify` passed; no failed units on either host; dsserver firewall, Tailscale, Docker and its A2 heartbeat active; heartbeat sending every 60 s

Note: while the hub is stopped the dashboard is unreachable too (it *is* the hub), and Beszel sends no alerts; Healthchecks covers that gap.
