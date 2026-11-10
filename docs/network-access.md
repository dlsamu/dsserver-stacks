# Network access for applications

How a service on dsserver becomes reachable, and by whom. Firewall design: `host/docs/host-config.md` §12; ruleset: `host/files/etc/dsserver-firewall.nft`.

## Scopes (least exposed first)
| Scope | Who can connect | How | Status |
|---|---|---|---|
| **localhost** (default) | only processes on dsserver (and an SSH tunnel: `ssh -L 8080:127.0.0.1:8080 dsserver`) | Compose: `ports: ["127.0.0.1:8080:80"]`. **No firewall entry.** | available |
| **lan** | devices on 192.168.68.0/24 | Compose: `ports: ["8080:80"]` **and** port 8080 in `lan_tcp`/`lan_udp` | available |
| **vpn** | devices on the future VPN | interface in `vpn_ifaces` + port in `vpn_tcp`/`vpn_udp` | not yet: no VPN |
| **internet** | anyone | port in `internet_tcp`/`internet_udp` + a router port forward + a reverse-proxy/TLS decision | not allowed without a separate approval |

Rules:
- **Start with localhost.** Move a service up only for a concrete need, and write that need down.
- A published Docker port that is in **no** scope is blocked, even from the LAN. A mistake in a Compose file, such as `8080:80` instead of `127.0.0.1:8080:80`, therefore doesn't expose anything.
- The firewall matches the **host** port, which is the left side of `8080:80`.
- Containers can't reach services on the host (for example, a container reaching `172.17.0.1:22` is blocked). If an application needs that, treat it as a decision of its own.
- Avoid `network_mode: host`. If it is unavoidable, the service's ports go through the same scope sets.
- IPv6: published ports are IPv4 only. Docker IPv6 is not enabled.

## Process: giving an application access
1. **Decide the scope.** Record it in the register below: application, port/protocol, scope, reason, date.
2. **Compose:** publish the port to match the scope (`127.0.0.1:` for localhost).
3. **Firewall (lan/vpn/internet only):** add the port to the matching set in `host/files/etc/dsserver-firewall.nft`, with a comment naming the application and date. Run `bash host/tests/test-firewall.sh`, then commit.
4. **Bootstrap:** you run `sudo bash host/scripts/09-delegated-sudo.sh install <commit>`. This is the approval step: the firewall can only load reviewed, committed rules.
5. **Apply with a safety net:** `10-firewall.sh try` loads the rules with a 10-minute automatic revert. Test from a LAN device, then run `10-firewall.sh confirm`.
6. **Verify:** `10-firewall.sh verify`. From another device, check that access works and that a port **not** in a scope stays closed.

Removing access is the same process, deleting the element instead.

## Register
| Application | Port | Scope | Reason | Since |
|---|---|---|---|---|
| SSH (host) | 22/tcp | lan | administration from dsoffice and Windows | 2026-11-10 |
| KDE Connect (host) | 1714–1764/tcp+udp | lan | existing behaviour kept | 2026-11-10 |
| mDNS (host) | 5353/udp | lan | `dsserver.local` name resolution | 2026-11-10 |

## Checking
- What listens: `ss -tulpn`. Anything on `0.0.0.0` / `*` without a register entry is reachable only from localhost and docker-internal traffic, because the firewall drops it.
- What the firewall allows: `sudo nft list set inet dsserver_fw lan_tcp` (and `lan_udp`, `vpn_*`, `internet_*`).
- What it dropped recently: `journalctl -k -g dsserver-fw --since -1h`.
