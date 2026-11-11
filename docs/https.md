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

## Status (2026-11-11)
| Item | State |
|---|---|
| DNS: `beacon` → .121 and `dsserver` → .115, both DNS only (dsserver's Deco reservation confirmed by you) | **live**. Resolves through Cloudflare's authoritative servers, ISP resolvers 2.248.248.2/.248, the Deco gateway 192.168.68.1, 1.1.1.1, 8.8.8.8 and the system resolver on both hosts. No leftover `_acme-challenge` records |
| Tokens `caddy-beacon` / `caddy-dsserver` | **installed**: `/etc/beacon-secrets/cloudflare.env` and `/etc/dsserver-secrets/cloudflare.env` (root 0600). Status active; each sees only rubusdua.net. Staged copies shredded. Nothing in Caddy's logs |
| https://beacon.rubusdua.net | **live, tested**: Let's Encrypt (YE1), TLS 1.3, expires 2027-02-09. From dsserver by name: dashboard, /api/health, live updates (SSE), agent WebSocket endpoint. On Beacon: automation login + authenticated read |
| Beszel agent over WebSocket through HTTPS | **tested**: a temporary agent on dsserver connected to `https://beacon.rubusdua.net` ("WebSocket connected") and delivered live metrics. The test system, token file and data were removed afterwards. Real agents still use :8090 (see Cutover) |
| Beacon firewall 443/tcp from the LAN | **live**: try → test → confirm. 80 and 2019 closed |
| https://dsserver.rubusdua.net | **live, tested**: Let's Encrypt (YE1), TLS 1.3, expires 2027-02-09. Answers with the placeholder 404 as designed. Checked from Beacon (a LAN client) by name with certificate verification |
| dsserver firewall 443/tcp in `lan_tcp` | **live**: blocked from the LAN before, open after `10 try`. 22 still reachable; unlisted 9999 and port 80 closed. Then `confirm`; `10 VERIFY PASSED` |
| Restart recovery | **tested**: Beacon: SIGKILL of Caddy → Docker restarted it within 1 s and kept the stored certificate (no new request). dsserver: container recreated by `14 up` → certificate reused. Both `restart: unless-stopped`; docker, firewall and agent units enabled at boot. **Not tested:** an actual reboot (not allowed), and a SIGKILL on dsserver (14 has no such mode; same image and policy as Beacon) |
| Renewal | **path tested**: a throw-away Caddy on Beacon obtained a fresh certificate from Let's Encrypt **staging** with the same token and plugin, then was removed. Real renewal is automatic, about 30 days before expiry (first around 2027-01-10). **Not observed yet** |
| Monitoring after the change | **checked**: both systems up, 13 alerts / 0 firing, `13 VERIFY PASSED`, dsserver heartbeat ran successfully at 16:02, Beacon hub sends its Healthchecks ping (HTTPS connection 16:05:30), `bz test-notify` sent, 0 failed units on both hosts, http://192.168.68.121:8090 still answers |
| Retire LAN plain HTTP (Beacon :8090), set `APP_URL` | **done 2026-11-11** (see Cutover) |

## Cutover (done 2026-11-11, approved by you)
- **Consumers of :8090 found** by sampling Beacon's connections for 2 minutes:
  - over loopback: Beacon's own agent (`HUB_URL=http://127.0.0.1:8090`) and Caddy. The firewall doesn't filter loopback.
  - from 192.168.68.115: dsserver's agent (WebSocket), plus Firefox on dsserver showing the dashboard over HTTP.
  - nothing else.
- **Hub:** `APP_URL=https://beacon.rubusdua.net` (supported environment setting, `compose/beszel/compose.yaml`), so alert links use the
  HTTPS name. The hub was recreated once. Its data is unchanged: alerts (13), notification settings, users,
  systems, superusers and alert history are identical by digest before and after. The network checks' settings are unchanged; only the
  timestamp of their status reset moved.
- **Beacon firewall:** 22 and 443 from 192.168.68.0/24, and **8090 only from 192.168.68.115**. Applied with
  try → test → confirm. The installed file equals the repo.
- **Agents:** they stay on plain `ws://` to :8090. Agent and hub authenticate each other with the token and the hub's key, so
  no credential crosses the network in plain text. **New agents** (`bz add-system`) get `HUB_URL=https://beacon.rubusdua.net`.
- **Known limitation:** the source-address rule can't tell processes apart, so **a browser on dsserver itself can still
  open http://192.168.68.121:8090**. Use the HTTPS bookmark there. Closing 8090 completely would require moving the dsserver agent to
  `https://beacon.rubusdua.net` (WebSocket over HTTPS is tested), plus a dsserver `/etc/hosts` entry so it doesn't depend on public DNS.
  That is optional and not done.

### Cutover verification (2026-11-11 16:10–16:21)
| Check | Result |
|---|---|
| Before: certificate, dashboard, health, SSE, WebSocket endpoint, login, authenticated read, live metrics pushed over HTTPS (new `--live` check) | passed |
| New dsserver agent connection through the new rule (`13 test-recovery`: SIGKILL → restart → reconnect) | passed |
| Ordinary LAN client (temporary network namespace on Beacon as 192.168.68.250; removed afterwards) | :8090 **blocked** (logged as `beacon-fw drop … DPT=8090`), https://beacon.rubusdua.net **200**, SSH open |
| Survives restarts: `docker restart caddy`, `docker restart beszel-hub`, `systemctl restart beacon-firewall` (boot load path) | HTTPS check passed after each; both systems back `up` |
| After: 13 alerts / 0 firing, configuration identical, `13 VERIFY PASSED`, live metrics over HTTPS, `bz test-notify` sent, dsserver heartbeat success 16:17:43, Beacon hub heartbeat 16:20:04, 0 failed units on both hosts | passed |
| Not tested | reboots; a real alert carrying the new link (needs an alert to fire) |

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
