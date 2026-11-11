#!/bin/bash
# dsserver: Beszel agent + filtering Docker socket proxy (roadmap O1/O2). Record: beacon/README.md.
# Thin wrapper around beacon/agent/install-agent.sh with FIXED arguments, so it can be delegated
# (host/scripts/09-delegated-sudo.sh) without letting the caller choose files or options.
#
#   preflight      read-only: env file, docker, current state
#   install        install/update agent + proxy (install-agent.sh <env> --with-docker-proxy).
#                  Env source: /home/daniel/.beszel-agent-dsserver.env if present (first install),
#                  else the installed /etc/beszel-agent/env (updates). Touches no other container.
#   verify         read-only checks: unit, user groups, boot persistence, proxy allowlist as user beszel
#   status         short read-only summary
#   test-recovery  SIGKILL the agent's main process and the proxy's process (simulated crashes);
#                  waits for systemd / Docker to restart them, then re-runs the allowlist check.
#                  Only beszel-agent.service and the container beszel-socket-proxy are touched.
#   log-scan       read-only: every container's full log searched for credential-like text (gate for the
#                  proxy's logs permission). Prints per-container counts and matching lines with every
#                  long token replaced by <REDACTED>; exit 1 if anything matched (review it by hand).
# Not delegated on purpose: removal (do it by hand, see beacon/README.md).
set -euo pipefail
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
ROOT=$(readlink -f -- "$HERE/../..")
INSTALLER=$ROOT/beacon/agent/install-agent.sh
FIRST_ENV=/home/daniel/.beszel-agent-dsserver.env
ETC_ENV=/etc/beszel-agent/env
SOCK=/run/beszel-docker/docker.sock
CT=beszel-socket-proxy
UNIT=beszel-agent.service

ok()   { echo "ok    $*"; }
bad()  { echo "FAIL  $*"; FAILS=$((FAILS+1)); }
fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
FAILS=0
[ "$(id -u)" = 0 ] || fail "run as root"
[ "$(hostname)" = dsserver ] || fail "not dsserver"

env_source() {
    if [ -e "$FIRST_ENV" ]; then
        [ ! -L "$FIRST_ENV" ] || fail "$FIRST_ENV is a symlink; refusing"
        [ "$(stat -c '%U %a' "$FIRST_ENV")" = "daniel 600" ] || fail "$FIRST_ENV must be owned by daniel, mode 600"
        echo "$FIRST_ENV"
    elif [ -s "$ETC_ENV" ]; then echo "$ETC_ENV"
    else fail "no env file ($FIRST_ENV or $ETC_ENV)"; fi
}

# HTTP status of a request through the proxy, made as the agent's user. Never prints bodies.
code() { runuser -u beszel -- curl -s -o /dev/null -w '%{http_code}' -m 5 --unix-socket "$SOCK" -X "$1" "http://docker$2" 2>/dev/null || true; }

allowlist() {
    local id; id=$(docker ps -q --no-trunc | head -n1 || true)
    [ -n "$id" ] || { bad "no running container to test with"; return; }
    local m p want got
    while read -r m p want; do
        got=$(code "$m" "$p")
        [ "$got" = "$want" ] && ok "proxy $m ${p/$id/<id>} -> $got" || bad "proxy $m ${p/$id/<id>} -> $got (want $want)"
    done <<EOF
GET /version 200
GET /info 200
GET /containers/json 200
GET /containers/$id/stats?stream=0 200
GET /containers/$id/logs?stdout=1&tail=1 200
GET /containers/$id/json 403
GET /containers/$id/top 403
GET /containers/$id/archive?path=/ 403
GET /containers/$id/export 403
GET /images/json 403
GET /events 403
POST /containers/$id/stop 405
DELETE /containers/$id 405
EOF
    if runuser -u nobody -- test -x /run/beszel-docker 2>/dev/null; then bad "user nobody can enter /run/beszel-docker"; else ok "user nobody cannot reach the proxy socket"; fi
}

preflight() {
    echo "env source: $(env_source)"
    for k in HUB_URL TOKEN KEY; do grep -q "^$k=." "$(env_source)" || fail "env lacks $k"; done
    ok "env has HUB_URL, TOKEN, KEY (values not shown)"
    systemctl is-active --quiet docker && ok "docker active" || fail "docker not active"
    [ -x "$INSTALLER" ] || [ -f "$INSTALLER" ] || fail "missing $INSTALLER"
    echo "agent unit: $(systemctl is-active $UNIT 2>/dev/null || true) / $(systemctl is-enabled $UNIT 2>/dev/null || true)"
    echo "proxy: $(docker inspect -f '{{.State.Status}}' $CT 2>/dev/null || echo absent)"
    echo "containers running: $(docker ps -q | wc -l)"
}

install_() {
    local src; src=$(env_source)
    local before; before=$(docker ps --format '{{.Names}} {{.ID}} {{.Status}}' | grep -v "^$CT " | sort || true)
    bash "$INSTALLER" "$src" --with-docker-proxy
    local after; after=$(docker ps --format '{{.Names}} {{.ID}} {{.Status}}' | grep -v "^$CT " | sort || true)
    # Status text changes with uptime ("Up 3 hours"), so compare names + ids only.
    [ "$(cut -d' ' -f1,2 <<<"$before")" = "$(cut -d' ' -f1,2 <<<"$after")" ] && ok "other containers unchanged ($(grep -c . <<<"$after" || true))" || bad "other containers changed"
    [ "$FAILS" = 0 ] || fail "$FAILS check(s) failed"
    echo "13 INSTALL DONE"
}

verify() {
    systemctl is-active --quiet $UNIT && ok "$UNIT active" || bad "$UNIT not active"
    [ "$(systemctl is-enabled $UNIT 2>/dev/null)" = enabled ] && ok "$UNIT enabled (multi-user.target)" || bad "$UNIT not enabled"
    systemctl is-enabled --quiet docker && ok "docker.service enabled" || bad "docker.service not enabled"
    [ "$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' $CT 2>/dev/null)" = unless-stopped ] && ok "$CT restart policy unless-stopped" || bad "$CT restart policy"
    [ "$(docker inspect -f '{{.State.Running}}' $CT 2>/dev/null)" = true ] && ok "$CT running" || bad "$CT not running"
    grep -qx 'd /run/beszel-docker 0750 64001 beszel -' /etc/tmpfiles.d/beszel-docker.conf && ok "tmpfiles recreates /run/beszel-docker at boot" || bad "tmpfiles entry"
    [ "$(stat -c '%u:%G %a' /run/beszel-docker)" = "64001:beszel 750" ] && ok "/run/beszel-docker 64001:beszel 0750" || bad "/run/beszel-docker is $(stat -c '%u:%G %a' /run/beszel-docker)"
    local g; g=$(id -nG beszel)
    for x in docker disk sudo adm; do [[ " $g " == *" $x "* ]] && bad "beszel in group $x"; done
    ok "beszel groups: $g"
    [ "$(stat -c '%U %a' $ETC_ENV)" = "root 600" ] && ok "$ETC_ENV root 0600" || bad "$ETC_ENV perms"
    local l; l=$(ss -tulpnH | grep -c beszel-agent || true)
    [ "$l" = 0 ] && ok "agent has no listening sockets" || bad "agent listens on $l socket(s)"
    local pid; pid=$(systemctl show -p MainPID --value $UNIT)
    [ "$pid" != 0 ] && [ "$(stat -c %U /proc/$pid)" = beszel ] && ok "agent runs as beszel (pid $pid)" || bad "agent user"
    ss -tnpH state established | grep -q ':8090 .*beszel-agent' && ok "agent connected to hub :8090" || bad "no hub connection"
    allowlist
    [ "$FAILS" = 0 ] && echo "13 VERIFY PASSED" || fail "$FAILS check(s) failed"
}

status() {
    echo "agent: $(systemctl is-active $UNIT) / $(systemctl is-enabled $UNIT 2>/dev/null || true), $(/usr/local/bin/beszel-agent -v 2>&1 | head -1)"
    echo "proxy: $(docker inspect -f '{{.State.Status}} restarts={{.RestartCount}} started={{.State.StartedAt}}' $CT 2>/dev/null || echo absent)"
    journalctl -u $UNIT -n 5 --no-pager -o short-iso | cut -c1-200
}

wait_for() {   # wait_for <seconds> <command...>
    local n=$1; shift
    for _ in $(seq 1 "$n"); do "$@" && return 0; sleep 1; done; return 1
}

test_recovery() {
    systemctl is-active --quiet $UNIT || fail "$UNIT not active before the test"
    local p0; p0=$(systemctl show -p MainPID --value $UNIT)
    echo "--- agent: SIGKILL main pid $p0 at $(date +%T)"
    systemctl kill -s SIGKILL --kill-whom=main $UNIT
    if wait_for 40 sh -c "[ \"\$(systemctl show -p MainPID --value $UNIT)\" != 0 ] && [ \"\$(systemctl show -p MainPID --value $UNIT)\" != $p0 ] && systemctl is-active --quiet $UNIT"; then
        ok "agent restarted by systemd at $(date +%T), new pid $(systemctl show -p MainPID --value $UNIT)"
    else bad "agent did not restart within 40 s"; fi
    wait_for 30 sh -c "ss -tnpH state established | grep -q ':8090 .*beszel-agent'" && ok "agent reconnected to hub" || bad "agent not reconnected"

    local c0 pid; c0=$(docker inspect -f '{{.RestartCount}}' $CT); pid=$(docker inspect -f '{{.State.Pid}}' $CT)
    [ "$pid" -gt 1 ] || fail "$CT has no pid"
    echo "--- proxy: SIGKILL pid $pid at $(date +%T) (a crash; 'docker stop/kill' would count as a manual stop)"
    kill -KILL "$pid"
    if wait_for 30 sh -c "[ \"\$(docker inspect -f '{{.RestartCount}}' $CT)\" -gt $c0 ] && [ \"\$(docker inspect -f '{{.State.Running}}' $CT)\" = true ] && [ -S $SOCK ]"; then
        ok "proxy restarted by Docker at $(date +%T) (restarts $c0 -> $(docker inspect -f '{{.RestartCount}}' $CT))"
    else bad "proxy did not restart within 30 s"; fi
    wait_for 15 sh -c "[ \"\$(runuser -u beszel -- curl -s -o /dev/null -w '%{http_code}' -m 5 --unix-socket $SOCK http://docker/version)\" = 200 ]" && ok "proxy answers again" || bad "proxy not answering"
    allowlist
    [ "$FAILS" = 0 ] && echo "13 TEST-RECOVERY PASSED" || fail "$FAILS check(s) failed"
}

log_scan() {
    local re='token|secret|passw|apikey|api_key|authorization|bearer|BEGIN [A-Z ]*PRIVATE|cf_api|ntfy\.sh/|hc-ping|credential|session=|cookie'
    local c n m hits=0
    for c in $(docker ps -a --format '{{.Names}}'); do
        n=$(docker logs "$c" 2>&1 | wc -l)
        m=$(docker logs "$c" 2>&1 | grep -c -i -E "$re" || true)
        echo "$c: $n lines, $m matching"
        if [ "$m" -gt 0 ]; then
            hits=$((hits+m))
            docker logs "$c" 2>&1 | grep -i -E "$re" | sed -E 's/[A-Za-z0-9_+\/=.-]{16,}/<REDACTED>/g' | cut -c1-200 | sort | uniq -c | sort -rn | head -n 10 | sed 's/^/    /' || true
        fi
    done
    [ "$hits" = 0 ] && echo "13 LOG-SCAN CLEAN" || { echo "13 LOG-SCAN: $hits matching line(s) - review above before allowing logs"; exit 1; }
}

case "${1:-}:$#" in
    preflight:1) preflight ;;
    log-scan:1) log_scan ;;
    install:1) install_ ;;
    verify:1) verify ;;
    status:1) status ;;
    test-recovery:1) test_recovery ;;
    *) echo "usage: sudo $0 preflight|install|verify|status|test-recovery|log-scan" >&2; exit 2 ;;
esac
