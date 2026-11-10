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
| Detecting a dead Beacon | the hub's built-in heartbeat → Healthchecks.io check `beacon` → email | **Pending:** needs the ping URL (see "Manual steps") |

## Access
- Dashboard: **http://beacon.local:8090** (or http://192.168.68.121:8090), home LAN only. Login `admin@beacon.lan`. The password is in `~/beszel-admin.txt` on dsserver: move it to your password manager, then delete the file. A root-only copy is on Beacon in `/root/beacon-secrets/`.
- SSH: `ssh beacon` from dsserver (key `~/.ssh/beacon_admin`, passwordless sudo on Beacon).
- Not reachable from the internet or the tailnet.

## What is monitored
| System | What | How |
|---|---|---|
| **beacon** | CPU, load, memory, swap, disk usage and I/O, temperatures, network, systemd services, containers (health, CPU, memory) | local agent |
| **dsserver** | the same, plus its Docker containers | agent: **install pending** (needs sudo). The system is *paused* in Beszel until then |
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
| Update Beszel | Read the release notes, then `bash /srv/stacks/beacon/scripts/update-beszel.sh <version>`. It re-pins the image digest and agent checksums from Docker Hub/GitHub, shows the diff, backs up, deploys the hub and Beacon's agent, and prints the one sudo command for dsserver's agent. Commit afterwards. There are no automatic application updates |
| Back up hub data | `bash /srv/stacks/beacon/scripts/backup-hub.sh` → `~/beacon-backups/` (keeps 10; stops the hub for about 10 s). Done automatically before updates; otherwise monthly is enough (losing metric history is acceptable; settings and tokens matter) |
| Status | `ssh beacon 'sudo docker ps; systemctl status beszel-agent beacon-firewall --no-pager'` |
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
| Agent crashed | Nothing: systemd restarts it (tested, ~10 s) |
| Beacon hangs or is unreachable | Power-cycle it (tested headless boot: SSH back in ~15 s, all services start) |
| **microSD failed** | 1. New card in the USB reader on dsserver. 2. `sudo bash /srv/stacks/beacon/flash-sd.sh /srv/stacks/beacon/images/2026-10-06-raspios-trixie-arm64-lite.img.xz` (or a newer image: update the pinned hash and device size in the script). 3. Boot. Remove the old line from `~/.ssh/known_hosts_beacon`, connect once with `ssh -o StrictHostKeyChecking=accept-new beacon`, and compare the fingerprint with `ssh beacon ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`. 4. `ssh beacon 'sudo bash -s' < /srv/stacks/beacon/setup-base.sh`, then reboot (memory cgroup). 5. `ssh beacon 'sudo bash -s' < /srv/stacks/beacon/scripts/install-docker.sh`. 6. `bash /srv/stacks/beacon/scripts/deploy.sh`. 7. Firewall: `apply.sh try`, test, `confirm`. 8. **Restore** the newest backup (below). 9. Beacon's agent: create a new token for system *beacon* (Dashboard → system → settings), write its env file, run `install-agent.sh ... --with-docker-proxy`. 10. `set-heartbeat.sh` again. Agents on other hosts reconnect by themselves (same hub key, from the backup) |
| **Restore hub data** | `scp ~/beacon-backups/<newest>.tar.gz beacon:/tmp/b.tgz`, then `ssh beacon 'sudo docker stop beszel-hub; sudo rm -rf /srv/appdata/beszel; sudo tar -C /srv/appdata -xzf /tmp/b.tgz; sudo chown -R 10001:10001 /srv/appdata/beszel; sudo docker start beszel-hub; rm /tmp/b.tgz'` (tested 2026-11-10 into a temporary hub: healthy, users intact) |
| Forgotten dashboard password | `ssh beacon 'sudo docker exec beszel-hub /beszel superuser upsert admin@beacon.lan <new password>'`, log in at http://beacon.local:8090/_/ and reset the user's password there |

## Secrets (none in Git)
| Secret | Where |
|---|---|
| Dashboard admin password | `~/beszel-admin.txt` (dsserver, 0600) → your password manager; `/root/beacon-secrets/` on Beacon |
| ntfy topic (works like a password) | `~/ntfy-beacon.txt` (dsserver, 0600) and inside the hub database |
| Agent tokens | `/etc/beszel-agent/env` on each host (root 0600). dsserver's, until installed: `~/.beszel-agent-dsserver.env` (0600; deleted by you after install) |
| Healthchecks ping URL | `/srv/beacon/compose/beszel/hub.env` on Beacon (root 0600), written by `scripts/set-heartbeat.sh` |
| Hub private key | `/srv/appdata/beszel/id_ed25519` and the backups in `~/beacon-backups/` (0700) |

## Install history
- 2026-11-10: flashed with `flash-sd.sh` (Pi OS Lite 2026-10-06; SHA-256 and GPG verified; read-back compared). First boot via cloud-init (`done`; harmless warning about a missing `cc_netplan_nm_patch` module). Host key ED25519 `SHA256:418PbwFoGJ9+lZdnllHq0NLDFNOKr86v76L8KIDB8hs`. Admin key `SHA256:FUeaboVVG1shD6LYcaBEbHi0qHNHwzHEB8cPmJNlIaM` (no passphrase).
- 2026-11-10 23:00: 40 updates applied, kernel 6.18.60, reboot verified.
- 2026-11-10 23:20–23:50: Docker 29.9.3 (official repository), firewall, Beszel hub, agent and socket proxy, alerts, network monitors, ntfy; memory cgroup enabled (reboot).

## Verification (2026-11-10)
**Tested:**
- hub health, admin login, API
- firewall: new SSH, hub and ping from the LAN work; a closed port is dropped; the 5-minute automatic revert was armed and cancelled
- socket proxy:
  - the 4 allowed endpoints return 200
  - inspect, logs, archive, export, images, events and versioned paths return 403
  - HEAD, POST, PUT and DELETE return 405
  - only the `beszel` group can open the socket; `nobody` and `daniel` cannot
- Beacon metrics, temperatures, services and containers (including memory after enabling the memory cgroup)
- all 5 network monitors (0 % loss)
- ntfy delivery to ntfy.sh (test message)
- **a real alert fired and recovered:** the disk threshold was lowered to 1 %, the alert arrived in 56 s, and the recovery message came after restoring 85 %
- the hub heartbeat payload, delivered to a local test receiver
- history kept across two hub recreations and a reboot
- crash recovery: hub and proxy SIGKILL → Docker restart in ~2 s; agent SIGKILL → systemd restart ~10 s; reconnect
- reboot: SSH back in ~15 s, all units active, no failed units, firewall loaded, agent reconnected, metrics continued
- backup to dsserver, then restore into a temporary hub
- a dsserver agent test run: unprivileged, a temporary system that was deleted afterwards. It delivered metrics, 12 sensors and 60 services, and its connection passed dsserver's firewall unchanged

**Not yet tested:**
- the Healthchecks heartbeat end to end (no URL yet)
- dsserver's agent as a service, and its Docker metrics through the proxy
- a real Status/down alert
- delivery to your phone (not subscribed yet)
