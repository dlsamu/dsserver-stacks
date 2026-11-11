# StockPulse on dsserver

Stock screener reports for the StockPulse Android app. Served at **https://stockpulse.rubusdua.net**, home LAN only.
Source: `dlsamu/stock-tracker`, branch `dsserver`, commit in `SOURCE`. Local clone: `~/dev/stock-tracker`.

## Architecture
```
weekday timers (systemd, host)          stockpulse-job@us|intl|ath.service -> 15-stockpulse.sh job <x>
  08:00 us · 09:00 intl · 10:00 ath        -> docker compose run --rm job  (python <screener>.py)
                                              writes /data/history.db + /reports/*.html; push via FCM if key present
LAN browser / app --https:443--> Caddy (proxy/) --proxy network--> stockpulse-web (serve.py, allowlist only)
```
| Part | Where | Notes |
|---|---|---|
| Image `stockpulse:<commit12>` | built locally by `15 build` from `git archive <SOURCE>` | python 3.13.18-slim (digest-pinned), `pip --require-hashes` from `requirements.lock`, uid 10010, TZ Europe/Stockholm |
| `web` container `stockpulse-web` | always on, `restart: unless-stopped` | read-only root, all caps dropped, no-new-privileges, **no published port**, network `proxy` only, sees **only** `/reports` (read-only), health check `/healthz` |
| `job` container | started per run (`run --rm`) | same hardening; network `stockpulse_jobs` (internet for market data); `/data`, `/reports` rw, `/etc/stockpulse-secrets` ro |
| History DB | `/srv/appdata/stockpulse/data/history.db` (10010, 0700 dir) | never mounted into the web container |
| Reports | `/srv/appdata/stockpulse/reports/` (latest `report*.html`) + `reports/reports/` (archive) | served by allowlist only |
| Backups | `/srv/appdata/stockpulse/data/backups/` daily 03:15, 14 kept, integrity-checked | same disk: protects against corruption/mistakes, **not** disk loss (until the NAS/restic backup exists) |
| Firebase key | `/etc/stockpulse-secrets/firebase-service-account.json` (root:10010 0640) | absent = pushes skipped |
| Logs | journal (`journalctl -u 'stockpulse-job@*'`), `docker logs stockpulse-web` (size-bounded) | |

## Monitoring
| What | How it is detected | Notification |
|---|---|---|
| Web down / not answering through HTTPS | Beacon network check `https://stockpulse.rubusdua.net/healthz` (http, 60 s); the 15-min check (web container not running/healthy) | ntfy: "Network monitor … on beacon" (loss > 20 %/h, ≈ 12 min) and "Failed services on dsserver: stockpulse-check.service" |
| Web container unhealthy | Docker health check `/healthz`; Beszel dsserver ContainerHealth (5 min) | ntfy: "Unhealthy container stockpulse-web on dsserver" |
| Database missing/corrupt/tables, storage < 2 GiB or 5 %, wrong ownership, report missing or a symlink | `stockpulse-check.timer` (every 15 min) runs `15 check` (`check.py`) → `stockpulse-check.service` **failed** | Beszel dsserver SystemdFailed (5 min) → ntfy naming `stockpulse-check.service`; recovery message when the next run passes |
| Stale reports (only after `timers-enable`) | check: each latest report newer than the last weekday 08/09/10:00 slot + 90 min | as above |
| Backup older than 26 h / none (after `backup-enable`) | check | as above |
| Screener run failed (e.g. no tickers, crash) | `stockpulse-job@<x>.service` failed | Beszel SystemdFailed → ntfy naming the job unit, until the next successful run |

Beszel's dashboard (dsserver → Services) lists the `stockpulse-*` units and their state. The units are `Type=exec`, **not
`oneshot`**: the Beszel agent skips units that never entered the active state, which is every failed oneshot run (tested
2026-11-11). The agent re-reads the unit list every 10 min, so a check failure notifies within ≈ 15 + 10 + 5 = 30 min.
**Application vs host:** StockPulse units are application layer for `dsserver-health`: a failed StockPulse unit never turns the
Healthchecks.io check "down" (no "dsserver down" e-mail); the ping body shows `info=…,apps:failed` instead. Host problems still
report `status=fail`. ntfy texts name the StockPulse unit or monitor, so they read differently from host alerts (Status, Disk, …).
Check tests (no root, no real data): `bash stockpulse/tests/test-check.sh` (18 scenarios).
Alert test (≈ 10–15 min): `15 check-test-fail` → `15 check-now` → ntfy after the agent's next unit refresh (≤ 10 min) →
`15 check-test-clear` → `15 check-now` → recovery message after the next refresh. Without `check-now` add up to 15 min per step.

## Commands (`S=/usr/local/lib/dsserver-admin/host/scripts/15-stockpulse.sh; sudo -n $S <mode>`)
`preflight` · `build` · `import` (one-time) · `up` · `verify` · `status` · `test-reset` · `run-test us|intl|ath` ·
`push-test` · `job us|intl|ath` · `backup` · `check` · `check-now` · `check-test-fail|check-test-clear` · `check-enable` · `test-recovery` ·
`units-install` · `backup-enable` · `timers-enable|timers-disable` · `down`.
After changing anything under `stockpulse/` or the Caddyfile: commit, `sudo bash host/scripts/09-delegated-sudo.sh install <commit>`.

## Testing unreleased code (no 09 install per change)
Point branch `stockpulse-test` in `~/dev/stock-tracker` at the commit to test (`git branch -f stockpulse-test <commit>`),
then `15 test-reset` → `15 test-build` → `15 test-run us|intl|ath` → compare → `15 test-clean`.
The test image is tagged `stockpulse-test:*` (production only ever runs `stockpulse:<SOURCE>`); the run mounts only
`/srv/appdata/stockpulse-test/{data,reports}`, has no secrets mount and no Firebase key (pushes impossible), and uses its
own network `stockpulse_test`. Like production jobs it has internet (and LAN) egress, and the build installs the
commit's own `requirements.lock`, so only test commits you wrote yourself.

## Deploy from scratch / recovery
1. `~/dev/stock-tracker` contains the `SOURCE` commit (push branch `dsserver` to GitHub so it survives a disk loss).
2. `09 install <commit>` → `15 build` → `15 import` (or restore `data/` and `reports/` from backup instead) → `15 up`
   → `14 dns-ensure` + `14 up` (Caddy) → `15 verify` → `15 units-install` → `15 backup-enable` → `15 check-enable` → (approved) `15 timers-enable`.
3. Restore the DB from a backup: `15 down`, copy `data/backups/history-<time>.db` to `data/history.db` (owner 10010, 0600), `15 up`.

## Updating the code
Commit to `~/dev/stock-tracker` (branch `dsserver`), put the full commit id in `SOURCE`, commit, `09 install`, `15 build`, `15 up`,
`15 verify`. Dependency update: edit `requirements.in`, regenerate `requirements.lock` with `pip-compile --generate-hashes`.
Rollback: previous `SOURCE` commit → `09 install` → `15 build` (or reuse the old image tag) → `15 up`.

## Tested 2026-11-11 (production, LAN only; screener timers disabled throughout)
- `15 verify` 49/49 (allowlist, 404 for planted .env/key/db/logs/source/.git/symlink/traversal canaries, 405 for POST/PUT/DELETE, headers, hardening); canaries removed.
- Crash recovery: web process SIGKILLed → Docker restart, healthy after 6 s, byte-identical report.
- Backup: `history-20261111-193128.db`, integrity ok; daily timer enabled (first timed run 2026-11-12 03:15).
- **Web outage** (container removed 19:49:56–20:11:26): Caddy 502 at once; check failed 20:00:15; Beacon NetworkMonitorLoss
  alert 20:02:50 (≈ 13 min, phone confirmed). Beszel SystemdFailed did NOT fire → found the oneshot gap → units Type=exec (623779e).
- **Check failure** (flag, after the fix): unit failed 20:30:05 → Beszel alert 20:39:01 (9 min; "Failed services on dsserver",
  phone confirmed) → flag cleared 20:39:33 → check passed 20:45:10 (unit inactive/success, nothing left failed, no manual step)
  → recovery 20:49:01 (phone confirmed).
- **Healthchecks during both failures:** `status=ok info=docker:active,apps:failed` (no "dsserver down" e-mail); back to
  `status=ok info=docker:active` at 20:47:13.
- Unit tests: `stockpulse/tests/test-check.sh` 18/18, `host/tests/test-dsserver-health.sh` 53/53.
- Screener test runs (test copy, pushes impossible): intl and ath ok (same counts as the Pi); **us fails: NASDAQ screener API 403**.

## Known gaps
- Beacon's loss alert uses a 1-hour window (20 %): ≈ 13 min to alert, ≈ 1 h to recover after a web outage (shared Beacon setting, unchanged).
- Detection of a check failure takes up to 15 (timer) + 10 (agent unit refresh) + 5 min.
- If `stockpulse-check.timer` itself stopped, nothing alerts (the Beacon web check still covers web availability).
- Backups are on the same disk as the data until the NAS/restic backup exists.
- US screener: `api.nasdaq.com/api/screener` (undocumented website backend behind bot protection) returns 403 from dsserver;
  recommended replacement: the NASDAQ Trader symbol directory (`nasdaqlisted.txt`, `otherlisted.txt`). Decision pending.
