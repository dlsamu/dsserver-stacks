# StockPulse review (handover projects 01–03) — 2026-11-10

Read-only review of `dlsamu/stock-tracker` @ `f06e3d5` and `dlsamu/stockpulse` @ `ea0727f` (both equal to the handover's commits), cloned to `~/dev/` on dsserver, against the Pi handover `dsserver-migration-v2`. Nothing was deployed, no screener was run, no push was sent, and the Pi and its public endpoint were not contacted.

## 1. Critical: `serve.py` serves its whole directory (production Pi exposed)

`Handler` subclasses `SimpleHTTPRequestHandler` with `directory=DIR` (the repo directory) and falls back to `super().do_GET()` for every path that isn't `/` or an APK page. So **any file in `~/stock-tracker/` is downloadable, and directory listings are on** (`/?`, `/reports/`). Path traversal outside the directory is blocked (stdlib), but inside it nothing is.

Confirmed with a local test (127.0.0.1, dummy files in a scratch copy): `/firebase-service-account.json`, `/.env`, `/history.db`, `/serve.py`, `/.git/config`, `/reports/` and `/?` all return **200**.

On the Pi this directory holds S1 (Firebase service-account key: FCM send rights), S9 `.env` (incl. the **Supabase service-role key**), `history.db`, logs, `.git`, and it is published to the internet as `fluffyfury.duckdns.org:8080` via the router forward. Request logging is disabled (`log_message` → `pass`), so **there is no way to tell whether it was accessed**. The handover lists "exposes only the report routes" as a requirement for the *replacement*, but did not notice that the current server violates it.

**Recommended (user decision; Pi changes are the user's):**
1. Mitigate on the Pi now: either apply the allowlist fix below and restart `stock-report`, or (fastest) have the user temporarily remove the router's 8080 forward (the app then shows a network error until restored).
2. Treat S1 and S9 as compromised: generate a new Firebase service-account key and delete the old key ID in Google Cloud IAM; rotate the Supabase service-role key. (Both were already recommended because of the first handover zip.)
3. Don't probe the public endpoint from dsserver to "confirm"; the code makes it certain.

**Fix (prepared, not committed):** `serve-allowlist.diff` (in this session's scratchpad; to be committed to `dlsamu/stock-tracker` once approved). It serves exactly the 5 `/latest/...` routes, their stable filenames (`/report.html` etc., the app's fallback route), the APK landing pages, and `/` → 302 `/latest/us`; everything else is 404, with no directory serving or listings. `Cache-Control: no-store` and `ThreadingHTTPServer` are kept. Tested locally: 21 paths × GET/HEAD, all as expected. Side effect: the dropped games' `.apk` files are no longer downloadable (their landing pages remain until removed).

## 2. Handover vs source: discrepancies

| # | Handover | Source | Impact |
|---|---|---|---|
| D1 | `serve.py` serves the reports at `/latest/...` | Serves **every file** in the directory + listings (§1) | Critical |
| D2 | `/` redirects to the report | Redirects to `/report.html` (the stable file, not a route) | Cosmetic; fix redirects to `/latest/us` |
| D3 | Paths are relative to the script dir | Confirmed — and that means **code and data share one directory**: `history.db`, `report*.html`, `reports/`, credentials all live inside the git checkout | The service user needs write access to its code dir; no data-dir setting exists |
| D4 | Persistent data: `history.db`, reports, logs | Also **yfinance's cache** (`~/.cache/py-yfinance`, tz/cookie cache via platformdirs) | The service user needs a writable home/cache dir |
| D5 | `requirements.txt` incomplete (missing `requests`, `google-auth`) | Confirmed | Pin all four direct deps for the venv |
| D6 | Reports not sensitive | Reports embed API-supplied strings **without HTML escaping** | Low: the app's WebView has `javaScriptEnabled = false`; a desktop browser would run injected script. Fix later |
| D7 | README: `push_notify` also used by games' `deploy.py` | Games are dropped | None for dsserver; the APK routes can go after cutover (handover Q10) |
| D8 | App: cleartext only for `fluffyfury.duckdns.org` | Confirmed; also any link with port 8080 on another host is rewritten to `REPORT_HOST` | Must change with project 02 |

Confirmed as stated: Python 3.13 compatible (stdlib + yfinance/pandas; dsserver has 3.13.5, same as the Pi), no env vars used (`.env` only feeds dropped game code), DB schema (3 tables, created/migrated in code by `init_db`), push skips cleanly when the credential is missing, `ThreadingHTTPServer`, `no-store`, no retries for pushes, FCM topic `stockpulse-reports`, data-only messages with `route`.

## 3. Area notes

**Runtime and dependencies.** Direct: `yfinance` (1.4.1 on the Pi; pulls pandas 3.0.3, numpy, curl_cffi, lxml, peewee, protobuf, websockets…), `python-dotenv`, `requests`, `google-auth`. yfinance isn't in Debian, so a **venv** is required (needs the `python3-venv` package; not installed yet). Pin to the Pi's versions first for an identical comparison.

**Web server.** Stdlib `ThreadingHTTPServer` on `0.0.0.0:8080`, no TLS, no auth, request logs silenced. After the fix: fine for LAN/tailnet; public access stays project 02 (TLS reverse proxy/tunnel — the user's choice).

**Database and recoverability.** SQLite `history.db` (704 KB; `qualifiers`, `runs`, `ath_weeks`), single writer at a time (screeners run 1 h apart), the server never touches it. Copy with the SQLite backup API outside 08:00–10:30 on weekdays. Backfill scripts can rebuild ~30 days only, so it's not fully regenerable. **No backup exists anywhere today.** Backup for dsserver: a nightly `sqlite3 .backup` into `/srv/appdata`, then into restic when the NAS exists. Until cutover the Pi's copy is the master, so a dark dsserver copy doesn't trigger the "no valuable data before backups" rule.

**Scheduling and notifications.** 3 cron jobs (08/09/10 Mon–Fri, Europe/Stockholm; dsserver is already on that TZ). Pushes are sent only if `firebase-service-account.json` exists next to `push_notify.py`. On dsserver it stays **absent** until the M5 cutover, so no duplicate notifications are possible. Timers with `Persistent=true` later (M5).

**Android app.** AGP 8.5.2, Kotlin 1.9.24, Gradle 8.7, compile/target SDK 35, Firebase BoM 33.1.2 (messaging). Hardcoded `REPORT_HOST`/`REPORT_PORT`/`http://` in `MainActivity.kt` and `network_security_config.xml`. JS disabled in the WebView (good). Built only in GitHub Actions; nothing runs on dsserver. The debug keystore is committed on purpose. No app change is needed until project 02.

**Persistent storage.** `history.db` (important), `report*.html` (current, regenerated), `reports/` (37 MB archive, nice to have), logs (unrotated on the Pi → journald on dsserver), yfinance cache (disposable). Credential S1 only at M5.

## 4. Docker Compose vs native systemd

**Native systemd** (agrees with the handover and our hybrid model). It's one stdlib HTTP process plus three short batch scripts and one SQLite file. Compose would add an image build, a registry/pinning cycle and volume ownership work, with no real gain once `serve.py` stops serving the code directory. Instead, isolation comes from systemd: a dedicated user and a read-only filesystem except the data dir.

## 5. Fit with dsserver conventions

| Convention | Plan |
|---|---|
| `/srv/stacks` = config in Git, `/srv/appdata` = data | Unit file and install script in `/srv/stacks/apps/stock-tracker/`; runtime checkout + data in `/srv/appdata/stock-tracker/` (D3 forces code and data together for now; a `STOCK_TRACKER_DATA_DIR` setting can split them later) |
| No service as daniel; axel isolated | System user **`stocktracker`** (no shell, no sudo, no docker), home `/srv/appdata/stock-tracker` (0750) |
| Firewall: published only via an access scope | Nothing to change for M3a: 8080 is not in `lan_tcp`, so it's reachable on dsserver itself (127.0.0.1) only. LAN test from a phone = a later, separate `lan_tcp` addition |
| Root steps via a reviewed script | `host/scripts/12-stock-tracker.sh` (preflight / install / verify / status / rollback), run in Konsole |
| No secrets in Git | S1 not needed until M5; `.env` not migrated |
| No unrotated logs | `serve.py` → journal; screeners (later) → journal via units |

## 6. Proposed smallest milestone: M3a "stock-tracker serving on dsserver, dark"

**Goal:** dsserver's `serve.py` (with the allowlist fix) serves a copy of the Pi's current reports on `127.0.0.1:8080`, as a hardened systemd service. No screeners, no timers, no Firebase credential, no firewall change, no Pi change.

1. **Code fix (needs approval):** commit the allowlist fix to `dlsamu/stock-tracker` (daniel's key, in Konsole; the user's auto-commit convention). The Pi keeps running its old commit until the user updates it (§1).
2. **Script `12-stock-tracker.sh install`** (Konsole, root): installs `python3-venv`, creates user `stocktracker`, `git clone`s the fixed commit from `~/dev/stock-tracker` (local, no GitHub access needed) into `/srv/appdata/stock-tracker/app`, creates the venv with pinned deps (PyPI over HTTPS; versions = the Pi's), installs `stock-tracker-web.service` (`User=stocktracker`, `ProtectSystem=strict`, `ReadWritePaths=` the data dir, `ProtectHome=yes`, `PrivateTmp`, `NoNewPrivileges`), but does **not** start it.
3. **Data copy (user, from the Pi):** consistent `history.db` (backup API) + the 5 `report*.html` via the Pi's existing SSH to dsserver, into a staging dir; the script installs them with the right owner.
4. **Start + verify:** all 5 `/latest/...` routes return 200 with `no-store` on 127.0.0.1; credential/db/`.git` paths return 404; no firebase file present; `ss` shows 8080 and `nft` shows 8080 blocked from the LAN; `history.db` row counts equal the Pi's numbers.

**Next (separately approved):** M3b: one manual screener dry run as `stocktracker` (no credential → "skipping push"), compared with the Pi's same-day report; then optional LAN access to 8080 for a phone test; then timers (disabled) ready for M5.

## Open decisions for the user
1. Pi exposure (§1): mitigation now (fix + restart, or drop the router forward) and rotation of S1/S9.
2. Approve committing the `serve.py` fix to `dlsamu/stock-tracker`.
3. Approve the M3a plan (user name `stocktracker`, paths, native systemd).
