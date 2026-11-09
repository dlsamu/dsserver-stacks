#!/bin/bash
# dsserver: install Docker Engine + Compose from Docker's official Debian 13 repo (approved plan).
# Run as: sudo bash docker-install.sh
# Resumable: existing config files are verified and kept, never overwritten.
# Stops at the first failed validation. Does NOT touch firewall rules, SSH, or deploy services.
#
# Rev 2 (2026-11-09): validation fixes. No check pipes a producer into head/grep -q/awk-exit,
# because under `pipefail` an early-exiting reader makes the producer die of SIGPIPE (141),
# which caused a false failure in rev 1 and could also have silently skipped `&& fail` checks.
# Command output is captured into variables first and then matched.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LOG="$HERE/docker-install.log"
touch "$LOG"; chmod 0644 "$LOG"
exec > >(tee -a "$LOG") 2>&1

EXPECTED_FPR=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
DOCKER_ORIGIN='https://download.docker.com/linux/debian trixie/stable'
PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
KEY=/etc/apt/keyrings/docker.asc
SOURCES=/etc/apt/sources.list.d/docker.sources
DAEMON=/etc/docker/daemon.json

SOURCES_CONTENT='Types: deb
URIs: https://download.docker.com/linux/debian
Suites: trixie
Components: stable
Architectures: amd64
Signed-By: /etc/apt/keyrings/docker.asc'

DAEMON_CONTENT='{
  "firewall-backend": "iptables",
  "log-driver": "local"
}'

fail() { echo; echo "VALIDATION FAILED: $*"; echo "Stopped. Nothing further was changed."; exit 1; }
step() { echo; echo "=== $*"; }
listen() { ss -tulnH | awk '{print $1, $5}' | sort -u; }

# Verify a key file: exactly one primary key, primary fingerprint must match. Prints the fingerprint.
key_fpr() {
    local gh out npub fpr
    gh=$(mktemp -d)                     # throwaway GnuPG home; root's keyring untouched
    out=$(GNUPGHOME=$gh gpg --show-keys --with-colons "$1" 2>/dev/null) || { rm -rf "$gh"; return 1; }
    rm -rf "$gh"
    npub=$(awk -F: '$1=="pub"{n++} END{print n+0}' <<<"$out")
    fpr=$(awk -F: '$1=="fpr" && !seen {print $10; seen=1}' <<<"$out")   # first fpr = primary key
    echo "keys in file: $npub, primary fingerprint: $fpr"
    [ "$npub" = 1 ] && [ "$fpr" = "$EXPECTED_FPR" ]
}

# Create a root-owned 0644 file with exact content, or verify an existing one is identical.
ensure_file() {
    local path=$1 content=$2 cur
    if [ -e "$path" ]; then
        cur=$(cat "$path")
        [ "$cur" = "$content" ] || fail "$path exists with different content; not overwriting"
        [ "$(stat -c '%a %U:%G' "$path")" = "644 root:root" ] || fail "$path has unexpected owner/mode: $(stat -c '%a %U:%G' "$path")"
        echo "kept existing $path (content verified identical)"
    else
        printf '%s\n' "$content" > "$path"
        chmod 0644 "$path"
        echo "created $path"
    fi
    cat "$path"
}

# Print the repository origins ("URL suite") that offer version $2 of package $1,
# parsed from `apt-cache policy`; the local dpkg status entry is ignored.
#   version line:  "     5:29.9.3-1~debian.13~trixie 500"   or " *** 5:29.9.3-... 100"
#   origin line:   "        500 https://download.docker.com/linux/debian trixie/stable amd64 Packages"
version_origins() {
    local pol
    pol=$(apt-cache policy "$1")
    awk -v v="$2" '
        $1=="***"                                       { cur=$2; next }
        NF==2 && $2 ~ /^-?[0-9]+$/ && $1 !~ /^-?[0-9]+$/ { cur=$1; next }
        $1 ~ /^-?[0-9]+$/ && cur==v && $2 != "/var/lib/dpkg/status" { print $2, $3 }
    ' <<<"$pol"
}

# Require: version $2 of $1 is offered by at least one repo, and ONLY by Docker's trixie/stable repo.
check_origin() {
    local pkg=$1 ver=$2 origins bad
    origins=$(version_origins "$pkg" "$ver")
    [ -n "$origins" ] || fail "$pkg $ver: no repository offers this version"
    bad=$(grep -vxF "$DOCKER_ORIGIN" <<<"$origins" || true)
    [ -z "$bad" ] || fail "$pkg $ver: also offered by an unexpected origin: $bad"
    echo "$pkg $ver <- $DOCKER_ORIGIN"
}

policy_field() {   # policy_field <pkg> Installed|Candidate
    local pol
    pol=$(apt-cache policy "$1")
    awk -v f="$2:" '$1==f {print $2}' <<<"$pol"
}

[ "$(id -u)" = 0 ] || fail "run with sudo"
echo
echo "##### Run started $(date -Is) on $(hostname) (rev 2, resumable)"

step "0. Pre-flight"
for p in docker.io docker-compose podman-docker containerd runc; do
    st=$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null || true)
    if [[ $st == i* ]]; then fail "conflicting package installed: $p ($st)"; fi
done
if [ "$(systemctl is-active docker 2>/dev/null || true)" = active ]; then
    [ -s "$HERE/ports-before.txt" ] || fail "docker already running and no pre-install port baseline exists"
    echo "docker already active: keeping existing pre-install baseline ports-before.txt"
else
    listen > "$HERE/ports-before.txt"
    echo "recorded fresh port baseline (docker not running)"
fi
echo "pre-flight OK"

step "1. Docker signing key"
install -m 0755 -d /etc/apt/keyrings
if [ -e "$KEY" ]; then
    key_fpr "$KEY" || fail "existing $KEY does not verify; not touching it"
    [ "$(stat -c '%a %U:%G' "$KEY")" = "644 root:root" ] || fail "$KEY has unexpected owner/mode"
    echo "kept existing $KEY (fingerprint verified)"
else
    TMPKEY=$(mktemp)
    curl -fsSL https://download.docker.com/linux/debian/gpg -o "$TMPKEY"
    if ! key_fpr "$TMPKEY"; then rm -f "$TMPKEY"; fail "downloaded key fingerprint mismatch (discarded, never installed)"; fi
    install -m 0644 -o root -g root "$TMPKEY" "$KEY"
    rm -f "$TMPKEY"
    echo "installed $KEY"
fi
echo "KEY-OK"

step "2. Repository definition"
ensure_file "$SOURCES" "$SOURCES_CONTENT"

step "3. Docker daemon configuration (before first start)"
install -m 0755 -d /etc/docker
ensure_file "$DAEMON" "$DAEMON_CONTENT"

step "4. apt update and candidate origin check (all packages)"
apt-get update
for p in $PKGS; do
    c=$(policy_field "$p" Candidate)
    [ -n "$c" ] && [ "$c" != "(none)" ] || fail "$p: no install candidate"
    check_origin "$p" "$c"
done
echo "candidate origins OK"

step "5. Install packages"
DEBIAN_FRONTEND=noninteractive apt-get install -y $PKGS

step "6. Verify installed packages and their origin"
for p in $PKGS; do
    st=$(dpkg-query -W -f='${db:Status-Abbrev}' "$p" 2>/dev/null || true)
    [[ $st == ii* ]] || fail "$p not properly installed (status '$st')"
    v=$(policy_field "$p" Installed)
    check_origin "$p" "$v"
done
echo "packages OK"

step "7. Verify configuration and services"
dockerd --validate --config-file "$DAEMON" || fail "daemon.json did not validate"
for s in docker containerd; do
    [ "$(systemctl is-enabled $s)" = enabled ] || fail "$s not enabled"
    [ "$(systemctl is-active $s)" = active ]   || fail "$s not active"
    echo "$s: enabled, active"
done
docker version --format 'Client {{.Client.Version}} / Server {{.Server.Version}} (API {{.Server.APIVersion}})'
docker compose version || fail "compose plugin not working"
docker buildx version  || fail "buildx plugin not working"

LD=$(docker info --format '{{.LoggingDriver}}')
echo "logging driver: $LD"
[ "$LD" = local ] || fail "logging driver is '$LD', expected 'local'"

INFO=$(docker info 2>/dev/null)
grep -iE 'firewall backend|storage driver|cgroup (driver|version)|docker root dir|logging driver' <<<"$INFO" || true
FB=$(grep -i 'Firewall Backend' <<<"$INFO" || true)
[ -n "$FB" ] || fail "docker info does not report a Firewall Backend"
[[ ${FB,,} == *iptables* ]] || fail "firewall backend is not iptables: $FB"
TABLES=$(nft list tables)
if grep -q 'docker-bridges' <<<"$TABLES"; then fail "nftables-backend table 'docker-bridges' present"; fi
iptables -n -L DOCKER-USER >/dev/null 2>&1 || fail "iptables DOCKER-USER chain missing"
ALT=$(update-alternatives --query iptables | awk '/^Value:/{print $2}')
echo "iptables alternative: $ALT ($(iptables --version))"
[[ $ALT == *iptables-nft ]] || fail "iptables is not iptables-nft: $ALT"
[ "$(systemctl is-enabled nftables 2>/dev/null || true)" = disabled ] || fail "nftables.service is no longer disabled"
echo "firewall backend OK (iptables via iptables-nft); nftables.service still disabled"
echo "net.ipv4.ip_forward=$(cat /proc/sys/net/ipv4/ip_forward) (set by Docker; informational)"

step "8. hello-world"
OUT=$(docker run --rm hello-world)
head -n 3 <<<"$OUT"
[[ $OUT == *'Hello from Docker!'* ]] || fail "hello-world did not print the expected greeting"
docker image rm hello-world >/dev/null && echo "hello-world image removed"
LEFT=$(docker ps -aq)
[ -z "$LEFT" ] || fail "containers remain after test: $LEFT"
IMGS=$(docker images -q)
echo "containers: none; images: $(grep -c . <<<"$IMGS" || true)"

step "9. Listening ports (before vs after)"
listen > "$HERE/ports-after.txt"
NEW=$(comm -13 "$HERE/ports-before.txt" "$HERE/ports-after.txt")
GONE=$(comm -23 "$HERE/ports-before.txt" "$HERE/ports-after.txt")
[ -z "$GONE" ] || echo "sockets no longer listening (informational): $GONE"
[ -z "$NEW" ] || fail "new listening sockets appeared: $NEW"
echo "no new listening ports"

echo
echo "ALL CHECKS PASSED $(date -Is)"
