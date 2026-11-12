# External application access (design 2026-11-11; StockPulse activation 2026-11-12)

## Status and decisions (2026-11-12, approved by Daniel)
- **StockPulse** goes public through the tunnel, protected by **Cloudflare Access, e-mail one-time PIN**, allow-list in
  `/etc/dsserver-secrets/stockpulse-access-emails` (root 0600, never in Git), session 30 days; `/healthz` bypassed.
- **One name** (option 1 below): `stockpulse.rubusdua.net` becomes a proxied CNAME to the tunnel; `beacon.`/`dsserver.`
  stay LAN-only A records. Caddy, its certificates, the firewall and the router are not changed.
- **Credentials:** a *temporary* setup token (Account: Cloudflare Tunnel Edit, Access: Apps and Policies Edit,
  Access: Organizations, Identity Providers, and Groups Edit; Zone rubusdua.net: DNS Edit), installed root-only,
  **revoked after setup**. What stays on dsserver: the tunnel credentials file (runs this one tunnel only).
- **App v0.4** (stockpulse repo): Access login pages stay inside the WebView with JS on only there; opt-in
  "Test notifications" (topic `stockpulse-test`) so notification tests never reach the family topic.
- Runbook: `host/scripts/16-tunnel.sh` (all modes delegated via 09). Order below.

### Activation order (16-tunnel.sh)
`preflight` → `token-install` → `emails-install` → `check` → `access-setup` → `tunnel-create` → `config` → `up`
→ `dns-switch` (refuses without the Access app: **Access first, DNS second**) → `verify` → phone test on mobile data
→ rollback drill (`dns-rollback`, LAN check, `dns-switch`, `verify`) → `token-remove` + revoke the token in the dashboard.

### Rollback (verified in the drill)
1. `16-tunnel.sh dns-rollback`: back to A 192.168.68.115, DNS only = exactly the LAN-only state before (apps on the
   home Wi-Fi keep working; mobile data shows the app's offline page). Needs the setup token, or do it in the dashboard:
   DNS → `stockpulse` → A, 192.168.68.115, proxy off.
2. `16-tunnel.sh down`: connector stopped (with DNS still on the tunnel, the name returns a Cloudflare error page).
3. Optional `16-tunnel.sh teardown`: deletes the Access apps/policies and the tunnel at Cloudflare and the local credentials.

### Monitoring notes (from the 2026-11-12 drill)
- Beacon's Beszel check `https://stockpulse.rubusdua.net/healthz` (1 min) is the external end-to-end check; a tunnel
  outage returns Cloudflare 530, which Beszel counts as a failure -> `NetworkMonitorLoss` (Beacon) -> ntfy.
  Drill: connector stopped 16:58, agent restarted 17:11:45, alert 17:15:23.
- **Beszel's agent keeps its HTTPS connection open between checks and does not re-resolve DNS.** After the switch it
  kept checking the old LAN path (Caddy, certificate issuer/expiry gave it away) and stayed green while the tunnel was
  down. **After every `dns-switch`/`dns-rollback`: `ssh beacon sudo systemctl restart beszel-agent`** (the dsserver external check is not affected: it resolves fresh every minute).
- Tunnel container: `ContainerHealth` (dsserver, 5 min) via Beszel; Cloudflare reports connections in `16 status`.

### External check on dsserver (2026-11-12, primary alert for the public path)
- `stockpulse-external.timer` (every minute) -> `15 external-check` -> `stockpulse/external_check.py`: resolves the name
  fresh via 1.1.1.1/9.9.9.9 (never the Deco, never a kept-alive connection), then requires `/healthz` 200 `ok` from
  `server: cloudflare` AND `/latest/us` without login -> redirect to `*.cloudflareaccess.com` (alerts if Access
  protection disappears, too). A LAN answer in public DNS counts as failed.
- Hysteresis: 3 failed probes in a row -> `stockpulse-external-alarm.service` started once, fails and stays failed ->
  SystemdFailed (dsserver) -> ntfy. 2 good probes in a row -> `reset-failed` -> recovery. One alert + one recovery per
  incident; blips (1-2 failed minutes) and flapping during an outage do not alert or re-alert.
- Planned rollback (`16 dns-rollback`): run `15 external-disable` first (otherwise the LAN answer alerts, correctly).
- Live alert-chain test without touching StockPulse: `15 external-test-fail` ... `15 external-test-clear`.
- Beacon's own Beszel check and thresholds are unchanged (independent second view, slower: 1 h loss > 20 %).

### What is public, and how it is protected
- Without a login: only Cloudflare's Access login page (served by Cloudflare) and `/healthz` (returns `ok`).
  Everything else (reports, archive, any other path) is answered by Cloudflare with a redirect to the login; the
  request never reaches dsserver.
- With a login (allow-listed e-mail + one-time code): the read-only report server, same as on the LAN
  (allow-listed paths only, strict CSP, no scripts).
- The tunnel can reach only Caddy; unknown hostnames get 404 from the connector.


Goal: StockPulse, Axel's training app and future personal apps reachable from the internet, without opening router
ports and without exposing administration. Status: **design + offline-validated templates only.** No tunnel, no
Cloudflare API call, no DNS change, nothing deployed. Decisions marked **DECIDE** are yours.

## Architecture (recommended)
```
phone / browser ──HTTPS──> Cloudflare edge ──(Access policy per hostname)──> Cloudflare Tunnel (outbound from dsserver)
                                                                        └─> tunnel-cloudflared (container, network "proxy")
                                                                               └─> https://proxy-caddy:443 (SNI = hostname)
                                                                                      └─> app container (e.g. stockpulse-web:8080)
```
- **Outbound only.** `cloudflared` dials out to Cloudflare; no port forward, no firewall change, no public IP needed.
- **One path for every app: through Caddy.** Same TLS/headers/logging as on the LAN; the tunnel can reach only Caddy
  (network `proxy`), never the host, SSH, Docker API, Beacon or other containers.
- **Explicit allowlist.** Public hostnames exist only in `tunnel/routes.toml`; `tunnel/render.py` validates them
  (zone, no infrastructure names, must have a Caddy site, access mode set) and renders the cloudflared ingress with a
  final `http_status:404`. Unknown hostnames hitting the tunnel get 404.
- **Locally managed config, version-controlled.** Ingress lives in Git (rendered), not only in the Cloudflare
  dashboard. Credentials: the tunnel's own credentials file (scoped to this one tunnel), not the account-wide `cert.pem`.

Files: `tunnel/compose.yaml` (template, digest-pinned 2026.10.7, read-only, no capabilities, uid 65532, healthcheck),
`tunnel/routes.toml` (registry; StockPulse present, `enabled = false`), `tunnel/render.py` + `test_render.py` (8 tests).

## Stays private (never a route; enforced by render.py's name rule and by design)
Beacon and its dashboard, `dsserver.rubusdua.net`, SSH, Docker API/socket proxies, Beszel, Caddy admin socket,
DATASERVER/NAS, the Deco, Replay, Kjell's laptop. LAN names keep their private A records and keep working unchanged.

## Authentication per application
| App | Recommendation | Alternatives |
|---|---|---|
| StockPulse (read-only reports, 2 users) | **Cloudflare Access, e-mail one-time PIN**, allow-list of 2 addresses, session 30 days; `/healthz` bypass for monitoring | (b) Access **service token** sent by the app as headers (no login; but the secret sits in the APK and must be rotated if a phone is lost); (c) Tailscale on the family phones (no public hostname at all; one more app to keep running); (d) public without auth (reports are not very sensitive, but ticker interests + it invites scanning) |
| Axel's training app | **DECIDE when its design exists.** Default: Access OTP in front + the app's own user accounts (Access alone gives "who may reach it", not per-user data separation) | Access only (if single user); Tailscale |
| Future personal apps | Access OTP by default; `public` only with a written `public_reason` in routes.toml | |

### Android WebView specifics (StockPulse app)
- **Google sign-in does not work inside a WebView** (Google blocks embedded browsers) → use e-mail OTP, not Google as
  the Access identity provider. OTP pages work in a WebView: the user gets a code by e-mail and types it.
- **JavaScript:** the app currently runs the WebView with **JS disabled** (reports need none). Cloudflare's Access login
  page needs JS. Required app change at activation: enable JS only while the page's host is the Access team domain
  (`<team>.cloudflareaccess.com`), keep it off for report pages (toggle in `onPageStarted`). Verify on a device.
- **Cookies:** Access sets `CF_Authorization` for the hostname; the WebView's `CookieManager` keeps it across app
  restarts (persisted by default). Session length = Access application session (recommend 30 days).
- **Notification-driven navigation:** a push opens `MainActivity` with a route → WebView loads
  `https://stockpulse.rubusdua.net<route>`. With a valid session: direct. With an expired one: Access login, then
  Access redirects back to the original URL (the route is preserved). No push-payload change needed.
- **Offline/LAN:** with a single public name (below), the phone uses the internet path at home too; the app's offline
  page (added 2026-11-11) covers "no internet".

## Hostnames (DECIDE)
A public DNS name can point either to the LAN IP (today) or to the tunnel, not both.
1. **Recommended: one name per app, tunnel-only.** `stockpulse.rubusdua.net` becomes a proxied CNAME to the tunnel;
   home devices also go via Cloudflare (a few ms more; one URL everywhere; the app keeps its default URL).
   Admin names (`beacon.`, `dsserver.`) stay LAN-only A records.
2. Split names: public `stockpulse.rubusdua.net` → tunnel, LAN `stockpulse.lan.rubusdua.net` → 192.168.68.115
   (needs a Caddy site + certificate for the LAN name; two URLs to explain).
3. Split-horizon DNS (same name, different answers at home): needs a local DNS server; the Deco cannot do it. Not recommended.

## Monitoring (each public app must have it)
- **Tunnel up:** `tunnel-cloudflared` container health → Beszel `ContainerHealth` (dsserver) → ntfy (existing rule).
- **End to end from outside:** Beacon HTTP check on `https://<app>/healthz` (bypassed in Access, returns `ok`, no data)
  → existing `NetworkMonitorLoss` alert. Beacon reaches it through the internet, so this proves DNS + Cloudflare +
  tunnel + Caddy + app. If Beacon's internet is down, netwatch classifies it as WAN, not as an app failure.
- **Cloudflare side (free):** tunnel health notifications by e-mail (Cloudflare dashboard → Notifications), optional.
- **Logs:** cloudflared logs in the container (Beszel Logs panel once dsserver's proxy allows logs).

## Procedures (after the decisions)
**Prerequisites / credentials needed (none exist yet):**
1. Cloudflare Zero Trust organisation (free plan, up to 50 users; Cloudflare may ask for a payment method even on the
   free plan; verify) and a team name.
2. A **scoped API token**: Account → Cloudflare Tunnel: Edit, Account → Access: Apps and Policies: Edit; Zone
   `rubusdua.net` → DNS: Edit. Stored like the existing tokens (root 0600, never in Git/chat). Or do the one-time steps
   in the dashboard instead.
3. The allowed e-mail addresses (Daniel, Axel).

**Activate StockPulse (one session, reversible):**
1. Create the tunnel (API/dashboard) → credentials JSON to `/etc/dsserver-secrets/cloudflared/credentials.json`.
2. Access application for `stockpulse.rubusdua.net`: OTP, allow-list, 30-day session; bypass policy for `/healthz`.
   **Access first, DNS second**, so the name is never reachable without the policy.
3. `routes.toml`: `enabled = true` → `render.py --check` → render `config.yml` → `docker compose -f tunnel/compose.yaml up -d`.
4. DNS: replace the A record `stockpulse` (192.168.68.115) with a proxied CNAME `<tunnel-id>.cfargotunnel.com`.
5. Verify: from outside (phone on mobile data) login + report; `/healthz` 200; any other hostname on the tunnel → 404;
   `beacon.`/`dsserver.` unchanged and LAN-only; Beacon external check green; ContainerHealth healthy.
6. App: build with JS-for-Access change; test login, push tap after session expiry.

**Add a route:** Caddy site for the name (LAN-tested) → routes.toml entry (`enabled = false`) + Access application →
review → `enabled = true` → render → restart cloudflared → DNS CNAME → Beacon check.
**Disable a route (fast):** `enabled = false` → render → `docker compose -f tunnel/compose.yaml restart`
(the hostname then gets 404 from the tunnel); optionally delete the CNAME.
**Rollback everything:** `docker compose -f tunnel/compose.yaml down`; DNS: CNAME back to the A record 192.168.68.115;
delete the tunnel and Access app in Cloudflare; remove `/etc/dsserver-secrets/cloudflared`. LAN access is unaffected
throughout (Caddy and the LAN A records are not touched by the tunnel).

## Offline validation done (2026-11-11)
- `render.py --check` on the real registry: ok; rendered config contains only enabled routes + default 404.
- `test_render.py`: 8 tests (infrastructure names refused, other zones/nesting refused, must go through Caddy and
  have a Caddy site, access modes, duplicates, render output, Caddyfile parsing of the real file).
- `docker compose -f tunnel/compose.yaml config`: valid.
- Not validated (needs the binary/tunnel): `cloudflared tunnel ingress validate`, the healthcheck command, Access in a WebView.
