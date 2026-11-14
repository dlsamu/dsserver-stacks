# Local DNS for the home LAN (dsserver + Beacon)

Two identical, independent resolvers give every LAN device the same answers for the home hosts and forward
everything else to public DNS. The Deco stays the router and the only DHCP server; it only hands out these two
resolvers (manual step below).

| Resolver | Address | Runs as |
|---|---|---|
| Beacon | 192.168.68.121 | `local-dns.service` (dnsmasq 2.91 from Debian `dnsmasq-base`) |
| dsserver | 192.168.68.115 | `local-dns.service` (same) |

## Records (`records.conf`, the only place to edit)

| Name | Address |
|---|---|
| dsserver.rubusdua.net | 192.168.68.115 |
| beacon.rubusdua.net | 192.168.68.121 |
| dsnas.rubusdua.net | 192.168.68.112 |
| replay.rubusdua.net | 192.168.68.125 |
| dataserver.rubusdua.net | 192.168.68.119 |

Each record also answers the reverse lookup (PTR). AAAA queries for these names get "no data" (the LAN has no IPv6).

## Design decisions

- **dnsmasq, DNS only.** Already installed on both hosts as a NetworkManager dependency (`dnsmasq-base`), ~2 MB RAM,
  no new package. It runs from our own unit and config (`/etc/local-dns/`), not the `dnsmasq` package's
  `/etc/dnsmasq.conf`. No `dhcp-range` exists, so it never does DHCP; `verify` checks that nothing listens on port 67.
- **Only exact names are local.** `host-record` lines, no `local=/rubusdua.net/`. Every other `rubusdua.net` name is
  forwarded unchanged:
  - `stockpulse.rubusdua.net` still resolves to Cloudflare, so the tunnel and Access login stay in the path (no local override);
  - `_acme-challenge.*` TXT and SOA queries go to Cloudflare's DNS, so Caddy's DNS-01 renewals are unaffected;
  - unknown names get the real NXDOMAIN.
- **No dependency on the internet or Cloudflare for local names** (answered from `records.conf`, TTL 60 s).
- **No circular dependency.** Upstream servers are fixed IPs (`no-resolv`): ISP 2.248.248.2 and 2.248.248.248 (what
  the LAN used before), then 1.1.1.1 and 9.9.9.9 as fallbacks for internet names. The hosts' own `/etc/resolv.conf`
  (from DHCP) is never read by dnsmasq, so pointing the hosts at themselves is safe.
- **Listens only on loopback and the host's LAN address** (`bind-dynamic`); firewalls allow 53/udp+tcp from
  192.168.68.0/24 only (and, on dsserver, from the Docker bridges, because containers use the host's resolvers).
  No router port forward exists, so nothing is reachable from the internet.
- `domain-needed` and `bogus-priv`: single-label names and private reverse lookups never leave the LAN.
- **Hardened unit:** starts as root only to bind port 53, then runs as user `dnsmasq`; capability bounding set
  limited to bind/setuid/setgid; read-only filesystem; `Restart=always`; MemoryMax 64M.
- **IPv6:** the Deco advertises no IPv6 prefix (hosts have link-local addresses only), so clients have no IPv6 DNS
  servers that could bypass these resolvers. If IPv6 is ever enabled on the Deco, re-check what DNS it advertises.
- Not done on purpose: DNSSEC validation (extra moving part; the upstreams validate), query logging (privacy),
  rebind protection (could break unknown devices that rely on public names resolving to private addresses).

## Files

| File | Purpose |
|---|---|
| `dnsmasq.conf` | common configuration (installed as `/etc/local-dns/dnsmasq.conf`) |
| `records.conf` | the local records |
| `local-dns.service` | systemd unit |
| `local-dns.sh` | `preflight` / `install` / `verify` / `status` / `test-restart` / `rollback`, run as root on the host |
| `dnsq.py` | tiny stdlib DNS client used by `verify` (Beacon has no `dig`) |
| `deploy-beacon.sh` | copies this directory to Beacon `/srv/local-dns` and runs `local-dns.sh <step>` there |
| `test-dns.sh` | end-to-end test from a LAN client against both resolvers (one or both) |

## Operations

```bash
# Beacon (from dsserver, as daniel)
bash /srv/stacks/dns/deploy-beacon.sh install|verify|status|test-restart
# dsserver (delegated sudo; the snapshot is refreshed by 09-delegated-sudo.sh install <commit>)
sudo -n /usr/local/lib/dsserver-admin/dns/local-dns.sh install|verify|status|test-restart
# both, from any LAN host with dig
bash /srv/stacks/dns/test-dns.sh            # both resolvers
bash /srv/stacks/dns/test-dns.sh 192.168.68.121
```

**Changing a record:** edit `records.conf`, commit, then `deploy-beacon.sh install`, `09 install <commit>` +
`local-dns.sh install` on dsserver, `test-dns.sh`. Keep the address in line with the Deco reservation.

**Rollback of one resolver:** Beacon `bash deploy-beacon.sh rollback`; dsserver (manual, as root)
`sudo /usr/local/lib/dsserver-admin/dns/local-dns.sh rollback`. Remove the Deco DNS entry first if the Deco hands it out.

## Deco change (manual, in the Deco app; done by the owner)

Prerequisite: both resolvers pass `test-dns.sh` (state below).

1. Deco app > **More > Advanced > DHCP Server** (wording varies by app version: "Address Reservation" lives next to it).
2. **Primary DNS: 192.168.68.121** (Beacon), **Secondary DNS: 192.168.68.115** (dsserver). Save.
   Do **not** change the Deco's own *Internet Connection > DNS* (WAN) setting: the router keeps using the ISP's DNS
   for itself, so the router never depends on these resolvers.
3. Clients pick the new servers up when they renew their lease. To apply at once: reconnect Wi-Fi on phones/laptops;
   on dsserver/Beacon `sudo nmcli device reapply <if>` (or wait for renewal).
4. Tell Claude; it then checks dsserver, Beacon and a client (`resolvectl`/`nmcli`, browser DNS-over-HTTPS, IPv6).

**Rollback (Deco):** set *DHCP Server > DNS* back to the previous setting (**Auto / obtain from ISP**; before the change
the Deco handed out 2.248.248.2 and 2.248.248.248) and reconnect clients. The resolvers can stay running; nothing
depends on them once the Deco no longer hands them out.

## Browser DNS-over-HTTPS

Browsers with "secure DNS" set to a fixed provider (e.g. Cloudflare in Chrome/Firefox) bypass the LAN resolvers.
For `dsnas.rubusdua.net`, `replay.rubusdua.net` and `dataserver.rubusdua.net` this means "not found" in that
browser, because those names exist only locally (dsserver and beacon also have public records, so they keep
working). Chrome's default "use your current service provider" and Firefox's default in Sweden keep using the
system resolver. Fix per browser if needed: Settings > Privacy > Secure DNS > *current service provider* / off.

## Acceptance (2026-11-14)

| Check | Result |
|---|---|
| Beacon resolver: install, `verify`, firewall rule (LAN only) | pass; `test-restart` (restart + kill -9 -> back in 3 s); ~2 MB RAM |
| dsserver resolver: install, `verify`, firewall (LAN + Docker bridges), sandbox firewall test 32/32 | pass; `test-restart` back in 3 s |
| `test-dns.sh` against both from a LAN client (dsserver -> Beacon, Beacon -> dsserver with `dnsq.py`) | 70/70 |
| Independence | dsserver alone 35/35 with Beacon's resolver stopped; Beacon answered 30/30 during dsserver restart + kill |
| Deco DHCP: Primary 192.168.68.121, Secondary 192.168.68.115 (set by the owner) | phone: Google, Beacon, `dsnas.rubusdua.net` (local-only name) work; StockPulse shows Cloudflare Access |
| Hosts after lease renewal (14:46) | dsserver and Beacon `resolv.conf` = .121, .115; `getent hosts dsnas.rubusdua.net` ok on both |
| Docker | fresh container (busybox, default bridge) resolves and reaches the internet with the new servers; container -> host:53 covered by the sandbox test; running containers keep their old resolv.conf until recreated (harmless) |
| StockPulse security | through both resolvers: Cloudflare addresses, `/` -> 302 to `rubusdua.cloudflareaccess.com`, only `/healthz` 200 |
| IPv6 | the Deco sends RAs with a default route but **no prefix and no RDNSS/DHCPv6 DNS** (NetworkManager shows no IPv6 DNS on either host): no IPv6 path around the resolvers |
| Browser DoH | depends on the browser setting (see above); the phone test resolved the local-only name, so it uses the LAN resolvers |

Not tested (by design): host reboots (no reboot approved; units are enabled and `verify` checks it).
