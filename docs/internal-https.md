# Trusted HTTPS for internal admin pages (proposal: dsnas first)

Goal: `https://dsnas.rubusdua.net` (no port, no certificate warning), LAN-only, without making NAS
administration depend on another machine, and keeping direct IP access for recovery.

Today (2026-11-14): `dsnas.rubusdua.net` resolves to 192.168.68.112 via the local resolvers (no public record).
DSM serves its login on 5000 (HTTP) and 5001 (HTTPS, self-signed "Synology Inc. CA" certificate -> browser warning);
port 443 answers but has no site for DSM. The phone's "page not found" on :5000 is most likely the browser
upgrading `http://` to `https://` on the plain-HTTP port.

## Options

| | A. Proxy on dsserver (Caddy) | B. Trusted certificate on dsnas itself (recommended) | C. DSM's built-in Let's Encrypt |
|---|---|---|---|
| How | Caddy on dsserver serves a name and proxies to dsnas:5001 | Caddy on dsserver obtains the certificate via DNS-01 (as it does for its own names); a timer imports it into DSM; DSM serves it on 443 for `dsnas.rubusdua.net` (Login Portal reverse-proxy rule to its own 5001) | DSM requests the certificate itself |
| Name | must be a **different** name (e.g. `nas.rubusdua.net` -> .115); `dsnas.rubusdua.net` must keep pointing at .112 for SMB | `dsnas.rubusdua.net` itself | `dsnas.rubusdua.net` |
| NAS admin when dsserver is down | **broken** (by name); IP fallback only | **works**: certificate lives on dsnas; dsserver only renews (90-day certificate, renewal 30 days before expiry, so ~30 days of slack plus an alert) | works |
| Credentials needed | none on dsnas | a **dedicated DSM admin account** for the import, password root-only on dsserver (DSM has no certificate-only role) | none |
| Exposure | none (LAN) | none (DNS-01, LAN) | needs **port 80 from the internet** (HTTP-01) -> violates LAN-only, rejected |
| Moving parts | Caddyfile entry | Caddyfile entry + import timer + expiry check | - |

## Recommendation: B

- Access path = dsnas + local DNS only (two independent resolvers). dsserver is needed only every ~60 days to renew.
- Recovery unchanged: `https://192.168.68.112:5001` (self-signed warning) always works, also if DNS or the
  certificate fails. DSM's own 5000/5001 stay as they are.
- Renewal: Caddy already holds the Cloudflare DNS-edit token on dsserver and renews `dsserver.rubusdua.net`; it
  gets a site entry for `dsnas.rubusdua.net` only to obtain the certificate (the name never points at dsserver).
- Import: `dsnas-cert-push` timer on dsserver (daily): if Caddy's certificate for dsnas differs from what dsnas
  serves, import it with `SYNO.Core.Certificate` `import` (the documented call used by acme.sh's `synology_dsm`
  hook), assign it to the DSM web service, then verify by TLS handshake. Failure -> unit fails ->
  Beszel SystemdFailed -> ntfy.
- Independent expiry check from Beacon: alert when the certificate served on dsnas:443 has < 21 days left.
- DSM setting: **native customized domain** (Login Portal > DSM), no reverse-proxy rule (see review below).
- Firewall: unchanged (dsnas allows the LAN only; no router forwards).
- Certificate Transparency: the name `dsnas.rubusdua.net` becomes publicly visible in CT logs (as beacon. and
  dsserver. already are). It reveals the name, not the address (there is no public record).

## Needs owner approval before implementation
1. A dedicated DSM administrator account (e.g. `cert-deploy`, random 32-char password, root-only on dsserver,
   used only by the import timer; DSM applications other than DSM denied) - DSM has no narrower role for
   certificate import.
2. The Caddyfile change on dsserver (one site entry) and the import timer (delegated script).
3. The DSM customized-domain setting on dsnas.

Later candidates for the same pattern: none needed now (beacon. and dsserver. already have trusted HTTPS).

## Design review 2026-11-14 (owner's two questions)

### 1. DSM customized domain instead of a reverse-proxy rule
dsnas (DSM 7.4.1) exposes it natively: `SYNO.Core.Web.DSM` has `enable_custom_domain` (currently false) and `fqdn`
(null) next to `http_port 5000` / `https_port 5001`, i.e. the Login Portal > DSM "Customized domain" setting. Its
purpose is serving the DSM login under that host name on the default ports 80/443, which is exactly the
requirement; no reverse-proxy rule (DSM's own nginx, `SYNO.Core.AppPortal.ReverseProxy` has no entries today) is
needed. Synology's online help pages could not be read (empty shells), so the behaviour is confirmed by a first,
reversible implementation step: enable it with `fqdn=dsnas.rubusdua.net` while the self-signed certificate is still
in place, check `https://dsnas.rubusdua.net/` reaches the DSM login, 5000/5001 and SMB unchanged; switch back
off if not. **Adopted:** simpler (one DSM setting instead of a proxy rule), survives DSM upgrades as a first-class
setting, and keeps 5001 untouched for recovery.

### 2. acme.sh `SYNO_USE_TEMP_ADMIN=1` instead of a permanent deploy account
From the hook source (`deploy/synology_dsm.sh`) and the acme.sh Synology wiki:
- it works **only when acme.sh runs on the NAS itself as root** ("only support local deployment, can't be used to
  deploy in docker or deploy remotely"): it calls `synouser`/`synogroup` to create `sc-acmesh-tmp`, adds it to
  administrators, logs in to `localhost:5000`, imports via `SYNO.Core.Certificate` `import`, then deletes the user
  (the wiki notes it can be left behind if the script dies);
- if 2FA enforcement is on it temporarily switches `otp_enforce_option` off in `/etc/synoinfo.conf`;
- so it needs acme.sh installed on DSM (`/usr/local/share/.acme.sh`), a **root** Task Scheduler job, and the
  **Cloudflare DNS-edit token stored on dsnas** for DNS-01; the wiki documents re-fixing acme.sh after DSM upgrades.

| | B: permanent `cert-deploy` account, push from dsserver | acme.sh on dsnas with temp admin |
|---|---|---|
| Credential at rest | DSM admin password for **dsnas only**, root-only on dsserver (already holds the Cloudflare token for its own certificates) | **Cloudflare token with DNS-edit for the whole rubusdua.net zone on dsnas** (tokens cannot be limited to one record): whoever gets it can repoint `stockpulse` and issue certificates for any name |
| Software added | none (Caddy already runs; a small timer script in the repo) | acme.sh on DSM + root scheduled task (unversioned, outside the repo) |
| Privileged actions | API login of one account | root on DSM creating/deleting an admin and toggling 2FA enforcement on every renewal |
| DSM upgrade risk | API call used by acme.sh's remote mode (stable across DSM 7.x); failure alerts, certificate keeps working ~30 days | acme.sh install under `/usr/local` + root task may need repair after upgrades (wiki) |
| Dependency on dsserver | renewal only (normal operation independent) | none |
| Maintenance | repo + delegated script + tests, monitored | separate toolchain on the NAS |

**Conclusion: keep the permanent dedicated account (design B).** Temp-admin mode does not remove a stored secret, it
replaces a dsnas-only admin password on a hardened host with a zone-wide DNS token on the NAS, and adds software
and root automation to DSM. Mitigations for the account: random 32-character password, root-only on dsserver,
used only by the delegated timer, DSM applications other than DSM denied, LAN-only by firewall, a login from any
other host would show in DSM's connection log; rotate on any suspicion.

## Implementation (live 2026-11-14)

| Part | Where | State |
|---|---|---|
| DSM customized domain `dsnas.rubusdua.net` (no reverse proxy) | dsnas `SYNO.Core.Web.DSM` `enable_custom_domain=true`, `fqdn=dsnas.rubusdua.net` | reversible test passed, kept |
| Certificate issuance/renewal (Let's Encrypt, DNS-01) | dsserver Caddy, `proxy/Caddyfile` site `dsnas.rubusdua.net` marked `# cert-only` (`dns-ensure` never creates a public record for it; requests reaching dsserver for that name get 421) | issued 2026-11-14, valid to 2027-02-12; Caddy renews ~30 days before expiry |
| Deployment | `host/bin/dsnas-cert-push` via `host/scripts/18-dsnas-cert.sh` (delegated), timer `dsnas-cert-push.timer` daily 04:40 (+0-20 min) | first deployment, no-op run and forced re-import (renewal simulation) passed |
| DSM certificate entry | id `Ys2ldQ`, description `dsnas.rubusdua.net (Let's Encrypt via dsserver Caddy DNS-01)`, system default, bound to *DSM Desktop Service* and *dsnas.rubusdua.net* (binding set once by the owner in DSM; in-place replacement keeps it) | verified after the forced re-import |
| Deploy account `cert-deploy` | administrators group (required by DSM); password 32 chars in `/etc/dsserver-secrets/dsnas-cert-deploy.pw` (root 0600); application privileges: DSM allowed **only from 192.168.68.115**, AFP/FTP/rsync/SFTP/File Station/Universal Search/SMB denied; **No access** on every share | `18 selftest`: DSM API login from dsserver ok, File Station refused (160), SMB refused |
| Expiry monitoring (independent of dsserver) | Beacon `beacon/certwatch/cert_expiry.py`, `cert-expiry.timer` every 6 h, checks dsnas/dsserver/beacon names by LAN address with full chain + hostname validation, fails at < 21 days or untrusted -> Beszel SystemdFailed (beacon) -> ntfy | first run: all three trusted, 87-90 days |

TLS identity during deployment: before any password is sent, dsnas must present a publicly trusted certificate for
`dsnas.rubusdua.net` (normal case). Only while it still served the factory self-signed certificate was a bootstrap
allowed, and only with that certificate's SHA-256 pinned in the code (recorded independently from dsserver and
Beacon). Verification is never disabled. MFA: dsnas's global 2FA policy is "none" and was not touched; `cert-deploy`
has no 2FA (automation). If admin 2FA enforcement is ever switched on, `cert-deploy` login fails (error 403) and the
alert fires: then exempt the account or move to device-token login.

## Operations
```bash
S=/usr/local/lib/dsserver-admin/host/scripts
sudo -n $S/18-dsnas-cert.sh check      # Caddy vs dsnas certificate, trust, days left (read-only)
sudo -n $S/18-dsnas-cert.sh push       # what the timer does: deploy only if different
sudo -n $S/18-dsnas-cert.sh force      # re-import the same certificate (renewal drill, no reissue)
sudo -n $S/18-dsnas-cert.sh selftest   # account restrictions
sudo -n $S/18-dsnas-cert.sh status     # timer + last runs
ssh beacon 'journalctl -u cert-expiry -n 5 -o cat'
```

## Dependencies
- **Normal use** of `https://dsnas.rubusdua.net/`: dsnas + one of the two local resolvers. Not dsserver, not the internet.
- **Renewal**: dsserver (Caddy + timer), Cloudflare API (DNS-01), Let's Encrypt. If any is down, the current
  certificate keeps working; Caddy retries; dsnas still has ~30 days when renewal starts; Beacon alerts at 21 days.
- `https://dsnas.rubusdua.net:5001/` answers 404 by design once the customized domain is set: use the name without a port.

## Recovery
1. Name or certificate broken: `https://192.168.68.112:5001/` (DSM login always available; browser shows a name
   mismatch warning because the certificate is issued to the name - accept it once) or `http://192.168.68.112:5000/`.
2. Deployed a bad certificate: DSM > Control Panel > Security > Certificate > Settings: bind *DSM Desktop Service*
   and *dsnas.rubusdua.net* back to the self-signed `synology` certificate (kept, never deleted).
3. Disable the customized domain: DSM > Login Portal > DSM > uncheck Customized domain (DSM stays on 5000/5001).
4. Rotate the deploy password: `18 gen-password` only creates a missing file, so `sudo shred -u
   /etc/dsserver-secrets/dsnas-cert-deploy.pw`, `18 gen-password`, set the new value in DSM (User > cert-deploy),
   `18 selftest`.
5. Stop the automation: `sudo systemctl disable --now dsnas-cert-push.timer` (manual, as root); delete the DSM
   account `cert-deploy` in DSM.

## Trade-offs accepted
- A DSM administrator credential exists on dsserver (root-only, used by one timer, DSM login only from dsserver,
  no file or share access). Compromise of root on dsserver = admin on dsnas; root on dsserver already implies the
  Cloudflare DNS token and all dsserver data.
- The name `dsnas.rubusdua.net` appears in public Certificate Transparency logs (the address does not).
- Caddy on dsserver answers `dsnas.rubusdua.net` with 421 if a client is pointed at dsserver by mistake.
