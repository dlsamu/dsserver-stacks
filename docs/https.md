# HTTPS for home infrastructure (rubusdua.net)

Design, Cloudflare setup and operations for trusted HTTPS on Beacon, dsserver and later applications.
Day-to-day commands are in `beacon/README.md` ("HTTPS") and `proxy/README.md`.

## Architecture (decided 2026-11-11)

```
browser on the LAN ──DNS──> Cloudflare (public, DNS only)   beacon.rubusdua.net -> 192.168.68.121
        │                                                    dsserver.rubusdua.net -> 192.168.68.115
        └──HTTPS :443 (LAN only)──> Caddy on that host ──plain HTTP, loopback / Docker network──> app

Caddy ──DNS-01 (TXT record via Cloudflare API, outbound only)──> Let's Encrypt certificate, auto-renewed
```

- **Names:** ordinary public A records in the Cloudflare zone, **DNS only (grey cloud)**, pointing to
  the hosts' private LAN addresses. No local DNS server, no Deco/DHCP change, no client configuration.
  This was tested on 2026-11-11: the household's resolvers (2.248.248.2 and .248, handed out by Deco DHCP),
  1.1.1.1 and 8.8.8.8 all return private addresses, so they don't filter them as DNS rebinding.
  Android "Private DNS" and browser DNS-over-HTTPS keep working too, because they also resolve public names.
- **Certificates:** Caddy, one per host, with the `caddy-dns/cloudflare` module. Caddy gets certificates
  by DNS-01, so nothing has to be reachable from the internet. It renews them about 30 days before
  they expire and retries on its own after failures.
- **Independence:** Beacon and dsserver each run their own Caddy with their own certificate and
  Cloudflare token. Beacon's dashboard therefore doesn't depend on dsserver, which Beacon monitors.
- **Exposure:** Caddy listens on 443/tcp only. Each host's firewall allows that port from
  192.168.68.0/24 only. There is no port 80, no HTTP/3 (UDP), no router port forward and no Cloudflare proxy.
- **Backends:** On Beacon, Caddy reaches the hub at 127.0.0.1:8090 (both use host networking). On
  dsserver, Caddy runs on a Docker network called `proxy`. Applications join that network, publish no
  ports, and Caddy reaches them by container name.
- **Future public applications (for example training.rubusdua.net):** use Cloudflare Tunnel
  (`cloudflared` makes an outbound connection only) to that application's container alone. It is a
  separate decision and needs approval. Private names stay DNS only and never go through the tunnel.

### Trade-offs considered

| Option | Why not chosen / note |
|---|---|
| Local DNS server (Pi-hole/dnsmasq on Beacon) handed out by Deco DHCP | It becomes a single point of failure for the whole household's internet. It needs a Deco DHCP change. It is bypassed by Private DNS/DoH clients. |
| Split DNS via Tailscale | Only works on tailnet devices. Not needed while all access is from the LAN. |
| Per-device hosts files | Impossible on phones and doesn't scale. |
| Wildcard certificate `*.rubusdua.net` | It would keep host names out of Certificate Transparency logs. The cost: one key valid for every name, sitting on both hosts. Rejected for simplicity. **CT logs publicly list each certificate's name** (beacon, dsserver, and later stockpulse and training). The names are not secrets. |
| Debian `caddy` package | It can't use DNS-01 with Cloudflare because it has no modules, and it is version 2.6.2. `caddy add-package` would be undone by apt upgrades. |
| certbot + `python3-certbot-dns-cloudflare` (Debian) | It is well supported and updated by unattended-upgrades. It still needs a web server plus reload hooks, so there are two moving parts per host instead of one. This is the fallback if the custom Caddy build ever becomes a problem. |
| **Caddy built from the official `caddy:*-builder` image (xcaddy) + Cloudflare module** | **Chosen.** Caddy's documented build method. Pinned by tag and digest. One component does both TLS and proxying, and handles WebSocket/SSE without extra configuration. Cost: **Caddy updates are manual** (rebuild); see "Updating". |

Known limitations:
- **Name resolution needs the internet.** If the internet is down, the names don't resolve, and most
  household devices can't resolve anything anyway. Break-glass access to Beacon: `ssh -L
  8090:127.0.0.1:8090 beacon`, then http://localhost:8090. This works even after the LAN :8090
  cutover.
- **The records publish two private addresses** (192.168.68.115/.121). They aren't reachable from the
  internet. The only things revealed are that these hosts exist and the LAN address plan. dsserver's
  address must stay fixed: it needs a DHCP reservation in Deco, like Beacon's.
- **Off the LAN** (for example, over Tailscale only), the names point to LAN addresses that can't be
  reached. Remote access would be a separate decision (Tailscale subnet route or tunnel).
- **Token scope:** a token with Zone DNS:Edit can change any record in the rubusdua.net zone.
  Cloudflare can't limit a token to individual records. Mitigations: one token per host, so each can be
  revoked alone; the tokens are root-only on the hosts; IP filtering is optional (see below).

## Cloudflare setup (you, in the dashboard)

### API tokens: one per host
Go to Cloudflare dashboard → profile icon → **My Profile → API Tokens → Create Token → "Create Custom
Token"**. Your Google SSO and two-step verification apply as usual.

| Field | Value |
|---|---|
| Token name | `caddy-beacon` (second token: `caddy-dsserver`) |
| Permissions | **Zone · Zone · Read** and **Zone · DNS · Edit** |
| Zone Resources | **Include · Specific zone · rubusdua.net** |
| Client IP Address Filtering | optional: your current public IPv4. Leave it empty if your ISP address changes, because renewals would otherwise fail without notice until expiry. |
| TTL | no end date (renewal is unattended) |

The token is shown **once**. Don't paste it into chat. Store it like this:
1. In Konsole on dsserver, run `install -m 600 /dev/null ~/.cloudflare-token-beacon && nano ~/.cloudflare-token-beacon`.
   Paste the token, then save with Ctrl+O, Enter, Ctrl+X. For the dsserver token, use the same steps with `~/.cloudflare-token-dsserver`.
2. Optionally store a copy in Bitwarden. It isn't required: a lost token is simply revoked and recreated.
3. Claude then runs `https.sh token-install` / `14-https-proxy.sh token-install`. The script moves
   the token into a root-only file on its host, checks it at Cloudflare (`active`, sees exactly
   `rubusdua.net`) and shreds the staged file. The token never appears in Git, chat, command lines or logs.

Revoke: Cloudflare → My Profile → API Tokens → **⋯ → Delete**. Then create a new token and run
`token-install` again.

### DNS records (approval needed: they publish private addresses)
| Type | Name | Content | Proxy status | TTL |
|---|---|---|---|---|
| A | `beacon` | 192.168.68.121 | **DNS only** (grey cloud) | Auto |
| A | `dsserver` | 192.168.68.115 | **DNS only** (grey cloud) | Auto |

No record for the zone apex, no wildcard and no MX. Caddy adds and removes its own temporary
`_acme-challenge` TXT records.

## Status
| Item | State |
|---|---|
| Beacon: Caddy image built (2.11.9 + cloudflare v0.2.4) | **done** 2026-11-11 |
| Beacon: proxy tested on loopback with an internal test CA (dashboard, /api/health, live updates (SSE), agent WebSocket endpoint, login + authenticated read) | **tested** 2026-11-11 |
| Beacon: firewall 443/tcp from the LAN | prepared (`beacon/firewall/beacon-firewall.nft`), **not loaded** |
| Beacon: real certificate, DNS name, verify from dsserver, real agent over WebSocket | waiting for the token + DNS records |
| dsserver: `proxy/` + `host/scripts/14-https-proxy.sh` (delegated) | prepared and validated (`caddy validate`). Needs `09 install`, the token, firewall approval for 443 and a DHCP reservation |
| Retire LAN plain HTTP (Beacon :8090) | **not started; needs your approval** (see "Cutover") |

## Cutover (later, with approval)
- **Browsers** move to https://beacon.rubusdua.net. Set the hub's `APP_URL` to that address so links in
  alerts point there. This restarts the hub for a few seconds.
- **Agents** keep plain `ws://` to :8090 for now. Agent and hub authenticate each other with the
  token and the hub's SSH key signature, so this is not a credential exposure. Moving the dsserver
  agent to `https://beacon.rubusdua.net` would make it depend on public DNS. If done, also add a
  dsserver `/etc/hosts` entry for beacon.rubusdua.net.
- **Retiring :8090 from the LAN** means allowing it only from dsserver's address
  (agent) and loopback, instead of all of 192.168.68.0/24. Applied with `firewall/apply.sh try` (automatic
  revert after 5 minutes) and then `confirm`.

## Operations
- **Renewal:** automatic. Check: `bash beacon/scripts/https.sh status` (expiry date) and
  `verify` (fails below 14 days left). If renewal keeps failing, Caddy logs `error` lines. Cause is
  usually the token (`token-check`).
- **Recovery:** containers use `restart: unless-stopped`. Certificates and the ACME account live in
  `/srv/appdata/caddy` (Beacon) and `/srv/appdata/proxy` (dsserver). If those are lost, Caddy gets new
  ones within minutes. Let's Encrypt allows 5 duplicate certificates per week.
- **Updating Caddy:** change the versions and digests in `beacon/compose/caddy/Dockerfile`, then commit.
  Run `https.sh build` + `up` on Beacon, and `09 install` → `14 build` + `up` on dsserver.
  Watch https://github.com/caddyserver/caddy/releases for security releases.
- **Rollback:** `https.sh down` / `14-https-proxy.sh down` removes only the Caddy container. The hub and
  applications are untouched, and the existing :8090 path keeps working until the cutover.
