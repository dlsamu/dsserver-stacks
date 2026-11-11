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
Alert test: `15 check-test-fail` → wait for the next quarter-hour run + 5 min → `15 check-test-clear` (cleared at the next run).

## Commands (`S=/usr/local/lib/dsserver-admin/host/scripts/15-stockpulse.sh; sudo -n $S <mode>`)
`preflight` · `build` · `import` (one-time) · `up` · `verify` · `status` · `test-reset` · `run-test us|intl|ath` ·
`push-test` · `job us|intl|ath` · `backup` · `check` · `check-test-fail|check-test-clear` · `check-enable` · `test-recovery` ·
`units-install` · `backup-enable` · `timers-enable|timers-disable` · `down`.
After changing anything under `stockpulse/` or the Caddyfile: commit, `sudo bash host/scripts/09-delegated-sudo.sh install <commit>`.

## Deploy from scratch / recovery
1. `~/dev/stock-tracker` contains the `SOURCE` commit (push branch `dsserver` to GitHub so it survives a disk loss).
2. `09 install <commit>` → `15 build` → `15 import` (or restore `data/` and `reports/` from backup instead) → `15 up`
   → `14 dns-ensure` + `14 up` (Caddy) → `15 verify` → `15 units-install` → `15 backup-enable` → `15 check-enable` → (approved) `15 timers-enable`.
3. Restore the DB from a backup: `15 down`, copy `data/backups/history-<time>.db` to `data/history.db` (owner 10010, 0600), `15 up`.

## Updating the code
Commit to `~/dev/stock-tracker` (branch `dsserver`), put the full commit id in `SOURCE`, commit, `09 install`, `15 build`, `15 up`,
`15 verify`. Dependency update: edit `requirements.in`, regenerate `requirements.lock` with `pip-compile --generate-hashes`.
Rollback: previous `SOURCE` commit → `09 install` → `15 build` (or reuse the old image tag) → `15 up`.
