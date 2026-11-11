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

**Start at boot (dsserver), checked but not rebooted:** `beszel-agent.service` enabled (multi-user.target, `Restart=always`), `docker.service` enabled, proxy `restart: unless-stopped`, tmpfiles entry recreates `/run/beszel-docker` before Docker starts. The same set-up survived a real reboot on Beacon.

**Not tested:**
- a real Status/down alert (machine off for > 5 min) and the Healthchecks "Beacon down" email (planned separately)
- a dsserver reboot

**Known limitation:** ntfy messages are titled "Beacon" (`?title=Beacon` in the ntfy URL), which replaces Beszel's own titles, so a message doesn't say which machine it is about or whether it is an alert or a recovery. Removing `?title=Beacon` in Dashboard → Settings → Notifications fixes that (not changed yet).
