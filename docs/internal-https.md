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
