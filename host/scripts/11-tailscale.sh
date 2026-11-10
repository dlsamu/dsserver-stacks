#!/bin/bash
# dsserver M1 (handover numbering): Tailscale client so dsserver can reach kjells-computer on its own.
# Record: host/docs/host-config.md §13.
#
# Approved settings (2026-11-10): official repository pkgs.tailscale.com/stable/debian (trixie),
# --hostname=dsserver, --accept-dns=false, no Tailscale SSH, no exit node, no subnet routes,
# no incoming firewall change (vpn_ifaces stays empty, so new connections arriving on tailscale0
# are still dropped by dsserver_fw). --shields-up additionally refuses incoming tailnet
# connections inside tailscaled itself.
#
# Usage (as root, in Konsole; each step stops at the first failed check):
#   preflight   read-only: OS/arch, no Tailscale yet, firewall active, DNS/route state
#   install     record a baseline, add the signed repository, install the package, start tailscaled.
#               Does NOT log in or join any tailnet.
#   up          join the tailnet with the approved flags. Prints a login URL: open it and sign in
#               with the account that owns tail96c1da.ts.net. The URL is not written to the log.
#   verify      read-only: package origin, prefs, tailnet, DNS untouched, routes, firewall, sockets
#   status      read-only summary
#   rollback    (manual) log out, purge the package, remove only the files this script created
#
# Log: /var/log/dsserver-tailscale.log (root:daniel 0640, no secrets). Baseline: /var/lib/dsserver-tailscale/.
# Writes nothing inside the repository.
set -euo pipefail

EXPECTED_FPR=2596A99EAAB33821893C0A79458CA832957F5868   # Tailscale Inc. (Package repository signing key)
TS_URL=https://pkgs.tailscale.com/stable/debian
TS_ORIGIN="$TS_URL trixie/main"
KEYRING=/usr/share/keyrings/tailscale-archive-keyring.gpg
SOURCES=/etc/apt/sources.list.d/tailscale.sources
SOURCES_CONTENT='Types: deb
URIs: https://pkgs.tailscale.com/stable/debian
Suites: trixie
Components: main
Architectures: amd64
Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg'
EXPECTED_TAILNET=tail96c1da.ts.net
TS_HOSTNAME=dsserver
UP_FLAGS=(--hostname="$TS_HOSTNAME" --accept-dns=false --accept-routes=false --ssh=false
          --shields-up --advertise-exit-node=false --exit-node= --advertise-routes= --timeout=15m)
BASE=/var/lib/dsserver-tailscale
LOG=/var/log/dsserver-tailscale.log
FW_TABLE="inet dsserver_fw"
TS_V4=100.64.0.0/10
TS_V6=fd7a:115c:a1e0::/48

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }
info() { echo "info  $*"; }
warn() { echo "WARN  $*"; }

# ---------- pure helpers (tested by host/tests/test-tailscale-script.sh) ----------

# key_ok <file>: exactly one primary key whose fingerprint is EXPECTED_FPR.
key_ok() {
    local gh out npub fpr
    gh=$(mktemp -d)
    out=$(GNUPGHOME=$gh gpg --show-keys --with-colons "$1" 2>/dev/null) || { rm -rf "$gh"; return 1; }
    rm -rf "$gh"
    npub=$(awk -F: '$1=="pub"{n++} END{print n+0}' <<<"$out")
    fpr=$(awk -F: '$1=="fpr" && !seen {print $10; seen=1}' <<<"$out")
    echo "keys in file: $npub, primary fingerprint: ${fpr:-none}"
    [ "$npub" = 1 ] && [ "$fpr" = "$EXPECTED_FPR" ]
}

# prefs_problems: reads `tailscale debug prefs` JSON on stdin, prints one line per deviation.
prefs_problems() {
    jq -r --arg h "$TS_HOSTNAME" '
        [ (if .WantRunning != true          then "WantRunning is not true" else empty end),
          (if .Hostname != $h               then "Hostname is \(.Hostname|tojson), expected \($h)" else empty end),
          (if .CorpDNS != false             then "CorpDNS (accept-dns) is not false" else empty end),
          (if .RouteAll != false            then "RouteAll (accept-routes) is not false" else empty end),
          (if .RunSSH != false              then "RunSSH (Tailscale SSH) is not false" else empty end),
          (if .ShieldsUp != true            then "ShieldsUp is not true" else empty end),
          (if (.ExitNodeID // "") != ""     then "an exit node is set" else empty end),
          (if (.ExitNodeIP // "") != ""     then "an exit node IP is set" else empty end),
          (if ((.AdvertiseRoutes // []) | length) != 0 then "routes are advertised: \(.AdvertiseRoutes|tojson)" else empty end),
          (if ((.AdvertiseServices // []) | length) != 0 then "services are advertised" else empty end)
        ] | .[]'
}

# routes_outside_tailnet: reads `ip -j route show table N` JSON on stdin and prints every route whose
# destination is not inside the Tailscale ranges (e.g. a default route or a LAN prefix).
routes_outside_tailnet() {
    python3 -I -c '
import ipaddress, json, sys
nets = [ipaddress.ip_network(n) for n in sys.argv[1:]]
for r in json.load(sys.stdin):
    d = r.get("dst", "")
    if d in ("default", ""):
        print(d or "(no dst)"); continue
    try:
        n = ipaddress.ip_network(d if "/" in d else d + ("/128" if ":" in d else "/32"), strict=False)
    except ValueError:
        print(d); continue
    if not any(n.version == t.version and n.subnet_of(t) for t in nets):
        print(d)
' "$TS_V4" "$TS_V6" "100.100.100.100/32"
}

# resolv_touched: true if a resolv.conf (stdin) points at Tailscale's resolver or names it.
resolv_touched() { grep -qiE '100\.100\.100\.100|tailscale|ts\.net' ; }

# new_sockets <before> <after>: lines in after that are not in before (both sorted, `ss -tulnpH` reduced).
new_sockets() { comm -13 "$1" "$2"; }

# sockets_not_tailscaled: reads socket lines, prints those not owned by tailscaled.
sockets_not_tailscaled() { grep -v '"tailscaled"' || true; }

# ---------- system state ----------
# Protocol, local address and owning process names (pid/fd stripped so restarts don't count as new).
listen() { ss -tulnpH | awk '{p=$7; gsub(/,pid=[0-9]+,fd=[0-9]+/, "", p); print $1, $5, p}' | sort -u; }
pkg_status() { dpkg-query -W -f='${db:Status-Abbrev}' "$1" 2>/dev/null || true; }
policy_field() { local pol; pol=$(apt-cache policy "$1"); awk -v f="$2:" '$1==f {print $2}' <<<"$pol"; }
version_origins() {   # same parser as 03-docker-install.sh
    local pol
    pol=$(apt-cache policy "$1")
    awk -v v="$2" '
        $1=="***"                                       { cur=$2; next }
        NF==2 && $2 ~ /^-?[0-9]+$/ && $1 !~ /^-?[0-9]+$/ { cur=$1; next }
        $1 ~ /^-?[0-9]+$/ && cur==v && $2 != "/var/lib/dpkg/status" { print $2, $3 }
    ' <<<"$pol"
}
check_origin() {
    local origins bad
    origins=$(version_origins tailscale "$1")
    [ -n "$origins" ] || fail "tailscale $1: no repository offers this version"
    bad=$(grep -vxF "$TS_ORIGIN" <<<"$origins" || true)
    [ -z "$bad" ] || fail "tailscale $1: also offered by an unexpected origin: $bad"
    ok "tailscale $1 <- $TS_ORIGIN"
}
fw_hash() { nft list table $FW_TABLE 2>/dev/null | sha256sum | cut -d' ' -f1; }

start_log() {
    touch "$LOG"; chown root:daniel "$LOG"; chmod 0640 "$LOG"
    exec > >(tee -a "$LOG") 2>&1
    echo; echo "##### $CMD started $(date -Is) on $(hostname)"
}

do_preflight() {
    step "preflight (read-only)"
    . /etc/os-release
    [ "$VERSION_CODENAME" = trixie ] || fail "not Debian trixie: $VERSION_CODENAME"
    [ "$(dpkg --print-architecture)" = amd64 ] || fail "architecture is not amd64"
    ok "Debian $VERSION_ID ($VERSION_CODENAME) amd64"
    [ "$(systemctl is-active dsserver-firewall.service)" = active ] || fail "dsserver-firewall.service not active"
    nft list table $FW_TABLE >/dev/null 2>&1 || fail "table $FW_TABLE not loaded"
    local vpn; vpn=$(nft -j list set $FW_TABLE vpn_ifaces | jq -r '[.nftables[].set? | select(.) | .elem // [] ] | add | length')
    [ "$vpn" = 0 ] || fail "vpn_ifaces is not empty ($vpn elements)"
    ok "firewall active, vpn_ifaces empty (tailscale0 will get no incoming access)"
    [ "$(systemctl is-enabled nftables 2>/dev/null || true)" = disabled ] || fail "nftables.service is not disabled"
    local st; st=$(pkg_status tailscale)
    if [[ $st == ii* ]]; then info "tailscale is already installed ($st)"; else ok "tailscale not installed"; fi
    for f in /etc/apt/sources.list.d/*; do
        [ "$f" = "$SOURCES" ] && continue
        if grep -qs 'pkgs.tailscale.com' "$f"; then fail "another source file already points at Tailscale: $f"; fi
    done
    ok "no other Tailscale source files"
    if resolv_touched </etc/resolv.conf; then fail "/etc/resolv.conf already mentions Tailscale"; fi
    ok "/etc/resolv.conf: $(head -1 /etc/resolv.conf)"
    command -v jq >/dev/null && command -v gpg >/dev/null && command -v curl >/dev/null || fail "jq, gpg and curl are needed"
    ok "preflight passed"
}

do_install() {
    do_preflight
    step "1. Baseline (before any change)"
    install -d -m 0700 "$BASE"
    if [ -s "$BASE/listen-before.txt" ]; then
        info "keeping the existing baseline from $(stat -c %y "$BASE/listen-before.txt")"
    else
        if [ "$(systemctl is-active tailscaled 2>/dev/null || true)" = active ]; then fail "tailscaled already running and no baseline exists"; fi
        listen > "$BASE/listen-before.txt"
        sha256sum /etc/resolv.conf | cut -d' ' -f1 > "$BASE/resolv.sha256"
        fw_hash > "$BASE/fw.sha256"
        ip -j route show table main > "$BASE/route-main.json"
        ip rule show > "$BASE/ip-rule.txt"
        cat /proc/sys/net/ipv4/ip_forward > "$BASE/ip_forward"
        ok "baseline written to $BASE"
    fi

    step "2. Signing key"
    if [ -e "$KEYRING" ]; then
        key_ok "$KEYRING" || fail "existing $KEYRING does not verify; not touching it"
        ok "kept existing $KEYRING"
    else
        local tmp; tmp=$(mktemp)
        curl -fsSL "$TS_URL/trixie.noarmor.gpg" -o "$tmp"
        if ! key_ok "$tmp"; then rm -f "$tmp"; fail "downloaded key fingerprint mismatch (discarded, never installed)"; fi
        install -m 0644 -o root -g root "$tmp" "$KEYRING"; rm -f "$tmp"
        ok "installed $KEYRING"
    fi

    step "3. Repository definition"
    if [ -e "$SOURCES" ]; then
        [ "$(cat "$SOURCES")" = "$SOURCES_CONTENT" ] || fail "$SOURCES exists with different content; not overwriting"
        ok "kept existing $SOURCES (identical)"
    else
        printf '%s\n' "$SOURCES_CONTENT" > "$SOURCES"; chmod 0644 "$SOURCES"
        ok "created $SOURCES"
    fi

    step "4. apt update and candidate origin"
    apt-get update
    local c; c=$(policy_field tailscale Candidate)
    [ -n "$c" ] && [ "$c" != "(none)" ] || fail "tailscale: no install candidate"
    check_origin "$c"

    step "5. Install"
    DEBIAN_FRONTEND=noninteractive apt-get install -y tailscale
    [[ $(pkg_status tailscale) == ii* ]] || fail "tailscale not properly installed"
    check_origin "$(policy_field tailscale Installed)"
    [ "$(systemctl is-enabled tailscaled)" = enabled ] || fail "tailscaled not enabled"
    [ "$(systemctl is-active tailscaled)" = active ] || fail "tailscaled not active"
    ok "tailscaled enabled and active ($(tailscale version | head -1))"
    local bs; bs=$(tailscale status --json | jq -r .BackendState)
    info "backend state: $bs (NeedsLogin is expected: not joined yet)"
    echo; echo "INSTALL PASSED $(date -Is). Next: sudo bash $0 up"
}

do_up() {
    [[ $(pkg_status tailscale) == ii* ]] || fail "run 'install' first"
    step "up: joining the tailnet with: tailscale up ${UP_FLAGS[*]}"
    echo "A login URL follows. Open it in a browser and sign in with the account that owns $EXPECTED_TAILNET."
    echo "(The URL is shown only on this terminal, not in the log.)"
    tailscale up "${UP_FLAGS[@]}" </dev/tty >/dev/tty 2>&1 || fail "tailscale up failed or timed out"
    ok "tailscale up returned"
    do_verify
}

do_verify() {
    local problems=0 p
    step "verify: package and service"
    [ -s "$BASE/listen-before.txt" ] || fail "no baseline in $BASE (run 'install' first)"
    [[ $(pkg_status tailscale) == ii* ]] || fail "tailscale not installed"
    check_origin "$(policy_field tailscale Installed)"
    [ "$(cat "$SOURCES")" = "$SOURCES_CONTENT" ] || fail "$SOURCES content changed"
    key_ok "$KEYRING" >/dev/null || fail "$KEYRING does not verify"
    [ "$(systemctl is-active tailscaled)" = active ] || fail "tailscaled not active"
    ok "package, repository, key, service"

    step "verify: tailnet and settings"
    local js; js=$(tailscale status --json)
    [ "$(jq -r .BackendState <<<"$js")" = Running ] || fail "backend state is $(jq -r .BackendState <<<"$js") (not joined?)"
    local suffix; suffix=$(jq -r .MagicDNSSuffix <<<"$js")
    [ "$suffix" = "$EXPECTED_TAILNET" ] || fail "joined tailnet '$suffix', expected $EXPECTED_TAILNET"
    local dns; dns=$(jq -r .Self.DNSName <<<"$js")
    [ "$dns" = "$TS_HOSTNAME.$EXPECTED_TAILNET." ] || fail "this node is '$dns', expected $TS_HOSTNAME.$EXPECTED_TAILNET. (name taken? rename the old node in the admin console)"
    ok "node $dns, addresses $(jq -r '.Self.TailscaleIPs | join(" ")' <<<"$js")"
    p=$(tailscale debug prefs | prefs_problems)
    if [ -n "$p" ]; then echo "$p" | sed 's/^/FAIL  /'; fail "settings differ from the approved ones"; fi
    ok "prefs: hostname dsserver, accept-dns off, accept-routes off, Tailscale SSH off, shields up, no exit node, no advertised routes"
    local exp; exp=$(jq -r '.Self.KeyExpiry // empty' <<<"$js")
    if [ -n "$exp" ]; then warn "node key expires $exp: disable key expiry for dsserver in the Tailscale admin console"; problems=1
    else ok "key expiry disabled"; fi
    local peer; peer=$(jq -r '.Peer[] | select(.HostName=="kjells-computer" or (.DNSName|startswith("kjells-computer."))) | "\(.DNSName) \(.TailscaleIPs[0]) online=\(.Online)"' <<<"$js")
    if [ -n "$peer" ]; then ok "peer visible: $peer"; else warn "kjells-computer not visible in the tailnet"; problems=1; fi

    step "verify: host DNS, routing, firewall unchanged"
    if resolv_touched </etc/resolv.conf; then fail "/etc/resolv.conf now mentions Tailscale"; fi
    if [ "$(sha256sum /etc/resolv.conf | cut -d' ' -f1)" = "$(cat "$BASE/resolv.sha256")" ]; then ok "/etc/resolv.conf unchanged"
    else info "/etc/resolv.conf changed but has no Tailscale entries (NetworkManager rewrites it on DHCP renewal)"; fi
    p=$(ip -j route show table main | routes_outside_tailnet | sort)
    local pb; pb=$(routes_outside_tailnet <"$BASE/route-main.json" | sort)
    [ "$p" = "$pb" ] || fail "main routing table changed outside the tailnet ranges: before [$pb] now [$p]"
    ok "main routing table: no new non-tailnet routes"
    p=$(ip -j route show table 52 2>/dev/null | routes_outside_tailnet || true)
    [ -z "$p" ] || fail "Tailscale table 52 has routes outside the tailnet: $p"
    ok "table 52 holds tailnet routes only (no default route, no LAN prefixes)"
    [ "$(cat /proc/sys/net/ipv4/ip_forward)" = "$(cat "$BASE/ip_forward")" ] || fail "ip_forward changed"
    [ "$(systemctl is-active dsserver-firewall.service)" = active ] || fail "dsserver-firewall.service not active"
    [ "$(fw_hash)" = "$(cat "$BASE/fw.sha256")" ] || fail "table $FW_TABLE changed"
    ok "dsserver_fw table identical to the baseline; vpn_ifaces still empty"

    step "verify: listening sockets"
    local now; now=$(mktemp); listen >"$now"
    local added; added=$(new_sockets "$BASE/listen-before.txt" "$now"); rm -f "$now"
    [ -n "$added" ] && echo "$added" | sed 's/^/info  new socket: /'
    p=$(sockets_not_tailscaled <<<"$added")
    if [ -n "$p" ]; then warn "new listening sockets not owned by tailscaled (other services may have restarted on new ports): $p"; problems=1
    else ok "only tailscaled added sockets (UDP 41641 and its peer API); new incoming connections on eno1 and tailscale0 are still dropped by dsserver_fw"; fi

    echo
    if [ "$problems" = 0 ]; then echo "VERIFY PASSED $(date -Is)"; else echo "VERIFY PASSED WITH WARNINGS $(date -Is) (see WARN lines)"; fi
}

do_status() {
    systemctl is-active tailscaled 2>/dev/null || true
    tailscale status 2>&1 || true
    tailscale debug prefs 2>/dev/null | jq -c '{Hostname,WantRunning,CorpDNS,RouteAll,RunSSH,ShieldsUp,ExitNodeID,AdvertiseRoutes}' || true
}

do_rollback() {
    step "rollback"
    if command -v tailscale >/dev/null; then tailscale logout || true; fi
    if [[ $(pkg_status tailscale) == ii* || $(pkg_status tailscale) == rc* ]]; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y tailscale
    fi
    if [ -e "$SOURCES" ]; then
        if [ "$(cat "$SOURCES")" = "$SOURCES_CONTENT" ]; then rm -f "$SOURCES"; ok "removed $SOURCES"
        else warn "$SOURCES differs from ours; left in place"; fi
    fi
    if [ -e "$KEYRING" ] && key_ok "$KEYRING" >/dev/null; then rm -f "$KEYRING"; ok "removed $KEYRING"; fi
    rm -rf "$BASE"; ok "removed $BASE"
    apt-get update -qq || true
    if [ -d /var/lib/tailscale ]; then info "/var/lib/tailscale was left in place (created by the package, not by this script)"; fi
    echo "Also remove the dsserver machine in the Tailscale admin console."
}

main() {
    CMD=${1:-}; [ $# -eq 1 ] || CMD=""
    case $CMD in preflight|install|up|verify|status|rollback) ;; *)
        echo "usage: sudo bash $0 preflight|install|up|verify|status|rollback"; exit 2 ;; esac
    [ "$(id -u)" = 0 ] || fail "run with sudo"
    [ "$CMD" = status ] || start_log
    "do_$CMD"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
