# dsserver roadmap

Updated 2026-11-10. Each item is a small increment that is approved separately, with a script in `host/scripts/` or a service directory, copies in `host/files/`, and a section in `host/docs/host-config.md`. Order: **security and reliability first, monitoring second**. Monitoring never delays security updates.

## Done
| Phase | What | Record |
|---|---|---|
| Power | Sleep and hibernation disabled (systemd + Plasma) | host-config §1 |
| SSH | Key-only login, no root login, `AllowUsers daniel axel` | §2 |
| Docker | Docker CE + Compose from Docker's own repository, iptables-nft backend, `local` log driver; daniel not in the `docker` group | §3 |
| axel | Development user: no sudo or Docker, cgroup limits 12G/16G/CPUWeight 50 | §4 |
| GitHub | Separate keys for each user; a deploy key for this repository | §5 |
| /srv | `/srv/stacks` (Git) and `/srv/appdata` (data); bind-mount ownership model tested | §6 |
| NAS | Requirements for the replacement NAS | [nas-replacement-requirements.md](nas-replacement-requirements.md) |

## Next (proposed order)
| # | Increment | Depends on | Who does what |
|---|---|---|---|
| **A1** (done 2026-11-10) | **Automatic security updates:** `unattended-upgrades`, daily, Debian security and stable updates only, **no automatic reboot**, Docker's repository excluded (updated by hand) | — | You run the script in Konsole |
| **A2** (done 2026-11-10) | **External heartbeat and host health state:** a native `dsserver-health` timer (every 5 min) sends one HTTPS ping to Healthchecks.io, marked ok or fail with short codes only (failed host units, disk health, root disk above 90%, updates stale; Docker state and reboot need as information). Healthchecks emails the Gmail inbox | a Healthchecks.io account (yours) | You create the account and check; you install the ping URL in Konsole (hidden input) |
| A0 (installed 2026-11-10) | **Delegated sudo:** exact, root-owned script commands without a password, so Claude can run approved steps | — | You run `09-delegated-sudo.sh install` once in Konsole (host-config §11) |
| **A3** (done 2026-11-10) | **Firewall:** our own nftables table (IPv4+IPv6), incoming blocked by default, SSH/KDE Connect/mDNS from the LAN only, Docker published ports only when in an access scope, 10-minute automatic revert while testing | A1 | You test new connections from dsoffice and Windows; host-config §12, [network-access.md](network-access.md) |
| A4 | **BIOS:** After Power Loss → Power On; check for a BIOS newer than 02.17.00; a power-cut test | — | You, at the server |
| A5 | A **second SSH key** for daniel (e.g. from the Windows PC), so losing dsoffice doesn't lock you out | — | You provide the public key |
| O1 (**done 2026-11-11**: hub on Beacon, agents on Beacon and dsserver, ntfy alerts, Healthchecks heartbeat — see [beacon/README.md](../beacon/README.md)) | **Beszel hub** (Compose, pinned, 127.0.0.1 only) plus a **native agent** (our own unit file, no docker or disk groups, no auto-update), then a 48 h benchmark and final limits. Hub heartbeat to a second Healthchecks check | A2 (A3 for LAN access to the dashboard) | Design: [monitoring-architecture.md](monitoring-architecture.md) |
| O2 (done with O1) | Docker metrics in Beszel through a filtering socket proxy (exact GET allowlist) | O1 | Decided 2026-11-10 |
| L1 | Optional journald drop-in with an explicit size cap (e.g. `SystemMaxUse=1G`) | — | Only if the default (10% of the disk, up to 4 GB) is not wanted |

## Pi migration (handover `dsserver-migration-v2`, milestones M0–M7)
The Raspberry Pi (dsoffice) hands its kept responsibilities to dsserver. Milestone numbers follow the handover's MIGRATION-PLAN; the monitoring items above were renamed O1/O2 (formerly M1/M2) to avoid a clash. The handover package is reference material only and is not in Git (it lists where secrets live). kjell-monitor (handover M2) is **not** migrated: the observability platform on the reinstalled Pi will replace it.

| # | Increment | Status |
|---|---|---|
| M1 | **Remote admin of kjells-computer** (Kjell's Mint laptop) from dsserver, independent of the Pi: Tailscale client (`11-tailscale.sh`, host-config §13), then a **new, passphrase-protected** Ed25519 key for interactive use only (handover option B: no private key is shared with the Pi). Its public key is appended to `~kjell/.ssh/authorized_keys` over the Pi's existing connection; the Pi's key stays until Pi retirement. Done when dsserver logs in with its own key | **Done 2026-11-10**: [kjells-computer-admin.md](kjells-computer-admin.md) |
| M2 | kjell-monitor | **Dropped** (replaced by the Pi's future observability platform) |
| M3 | StockPulse on dsserver, private: [stockpulse/README.md](../stockpulse/README.md) (allowlist `serve.py`, Compose web + job containers, HTTPS via Caddy, systemd timers, 15-min application check → Beszel/ntfy, daily backup) | Deployed 2026-11-11 (LAN only); **production screener timers disabled** pending: US ticker source (NASDAQ API 403), new Firebase key, app URL, timer approval |
| H1 | HTTPS foundation for rubusdua.net: public DNS-only A records to LAN addresses, Caddy + Let's Encrypt DNS-01 per host, LAN-only 443 ([https.md](https.md)) | Done 2026-11-11 (HTTPS live on beacon. and dsserver.rubusdua.net); LAN cutover done: dashboard HTTPS-only, :8090 limited to the dsserver agent |
| M4–M7 | public endpoint + app, notification cutover, StockPulse dev, Pi retirement | Not started; see the handover |
| X1 | External access: Cloudflare Tunnel → Access (OTP) → Caddy, routes allowlisted in `tunnel/routes.toml` ([external-access.md](external-access.md)) | Designed 2026-11-11, templates offline-validated; **not active**; decisions: auth model, hostnames; needs Zero Trust org + scoped token |
| N1 | Network monitoring on Beacon: 10 Beszel checks + netwatch outage history/classification (beacon/README.md) | Live 2026-11-11 |

| NAS | **dsnas** (DS223j): family data + media migrated and three-way SHA-256 verified, shares/accounts/snapshots, LAN-only ([nas/README.md](../nas/README.md)); Beszel agent + SNMPv3 health ([nas/monitoring.md](../nas/monitoring.md)) | Done 2026-11-14; Replay switch pending (handled on Replay) |
| D1 | **Local DNS:** dnsmasq resolvers on Beacon + dsserver, identical records, LAN-only ([dns/README.md](../dns/README.md)) | Done 2026-11-14: live on both, Deco DHCP hands them out, client/Docker/IPv6/StockPulse acceptance passed |
| H2 | **Trusted HTTPS for dsnas** (`https://dsnas.rubusdua.net`, served by DSM itself; Caddy DNS-01 + `dsnas-cert-push` timer; Beacon expiry check) ([internal-https.md](internal-https.md)) | Done 2026-11-14 |

## Backlog (agreed 2026-11-14; order = priority, foundations first)
Priorities: reliability, security, simplicity, efficiency, features. Milestone order (owner, 2026-11-14): 1 NAS+DNS
acceptance, 2 off-device server backups, 3 DATASERVER secondary, 4 off-site family data, 5 physical network
monitoring, 6 Replay/Kjell on demand, 7 container observability. Items stay here until done or explicitly dropped,
even when the current tools cannot collect them. StockPulse rollout commitments are unchanged.

| # | Item | Notes / dependencies |
|---|---|---|
| D2 | Public DNS records for beacon./dsserver. removed (LAN resolvers answer them; `dns/cf-private-records.sh`, rollback `restore`) | **Done 2026-11-14** (approved) |
| 1 | NAS + DNS acceptance: alert drills (SNMP storage, cert expiry) with phone confirmation, resolver DNS monitors | **Done 2026-11-14** |
| 2 / B1 | **Off-device server backups** of dsserver, Beacon, StockPulse, configuration and encrypted secrets to dsnas | Proposal [backup-proposal.md](backup-proposal.md), awaiting review |
| 2 / NM3 | Backup job success and freshness monitoring | Part of B1 |
| 3 / B2 | **DATASERVER as versioned secondary backup** of dsnas | Only after Replay's migration is completed and verified; separate approval |
| 4 / B3 | **Off-site backup** of irreplaceable family data | Provider/encryption decision |
| 5 / N2 | **Physical network monitoring:** five Deco units, TL-SG105E v5, inter-house Ethernet link, gateway, DNS, internet: latency, loss, availability history, link speeds, error counters where a supported interface exists | Deco has no SNMP/API (ping/HTTP only); TL-SG105E is web-managed without SNMP |
| 6 / N3 | **On-demand monitoring of Replay** without false alerts while it is intentionally off | After Replay's migration; coordinated with Claude on Replay |
| 6 / N4 | **Kjell's Linux Mint computer**, following the Replay pilot | Over Tailscale; privacy agreed with Kjell |
| 7 / O3 | **Container observability** in Beszel | Socket-proxy allowlist decisions |
| NM1 | dsnas SMART test results monitored automatically | Not in the Synology MIB / unprivileged agent; DSM notification -> webhook, or least-privilege API check |
| NM2 | Snapshot freshness per dsnas share | `dsnas-check.py` checks it manually; needs a least-privilege automated path |
| S1 | DATASERVER FTP: confirm from outside (mobile data) that 21 + 55536-55546 are closed; decide FTP/`peter` | Router forward removed by owner 2026-11-14 |
| - | Incoming VPN access to dsserver, rootless Docker for axel; log forwarding only if needed | unchanged from before |
