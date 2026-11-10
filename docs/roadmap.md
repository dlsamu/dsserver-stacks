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
| **A2** (prepared 2026-11-10, not executed) | **External heartbeat and host health state:** a native `dsserver-health` timer (every 5 min) sends one HTTPS ping to Healthchecks.io, marked ok or fail with short codes only (failed host units, disk health, root disk above 90%, updates stale; Docker state and reboot need as information). Healthchecks emails the Gmail inbox | a Healthchecks.io account (yours) | You create the account and check; you install the ping URL in Konsole (hidden input) |
| A0 (installed 2026-11-10) | **Delegated sudo:** exact, root-owned script commands without a password, so Claude can run approved steps | — | You run `09-delegated-sudo.sh install` once in Konsole (host-config §11) |
| A3 | **Firewall:** our own systemd unit, iptables-nft for IPv4 and IPv6. Incoming traffic blocked by default, SSH from the LAN only, published Docker ports limited to the LAN through `DOCKER-USER`, a 5-min auto-revert while testing | A1 | You run it in Konsole and test from dsoffice and Windows; separate detailed plan |
| A4 | **BIOS:** After Power Loss → Power On; check for a BIOS newer than 02.17.00; a power-cut test | — | You, at the server |
| A5 | A **second SSH key** for daniel (e.g. from the Windows PC), so losing dsoffice doesn't lock you out | — | You provide the public key |
| M1 (deferred) | **Beszel hub** (Compose, pinned, 127.0.0.1 only) plus a **native agent** (our own unit file, no docker or disk groups, no auto-update), then a 48 h benchmark and final limits. Hub heartbeat to a second Healthchecks check | A2 (A3 for LAN access to the dashboard) | Design: [monitoring-architecture.md](monitoring-architecture.md) |
| M2 | Docker metrics in Beszel through a filtering socket proxy (optional) | M1 | Your decision |
| L1 | Optional journald drop-in with an explicit size cap (e.g. `SystemMaxUse=1G`) | — | Only if the default (10% of the disk, up to 4 GB) is not wanted |

## Deferred (waits on the replacement NAS)
- B: restic backups of dsserver to the new NAS, plus restore drills and a backup check in the heartbeat. Until then, **no service holding valuable data is deployed**, and dev work is pushed to GitHub.
- NAS migration from DATASERVER (DATASERVER and Replay are frozen until the photo backup has been verified).

## Later
- A VPN (Tailscale or WireGuard) for remote access and monitoring across networks; rootless Docker for axel.
- More hosts in Beszel: Raspberry Pis, the replacement NAS (reachability), the network and the internet, the Linux Mint PC (over the VPN).
- An off-site copy of backups.
- Logs: forwarding with `systemd-journal-remote` only if a need appears (see monitoring-architecture §5).
