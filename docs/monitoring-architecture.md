# Monitoring and alerting architecture

Status: **design, not deployed** (2026-11-10). Nothing in this document is installed yet; each part is a separate approved increment (see [roadmap.md](roadmap.md)).

**Principle:** dsserver is a general-purpose server that also has monitoring, not a monitoring platform. Monitoring stays small, uses bounded resources and storage, and never becomes a dependency of anything else.

## 1. Scope
| Now (dsserver only) | Later (one host at a time, each approved separately) |
|---|---|
| dsserver host metrics, Docker containers, systemd services, an external heartbeat | Raspberry Pis, Replay, the replacement NAS, network devices and internet connectivity, the remote Linux Mint PC |

Out of scope for now: collecting and searching logs centrally, SNMP, and monitoring DATASERVER or Replay. DATASERVER and Replay are **frozen**; see [nas-replacement-requirements.md](nas-replacement-requirements.md).

## 2. Constraints (targets, to be confirmed by measurement)
| | Target for all local monitoring together |
|---|---|
| RAM | < 256 MB |
| CPU | < 1% of one core on average while idle |
| Persistent data | ≤ 1 GB to start |
| Polling | Beszel's fixed 60 s interval; no faster polling |
| Exposure | **Nothing reachable from the internet.** The dashboard binds to 127.0.0.1 until the firewall phase, after that the LAN only, and later remote sites over a VPN |

Final resource limits are set **only after** a 48-hour benchmark (§8).

## 3. Components and where they run (hybrid model)
| Layer | Component | Runs as | Depends on Docker? | Why it runs there |
|---|---|---|---|---|
| **Outage detection (outside dsserver)** | **Healthchecks.io** (hosted, free plan: 20 checks) | external service | no | It is the only thing that can notice that dsserver is completely gone |
| Host heartbeat and health | `dsserver-health.timer`, a small script plus systemd timer | native, root, every 5 min | **no** | Proves the host, its network and systemd are alive, so it must keep working when Docker is broken |
| Disk health | `smartd` (already running) | native | no | The established tool; Beszel's S.M.A.R.T. needs extra privileges (§6) |
| Security updates | `unattended-upgrades` (planned) | native | no | Essential host function |
| Metrics, history, dashboard, threshold alerts | **Beszel hub** | Docker Compose, `/srv/stacks/beszel`, data in `/srv/appdata/beszel` | yes | An ordinary application |
| Host metrics collection | **Beszel agent** | **native** systemd service, user `beszel`, our own unit file | no | It sees the whole host (filesystems, sensors, systemd) without privileged container mounts |

**Alert flow**, deliberately with only two channels and no overlap:
- **Host-critical problems → Healthchecks.io → email to the Gmail inbox** (receive only). These are: dsserver down, internet down, failed systemd units (including the update service), a disk-health failure, and a full root disk. The heartbeat script reports a single *state* (ok or fail, with the reason in the ping body), so the alert clears itself when the problem goes away. No SMTP is configured on dsserver.
- **Metric thresholds and other hosts → Beszel → a push channel** (ntfy, Telegram or Pushover; **your decision**). These are: CPU, memory, disk, temperature, container health, and up/down for future hosts. Beszel has no email channel that works without SMTP.
- **Beszel itself** sends its own heartbeat to a second Healthchecks check, so a dead monitoring stack raises an email too.

## 4. Beszel evaluation
Version checked: **v0.21.1** (2026-10-22), MIT licence, about 27k GitHub stars, one main maintainer, **pre-1.0**. Sources: beszel.dev guide pages and the GitHub source and releases, read 2026-11-10.

| Requirement | Verdict | Notes |
|---|---|---|
| Lightweight host monitoring | ✅ | A single Go binary for the agent, a PocketBase application for the hub. **No resource figures are published**, so we measure ourselves (§8) |
| CPU, memory, disk, disk I/O, network | ✅ | Also load average, temperatures, swap, extra filesystems and Btrfs pools |
| History with bounded retention | ✅ fixed | Hard-coded in the source: 1-min records kept 1 h, 10-min 12 h, 20-min 24 h, 2-h records 7 days, 8-h records **30 days**. Old records are deleted hourly. **Not configurable**, but bounded; the expected size is tens of MB per host (to be measured) |
| Docker monitoring | ✅ with care | CPU, memory, network and health per container, plus image-update flags. It needs Docker API access; see §6 |
| systemd services | ✅ | Status, CPU and memory for each service, and an alert when a service fails. The native agent also shows recent journal lines |
| Availability | ⚠️ partly | Hosts are marked up or down. Its "network monitors" (ICMP/TCP/HTTP/DNS, run from an agent) can check routers, the internet and web endpoints. It can't detect **its own** host failing; Healthchecks.io covers that |
| Configurable alerts | ✅ | Status, CPU, memory, disk, bandwidth, load, temperature, I/O wait, container health, failed services, certificate expiry. S.M.A.R.T. alerts are automatic and can't be configured |
| Multi-host expansion | ✅ | One hub with many agents. Linux, FreeBSD, Windows, macOS, and a Synology package exist |
| Secure remote agents | ✅ in WebSocket mode | The agent connects **out** to the hub with a per-host token, and the hub checks the agent's fingerprint. In the older SSH mode the hub doesn't verify the agent's host key, so we don't use it. Across the internet the hub would have to be reachable, so remote hosts go **through a VPN** instead (§7) |
| Upgrades | ⚠️ | Releases come every 2–3 weeks and **breaking changes do happen** (v0.19.0 started verifying TLS certificates). We pin versions, turn **agent auto-update off**, read release notes, and upgrade hub and agent together |
| Backup and recovery | ✅ | Stop the hub and copy `/srv/appdata/beszel`, or use its built-in backup. Losing the history is acceptable; only settings and tokens matter |
| Email alerts without SMTP | ❌ | Needs a push channel (§3) |
| **Central log collection and search** | ❌ | It only shows recent per-host journal and container logs in the dashboard. Not a log system (§5) |
| **Network devices by SNMP** | ❌ | Only ping/TCP/HTTP/DNS reachability from an agent. That is enough for "is the router or internet up"; there's no interface statistics |
| **Synology disk and storage health** | ⚠️ | A Synology agent package exists, but the NAS requirements say no added applications. **Plan:** the NAS's own S.M.A.R.T., storage-pool and scrub notifications, plus a Beszel ping/SMB monitor for reachability. Decide when the NAS arrives |
| **Devices that are intentionally off** | ⚠️ | An agent that is off shows as down. Use per-host alert settings: no status alert for devices that are usually off, or only ping monitors |
| **Monitoring across networks** | ⚠️ | Not without exposing the hub. Use a VPN (Tailscale or WireGuard), a separate future decision |

**Significant concerns:**
1. **The install script grants too much.** `install-agent.sh` adds the `beszel` user to the **`docker` group, which is equivalent to root**, and to the **`disk` group** (raw read access to every disk). It may also enable a daily **auto-update running as root**. **Mitigation:** don't use the script. Install the pinned `.deb` or binary from the GitHub release (checksum verified) and write our own reviewed unit file with no `docker`/`disk` groups and no update timer.
2. **Pre-1.0 and fast-moving.** Pin the version, upgrade by hand, and treat each upgrade as a small change with a rollback (the previous image plus a data copy).
3. **One maintainer** (a bus-factor risk). It's acceptable because Beszel is not critical: if it disappears, the heartbeat and smartd alerts still work, and swapping the dashboard affects nothing else.

**Conclusion:** Beszel fits, with the controls above. The independent heartbeat, smartd and logs stay outside it on purpose.

## 5. Logs
- **Now: local only.**
  - The host journal is persistent (`/var/log/journal`, currently 12 MB). Its default cap is 10% of the filesystem, up to 4 GB. A small drop-in can set an explicit, smaller limit (roadmap, optional).
  - Docker uses the daemon-wide `local` log driver. It keeps logs across container restarts and rotates them; the defaults are 5 files of 20 MB per container. Logs are deleted when a container is **removed** (`down`), not when it is restarted.
  - Application data and logs written to disk live in `/srv/appdata/<service>`, never in Git.
- **Troubleshooting commands:**
  - `journalctl -b -p warning`
  - `journalctl -u <unit> --since -1h`
  - `journalctl -b -1` (the previous boot)
  - `sudo docker compose -f /srv/stacks/<svc>/compose.yaml logs --tail 200 -t`
  - `/var/log/unattended-upgrades/`
  - `sudo smartctl -a /dev/nvme0n1`
- **Expansion path, only if a real need appears, smallest first:**
  1. Beszel's per-host log view.
  2. Forward selected hosts' journals to dsserver with `systemd-journal-remote`, a native Debian package with no new database. Searched with `journalctl`.
  3. Only if search across many hosts becomes a real problem: VictoriaLogs (a single binary). Loki and Elasticsearch-type stacks are out of scope.

## 6. Agent permissions and the Docker socket
- **Read-only Docker socket access doesn't exist.** A `:ro` bind mount of `docker.sock` still gives full API access, and anything that can reach the socket is effectively root. So:
  - the agent **isn't** in the `docker` group and gets no socket mount
  - Docker metrics come through a **filtering socket proxy** container that allows only read-only container-list and stats calls, published on a Unix socket or 127.0.0.1 only. Beszel supports this through `DOCKER_HOST`
  - or Docker monitoring is left off at first. **Your decision**
- **S.M.A.R.T. in Beszel: off.** It needs `CAP_SYS_ADMIN` or the `disk` group for NVMe. smartd already does this as root and reports through the heartbeat.
- **The agent unit** is sandboxed: `User=beszel`, `NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=read-only`, `PrivateTmp`, plus `systemd-journal` group membership for the log view (it can read the logs, not change them). Memory and CPU caps are set after the benchmark.
- **Agent ↔ hub:**
  - WebSocket mode with `DISABLE_SSH=true`: the agent opens **no listening port** and connects to `http://127.0.0.1:8090`, the hub's port published on localhost only.
  - The agent token is kept in `/etc/beszel-agent/env` (root 0600, outside Git).
- **Dashboard access before the firewall:**
  - `ssh -L 8090:127.0.0.1:8090 daniel@dsserver` from dsoffice or Windows.
  - Hub password login, with the admin password kept in your password manager.

## 7. Expansion strategy
1. Each new Linux host gets a native agent: a pinned `.deb`, our unit file, WebSocket mode and a per-host token, added one at a time.
2. Network, router and internet: Beszel network monitors (ping, DNS, HTTPS), run from the dsserver agent.
3. Replacement NAS: DSM's own notifications plus Beszel reachability monitors (§4).
4. Remote sites such as the Linux Mint PC: only through a VPN. The hub is never published to the internet.
5. Replay: only after its backup has finished and been verified, and only read-only checks (ping/HTTP).

## 8. Measuring resource use (before limits are set)
- Run the hub and agent for 48 h at the 60 s default with dsserver as the only host.
- Record:
  - RAM, the average and peak from `systemctl show beszel-agent -p MemoryCurrent,MemoryPeak` and `sudo docker stats --no-stream`
  - CPU time per hour (`CPUUsageNSec` and the container's CPU)
  - the database size (`du /srv/appdata/beszel`) at 1 h, 24 h and 48 h
  - bytes written (`/proc/<pid>/io`, `write_bytes`)
- Then set the compose `mem_limit`/`cpus` and the unit's `MemoryMax=` at about 2× the observed peak, and record the numbers in this document.

## 9. Failure scenarios
| Failure | Detected by | Notes |
|---|---|---|
| dsserver powered off, kernel hang, network cable out | Healthchecks (heartbeat missing) | Takes up to 5 min plus the grace period |
| Internet down at home | Healthchecks (heartbeat missing) | **Can't be told apart** from the server being down; check the other devices |
| Docker daemon dead | Heartbeat state = fail (`docker.service` failed), and Beszel stops | The heartbeat doesn't depend on Docker |
| Beszel hub dead | Second Healthchecks check (hub heartbeat missing) | |
| An application down, host fine | Beszel container-health alert, or a failed systemd unit | **The heartbeat alone can't see this.** A service without a health check is invisible; every service needs one (README convention 2) |
| Disk failing | smartd → heartbeat state = fail | Already-failing drives are reported as soon as smartd checks |
| Security updates failing | Heartbeat state = fail (failed unit, or update log too old) | |
| Disk full | Heartbeat (root above 90%) and a Beszel disk alert | Both: the heartbeat covers it if Beszel is dead |
| Healthchecks.io itself down | Not detected | Accepted risk; also note its **100-entry ping log** and **20-check limit** on the free plan |
| Push channel down | Beszel alerts lost | Accepted; host-critical alerts go by email via Healthchecks |
| Clock drift or DNS failure on dsserver | The heartbeat's HTTPS ping fails, so it shows as down | Fail-safe (a false alarm rather than silence) |

## 10. Secrets (never in Git)
| Secret | Where |
|---|---|
| Healthchecks ping URLs (anyone who has one can ping) | `/etc/dsserver-health/ping-url` (root 0600), and the hub's in `/srv/stacks/beszel/.env` (0600, git-ignored) |
| Beszel agent token | `/etc/beszel-agent/env` (root 0600) |
| Beszel admin password | your password manager only |
| Push-channel URL or token | inside the Beszel hub database (`/srv/appdata`) |
