#!/bin/bash
# dsserver: StockPulse (stockpulse/: compose, Dockerfile, systemd units; stockpulse/README.md).
# Delegated through 09-delegated-sudo.sh: runs the reviewed files in the root-owned snapshot.
#
#   preflight        read-only: docker, source commit, data, secrets, image, units
#   build            image stockpulse:<commit> from `git archive` of stockpulse/SOURCE in ~/dev/stock-tracker
#   import           ONE-TIME: ~/stockpulse-import (checksums verified) -> /srv/appdata/stockpulse; refuses if data exists
#   up               (re)create the web container (report server; reached only through Caddy)
#   verify           container hardening, data permissions, HTTPS routes through Caddy, canary leak test
#   status           containers, last runs, timers, data sizes
#   test-reset       fresh test copy of the data in /srv/appdata/stockpulse-test (history.db via the backup API)
#   run-test us|intl|ath   screener run against the TEST copy; pushes impossible (no key, test topic)
#   push-test        one push to topic "stockpulse-test" (no device subscribes); needs the Firebase key
#   job us|intl|ath  PRODUCTION run (real data; pushes if the key exists). Used by the timers.
#   backup           history.db -> data/backups/history-<time>.db (backup API, integrity check, keep 14)
#   check            application check (stockpulse/check.py + web container health); exit 1 = problem.
#                    Run every 15 min by stockpulse-check.timer: a failure leaves the unit failed, which
#                    Beszel's SystemdFailed alert (dsserver) sends to ntfy; the next passing run clears it.
#   check-test-fail | check-test-clear   inject / remove a deliberate check failure (alert pipeline test)
#   check-enable     install + enable stockpulse-check.timer
#   check-now        start stockpulse-check.service now (short alert tests; the unit records the result)
#   test-recovery    SIGKILL the web process; Docker must restart it and serve the same report
#   units-install    install the systemd units (nothing enabled)
#   backup-enable    enable the daily backup timer
#   timers-enable | timers-disable   the three weekday screener timers (production schedule)
#   down             stop and remove the web container (data untouched)
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
STACK=$ROOT/stockpulse
COMMIT=$(tr -d '[:space:]' < "$STACK/SOURCE")
export STOCKPULSE_IMAGE=stockpulse:${COMMIT:0:12}
REPO=/home/daniel/dev/stock-tracker
IMPORT=/home/daniel/stockpulse-import
APP=/srv/appdata/stockpulse
TEST=/srv/appdata/stockpulse-test
SECRETS=/etc/stockpulse-secrets
NAME=stockpulse.rubusdua.net
UNITS="stockpulse-job@.service stockpulse-us.timer stockpulse-intl.timer stockpulse-ath.timer stockpulse-backup.service stockpulse-backup.timer stockpulse-check.service stockpulse-check.timer"
STATE=/var/lib/stockpulse
ARCHIVE_RE='report(_ath|_intl_(pacific|european|nordic))?_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}(_TEST)?\.html'
UID_=10010
ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
FAILS=0
[ "$(id -u)" = 0 ] || fail "run as root"
[ "$(hostname)" = dsserver ] || fail "not dsserver"
[[ $COMMIT =~ ^[0-9a-f]{40}$ ]] || fail "stockpulse/SOURCE must hold a full commit id"

dc() { docker compose -f "$STACK/compose.yaml" "$@"; }
script_for() { case $1 in us) echo stock_tracker.py ;; intl) echo intl_tracker.py ;; ath) echo ath_screener.py ;; *) fail "unknown job '$1' (us|intl|ath)" ;; esac; }
need_image() { docker image inspect "$STOCKPULSE_IMAGE" >/dev/null 2>&1 || fail "image $STOCKPULSE_IMAGE missing: run build"; }
dirs() {
    install -d -m 0750 -o root -g "$UID_" "$SECRETS"
    install -d -m 0750 -o root -g root "$APP"
    install -d -m 0700 -o "$UID_" -g "$UID_" "$APP/data"
    install -d -m 0755 -o "$UID_" -g "$UID_" "$APP/reports" "$APP/reports/reports"
}
# One screener/backup at a time (they share history.db); waits up to an hour.
locked() { flock -w 3600 /run/stockpulse.lock "$@"; }
jobrun() { locked env "$@"; }

case "${1:-}:$#" in
  preflight:1)
    systemctl is-active --quiet docker && ok "docker active" || bad "docker not active"
    docker network inspect proxy >/dev/null 2>&1 && ok "network proxy exists (Caddy)" || bad "network proxy missing (14 up)"
    runuser -u daniel -- git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null && ok "source commit ${COMMIT:0:12} present in $REPO" || bad "commit $COMMIT not in $REPO"
    echo "image: $(docker image inspect -f '{{.Id}}' "$STOCKPULSE_IMAGE" 2>/dev/null | cut -c1-19 || echo 'not built')"
    [ -s "$APP/data/history.db" ] && echo "data: history.db present" || echo "data: not imported yet"
    [ -s "$SECRETS/firebase-service-account.json" ] && echo "firebase key: present" || echo "firebase key: absent (pushes are skipped)"
    echo "web: $(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' stockpulse-web 2>/dev/null || echo absent)"
    for t in us intl ath backup; do echo "timer $t: $(systemctl is-enabled stockpulse-$t.timer 2>/dev/null || echo not-installed)"; done
    [ "$FAILS" = 0 ] && echo "15 PREFLIGHT PASSED" || fail "$FAILS check(s) failed" ;;

  build:1)
    tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
    mkdir "$tmp/src"
    runuser -u daniel -- git -C "$REPO" archive --format=tar "$COMMIT" | tar -x -C "$tmp/src"
    cp "$STACK/Dockerfile" "$tmp/Dockerfile"
    docker build -q -t "$STOCKPULSE_IMAGE" --label "org.opencontainers.image.revision=$COMMIT" "$tmp" >/dev/null
    ok "built $STOCKPULSE_IMAGE ($(docker image inspect -f '{{.Id}}' "$STOCKPULSE_IMAGE" | cut -c1-19), source $COMMIT)"
    docker run --rm --network none "$STOCKPULSE_IMAGE" python -c 'import yfinance, pandas, sys, time; print("python", sys.version.split()[0], "yfinance", yfinance.__version__, "pandas", pandas.__version__, "tz", time.strftime("%Z"))' ;;

  import:1)
    [ ! -e "$APP/data/history.db" ] || fail "$APP/data/history.db exists: import is one-time only (nothing changed)"
    ( cd "$IMPORT" && sha256sum --quiet -c SHA256SUMS ) || fail "checksums in $IMPORT do not match"
    ok "import checksums verified"
    python3 -I - "$IMPORT/reports.tar" "$ARCHIVE_RE" <<'EOF' || fail "reports.tar contains unexpected members"
import re, sys, tarfile
rx = re.compile(r"reports/(%s)?" % sys.argv[2])
with tarfile.open(sys.argv[1]) as t:
    bad = [m.name for m in t.getmembers() if not ((m.isfile() or m.isdir()) and rx.fullmatch(m.name.rstrip("/") + ("/" if m.isdir() else "")))]
sys.exit(1 if bad else 0)
EOF
    ok "reports.tar: only report files and the reports/ directory"
    dirs
    install -m 0600 -o "$UID_" -g "$UID_" "$IMPORT/history.db.backup" "$APP/data/history.db"
    for f in "$IMPORT"/latest-reports/report*.html; do install -m 0644 -o "$UID_" -g "$UID_" -p "$f" "$APP/reports/"; done
    tar -x -C "$APP/reports" --no-same-owner --no-same-permissions -f "$IMPORT/reports.tar"
    chown -R "$UID_:$UID_" "$APP/reports"; find "$APP/reports" -type f -exec chmod 0644 {} +; find "$APP/reports" -type d -exec chmod 0755 {} +
    python3 -I - "$APP/data/history.db" <<'EOF' || fail "imported database check failed"
import sqlite3, sys
c = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
r = c.execute("pragma integrity_check").fetchone()[0]
n = {t: c.execute(f"select count(*) from {t}").fetchone()[0] for t in ("runs", "qualifiers", "ath_weeks")}
print(f"ok    history.db integrity {r}; rows {n}; latest run {c.execute('select max(run_date) from runs').fetchone()[0]}")
sys.exit(0 if r == "ok" and n == {"runs": 1525, "qualifiers": 9592, "ath_weeks": 846} else 1)
EOF
    ok "reports: $(ls "$APP"/reports/report*.html | wc -l) latest, $(ls "$APP/reports/reports" | wc -l) archived"
    echo "15 IMPORT DONE (source files in $IMPORT left unchanged)" ;;

  up:1)
    need_image; dirs
    dc up -d --no-build --force-recreate web 2>&1 | tail -n 2
    for _ in $(seq 30); do [ "$(docker inspect -f '{{.State.Health.Status}}' stockpulse-web 2>/dev/null)" = healthy ] && break; sleep 2; done
    [ "$(docker inspect -f '{{.State.Health.Status}}' stockpulse-web)" = healthy ] && ok "stockpulse-web healthy" || fail "stockpulse-web not healthy"
    echo "15 UP DONE" ;;

  verify:1)
    w=stockpulse-web
    [ "$(docker inspect -f '{{.State.Running}} {{.State.Health.Status}} {{.HostConfig.RestartPolicy.Name}}' $w 2>/dev/null)" = "true healthy unless-stopped" ] && ok "$w running, healthy, restart unless-stopped" || bad "$w state"
    [ "$(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' $w)" = "10010:10010 true [ALL] [no-new-privileges:true]" ] && ok "$w: uid 10010, read-only root, all capabilities dropped, no-new-privileges" || bad "$w hardening: $(docker inspect -f '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.HostConfig.SecurityOpt}}' $w)"
    [ "$(docker inspect -f '{{json .HostConfig.PortBindings}}' $w)" = "{}" ] && ok "$w publishes no ports" || bad "$w publishes ports"
    [ "$(docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' $w)" = "proxy " ] && ok "$w only on network proxy" || bad "$w networks"
    [ "$(docker inspect -f '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' $w)" = "/reports:false /tmp:true " ] || [ "$(docker inspect -f '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' $w)" = "/reports:false " ] \
      && ok "$w sees only /reports (read-only); no data, secrets or code directories" || bad "$w mounts: $(docker inspect -f '{{range .Mounts}}{{.Destination}}:{{.RW}} {{end}}' $w)"
    [ "$(stat -c '%u %a' "$APP/data")" = "$UID_ 700" ] && ok "$APP/data 10010 0700" || bad "$APP/data perms"
    [ "$(stat -c '%U %g %a' "$SECRETS")" = "root $UID_ 750" ] && ok "$SECRETS root:10010 0750" || bad "$SECRETS perms"
    [ ! -e "$SECRETS/firebase-service-account.json" ] || [ "$(stat -c '%U %g %a' "$SECRETS/firebase-service-account.json")" = "root $UID_ 640" ] && ok "firebase key absent or root:10010 0640" || bad "firebase key perms"
    # HTTP through Caddy (the only path), with canary files planted where the old server leaked.
    canaries=(.env firebase-service-account.json history.db history.db-journal run.log intl_run.log config.yaml backup.tar.gz serve.py stock_tracker.py requirements.lock .git/config .git/HEAD)
    cleanup() { for c in "${canaries[@]}"; do rm -f "$APP/reports/$c"; done; rmdir "$APP/reports/.git" 2>/dev/null || true; rm -f "$APP/reports/reports/report_2000-01-01_00-00.html" "$APP/reports/reports/canary.db"; }
    trap cleanup EXIT
    mkdir -p "$APP/reports/.git"
    for c in "${canaries[@]}"; do echo "CANARY-$RANDOM-LEAK" > "$APP/reports/$c"; done
    echo "CANARY-db-LEAK" > "$APP/reports/reports/canary.db"
    ln -s "$APP/data/history.db" "$APP/reports/reports/report_2000-01-01_00-00.html"
    get() { curl -s --path-as-is -o /tmp/stockpulse-verify.body -w '%{http_code}' --resolve "$NAME:443:127.0.0.1" -X "${2:-GET}" "https://$NAME$1" || echo ERR; }
    leak() { grep -qE 'CANARY|SQLite format' /tmp/stockpulse-verify.body 2>/dev/null; }
    while read -r path want; do
      got=$(get "$path")
      if [ "$got" = "$want" ] && ! leak; then ok "GET $path -> $got"; else bad "GET $path -> $got (want $want)$(leak && echo ', CONTENT LEAKED')"; fi
    done <<EOF
/ 200
/latest/us 200
/latest/ath 200
/latest/intl/nordic 200
/latest/intl/european 200
/latest/intl/pacific 200
/report.html 200
/archive/ 200
/healthz 200
/.env 404
/firebase-service-account.json 404
/history.db 404
/history.db-journal 404
/run.log 404
/intl_run.log 404
/config.yaml 404
/backup.tar.gz 404
/serve.py 404
/stock_tracker.py 404
/requirements.lock 404
/push_notify.py 404
/.git/config 404
/.git/HEAD 404
/.git/ 404
/reports/ 404
/reports/canary.db 404
/archive/canary.db 404
/archive/report_2000-01-01_00-00.html 404
/archive/../history.db 404
/archive/%2e%2e/%2e%2e/data/history.db 404
/latest/us/../../.env 404
/data/history.db 404
/etc/passwd 404
/../../../etc/passwd 404
/run/secrets/stockpulse/firebase-service-account.json 404
EOF
    a=$(find "$APP/reports/reports" -maxdepth 1 -type f -regextype posix-extended -regex ".*/$ARCHIVE_RE" -printf '%f\n' -quit)
    [ "$(get "/archive/$a")" = 200 ] && ok "GET /archive/<a real report> -> 200" || bad "archived report not served"
    for m in POST PUT DELETE; do [ "$(get / $m)" = 405 ] && ok "$m / -> 405" || bad "$m / not refused"; done
    h=$(curl -sI --resolve "$NAME:443:127.0.0.1" "https://$NAME/latest/us")
    grep -qi "content-security-policy: default-src 'none'" <<<"$h" && grep -qi 'cache-control: no-store' <<<"$h" && grep -qi 'x-content-type-options: nosniff' <<<"$h" \
      && ok "headers: CSP default-src 'none', Cache-Control no-store, nosniff" || bad "security headers missing"
    rm -f /tmp/stockpulse-verify.body
    cleanup; trap - EXIT
    left=$(cd "$APP/reports" && ls -A | grep -vE '^(report(_ath|_intl_(pacific|european|nordic))?\.html|reports)$' || true)
    [ -z "$left" ] && ok "canaries removed; report dir holds only reports" || bad "unexpected files in report dir: $left"
    [ "$FAILS" = 0 ] && echo "15 VERIFY PASSED" || fail "$FAILS check(s) failed" ;;

  status:1)
    docker ps -a --filter name=stockpulse --format '{{.Names}} {{.Image}} {{.Status}}'
    systemctl list-timers 'stockpulse-*' --all --no-pager 2>/dev/null | head -n 7 || true
    for j in us intl ath; do echo "job $j: $(systemctl show -p Result,ExecMainExitTimestamp --value "stockpulse-job@$j.service" 2>/dev/null | tr '\n' ' ')"; done
    du -sh "$APP/data" "$APP/reports" 2>/dev/null || true
    ls -1t "$APP/data/backups" 2>/dev/null | head -n 2 ;;

  test-reset:1)
    need_image; [ -s "$APP/data/history.db" ] || fail "nothing imported yet"
    rm -rf "$TEST"; install -d -m 0750 "$TEST"
    install -d -m 0700 -o "$UID_" -g "$UID_" "$TEST/data"; install -d -m 0755 -o "$UID_" -g "$UID_" "$TEST/reports" "$TEST/reports/reports"
    install -m 0644 -o "$UID_" -g "$UID_" -p "$APP"/reports/report*.html "$TEST/reports/"
    docker run --rm --network none --user "$UID_:$UID_" --read-only -v "$APP/data:/src:ro" -v "$TEST/data:/data" "$STOCKPULSE_IMAGE" \
      python -c 'import sqlite3; s=sqlite3.connect("file:/src/history.db?mode=ro",uri=True); d=sqlite3.connect("/data/history.db"); s.backup(d); print("test copy:", d.execute("pragma integrity_check").fetchone()[0], d.execute("select count(*) from runs").fetchone()[0], "runs")'
    ok "test data ready in $TEST (production data untouched)" ;;

  run-test:2)
    need_image; s=$(script_for "$2"); [ -s "$TEST/data/history.db" ] || fail "run test-reset first"
    echo "--- TEST run $2 ($s) against $TEST, pushes disabled (no key, topic stockpulse-test), started $(date +%T)"
    jobrun STOCKPULSE_DATA="$TEST/data" STOCKPULSE_REPORTS="$TEST/reports" STOCKPULSE_FCM_KEY=/nonexistent/key STOCKPULSE_FCM_TOPIC=stockpulse-test \
      docker compose -f "$STACK/compose.yaml" --profile job run --rm --no-deps job python "$s"
    echo "--- finished $(date +%T)" ;;

  push-test:1)
    need_image; [ -s "$SECRETS/firebase-service-account.json" ] || fail "no Firebase key in $SECRETS"
    out=$(STOCKPULSE_FCM_TOPIC=stockpulse-test dc --profile job run --rm --no-deps -e STOCKPULSE_DATA_DIR=/tmp -e STOCKPULSE_REPORT_DIR=/tmp job \
      python -c 'from push_notify import send_push; send_push("StockPulse test", "dsserver push path test (no device subscribes to this topic)", "/latest/us")' 2>&1)
    echo "$out" | sed 's/Bearer [^ ]*/Bearer <redacted>/g' | tail -n 3
    grep -q "sent 'StockPulse test' (/latest/us) to topic stockpulse-test" <<<"$out" && echo "15 PUSH-TEST PASSED" || fail "push not sent" ;;

  job:2)
    need_image; s=$(script_for "$2"); [ -s "$APP/data/history.db" ] || fail "nothing imported yet"
    echo "--- PRODUCTION run $2 ($s), firebase key $([ -s "$SECRETS/firebase-service-account.json" ] && echo present || echo 'absent: no push'), started $(date '+%F %T')"
    jobrun docker compose -f "$STACK/compose.yaml" --profile job run --rm --no-deps job python "$s"
    echo "--- finished $(date '+%F %T')" ;;

  backup:1)
    need_image; [ -s "$APP/data/history.db" ] || fail "nothing imported yet"
    locked docker compose -f "$STACK/compose.yaml" --profile job run --rm --no-deps job python -c '
import datetime, glob, os, sqlite3, sys
os.makedirs("/data/backups", mode=0o700, exist_ok=True)
dst = "/data/backups/history-%s.db" % datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
src = sqlite3.connect("file:/data/history.db?mode=ro", uri=True); d = sqlite3.connect(dst + ".tmp")
src.backup(d); r = d.execute("pragma integrity_check").fetchone()[0]; n = d.execute("select count(*) from runs").fetchone()[0]; d.close()
if r != "ok": os.remove(dst + ".tmp"); sys.exit("backup integrity check failed: " + r)
os.replace(dst + ".tmp", dst)
old = sorted(glob.glob("/data/backups/history-*.db"))[:-14]
for f in old: os.remove(f)
print("backup", os.path.basename(dst), "integrity ok,", n, "runs;", len(old), "old removed")' ;;

  check:1)
    rc=0
    python3 -I "$STACK/check.py" --data "$APP/data" --reports "$APP/reports" --state "$STATE" --uid "$UID_" || rc=1
    h=$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}' stockpulse-web 2>/dev/null || echo absent)
    if [ "$h" = "running healthy" ]; then ok "web container running, healthy"; else echo "FAIL  web container: $h"; rc=1; fi
    exit $rc ;;
  check-now:1)
    systemctl start stockpulse-check.service || true
    echo "stockpulse-check.service: $(systemctl show -p Result,ActiveState --value stockpulse-check.service | tr '\n' ' ')" ;;
  test-recovery:1)
    w=stockpulse-web; get() { curl -s --resolve "$NAME:443:127.0.0.1" "https://$NAME$1" | sha256sum | cut -c1-16; }
    h0=$(get /latest/us); c0=$(docker inspect -f '{{.RestartCount}}' $w); pid=$(docker inspect -f '{{.State.Pid}}' $w)
    echo "--- SIGKILL web pid $pid at $(date +%T) (a crash; 'docker stop' would count as a manual stop)"
    kill -KILL "$pid"
    for _ in $(seq 60); do [ "$(docker inspect -f '{{.RestartCount}} {{.State.Health.Status}}' $w)" = "$((c0+1)) healthy" ] && break; sleep 1; done
    [ "$(docker inspect -f '{{.RestartCount}} {{.State.Health.Status}}' $w)" = "$((c0+1)) healthy" ] && ok "web restarted by Docker and healthy at $(date +%T)" || bad "web not back"
    [ "$(get /latest/us)" = "$h0" ] && ok "same report served after the crash (sha256 $h0)" || bad "report differs after restart"
    [ "$FAILS" = 0 ] && echo "15 TEST-RECOVERY PASSED" || fail "$FAILS check(s) failed" ;;
  check-test-fail:1)  install -d -m 0755 "$STATE"; touch "$STATE/fail-test"; ok "deliberate check failure ON (next check run fails)" ;;
  check-test-clear:1) rm -f "$STATE/fail-test"; ok "deliberate check failure OFF" ;;
  check-enable:1)
    for u in stockpulse-check.service stockpulse-check.timer; do install -m 0644 "$STACK/systemd/$u" "/etc/systemd/system/$u"; done
    systemctl daemon-reload; systemctl enable --now stockpulse-check.timer >/dev/null 2>&1
    systemctl is-enabled stockpulse-check.timer ;;
  units-install:1)
    for u in $UNITS; do install -m 0644 "$STACK/systemd/$u" "/etc/systemd/system/$u"; done
    systemctl daemon-reload
    ok "units installed (none enabled): $UNITS" ;;
  backup-enable:1)
    systemctl enable --now stockpulse-backup.timer >/dev/null 2>&1; install -d -m 0755 "$STATE"; touch "$STATE/backup-enabled"
    systemctl is-enabled stockpulse-backup.timer ;;
  timers-enable:1)
    for t in us intl ath; do systemctl enable --now "stockpulse-$t.timer" >/dev/null 2>&1; done
    install -d -m 0755 "$STATE"; touch "$STATE/timers-enabled-at"   # report freshness is checked from now on
    systemctl list-timers 'stockpulse-*' --no-pager | head -n 7 ;;
  timers-disable:1)
    for t in us intl ath; do systemctl disable --now "stockpulse-$t.timer" >/dev/null 2>&1 || true; done
    rm -f "$STATE/timers-enabled-at"; ok "screener timers disabled (freshness no longer checked)" ;;
  down:1) dc down 2>&1 | tail -n 2 ;;
  *) echo "usage: sudo $0 preflight|build|import|up|verify|status|test-reset|run-test us|intl|ath|push-test|job us|intl|ath|backup|test-recovery|check|check-now|check-test-fail|check-test-clear|check-enable|units-install|backup-enable|timers-enable|timers-disable|down" >&2; exit 2 ;;
esac
