#!/bin/bash
# dsserver Phase U: create Linux user "axel" (development, key-only SSH from Windows).
# Usage: sudo bash phaseU-axel.sh <path-to-axel.pub> <expected SHA256 fingerprint> [--no-limits]
#   Example: sudo bash phaseU-axel.sh /home/daniel/axel-windows.pub SHA256:AbC...xyz
# The fingerprint must have been read out-of-band from the Windows PC (ssh-keygen -lf on the .pub file).
# Stops at the first failed validation. Not touched: firewall, Docker, /srv, daniel's account, other sshd settings.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
LOG="$HERE/phaseU-axel.log"
touch "$LOG"; chmod 0644 "$LOG"
exec > >(tee -a "$LOG") 2>&1

U=axel
UID_WANT=1001
COMMENT="Axel Samuelsson"
SSHD_DROPIN=/etc/ssh/sshd_config.d/20-dsserver-users.conf
SSHD_CONTENT='# dsserver: only these accounts may log in over SSH. Revert: delete this file, then "sshd -t && systemctl reload ssh".
AllowUsers daniel axel'
SLICE_DIR=/etc/systemd/system/user-${UID_WANT}.slice.d
SLICE_FILE=$SLICE_DIR/50-limits.conf
SLICE_CONTENT='# dsserver: keep axel'"'"'s development processes from starving the services.
[Slice]
MemoryHigh=12G
MemoryMax=16G
CPUWeight=50'

fail() { echo; echo "VALIDATION FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }

[ "$(id -u)" = 0 ] || fail "run with sudo"
PUB=${1:-}; FPR_WANT=${2:-}; LIMITS=yes
[ "${3:-}" = "--no-limits" ] && LIMITS=no
[ -n "$PUB" ] && [ -n "$FPR_WANT" ] || fail "usage: sudo bash $0 <axel.pub> <SHA256:fingerprint> [--no-limits]"
echo; echo "##### Phase U run $(date -Is) on $(hostname); limits=$LIMITS"

step "0. Pre-flight"
getent passwd "$U" >/dev/null && fail "user $U already exists"
getent passwd "$UID_WANT" >/dev/null && fail "UID $UID_WANT already in use"
getent group "$U" >/dev/null && fail "group $U already exists"
[ -e "/home/$U" ] && fail "/home/$U already exists"
[ -e "$SSHD_DROPIN" ] && fail "$SSHD_DROPIN already exists"
[ "$LIMITS" = no ] || { [ -e "$SLICE_DIR" ] && fail "$SLICE_DIR already exists"; }
[ -f "$PUB" ] || fail "public key file not found: $PUB"
NLINES=$(grep -c . "$PUB" || true)
[ "$NLINES" = 1 ] || fail "$PUB must contain exactly one key line (has $NLINES)"
KEYLINE=$(cat "$PUB")
[[ $KEYLINE == ssh-ed25519\ * ]] || fail "key is not ssh-ed25519"
[[ $KEYLINE != *PRIVATE* ]] || fail "this looks like a PRIVATE key; stop"
FPR_LINE=$(ssh-keygen -lf "$PUB") || fail "ssh-keygen cannot parse $PUB"
FPR_GOT=$(awk '{print $2}' <<<"$FPR_LINE")
echo "key: $FPR_LINE"
[ "$FPR_GOT" = "$FPR_WANT" ] || fail "fingerprint mismatch: file has $FPR_GOT, expected $FPR_WANT"
# daniel's own access must be intact before we restrict SSH users
[ -s /home/daniel/.ssh/authorized_keys ] || fail "daniel has no authorized_keys; refusing to set AllowUsers"
echo "pre-flight OK"

step "1. Create account (no password, own group, home 0700)"
adduser --disabled-password --uid "$UID_WANT" --comment "$COMMENT" "$U"
GROUPS_GOT=$(id -nG "$U")
echo "groups: $GROUPS_GOT"
for g in $GROUPS_GOT; do
    case "$g" in axel|users) ;; *) fail "unexpected group membership: $g";; esac
done
[ "$(stat -c '%a %U:%G' /home/$U)" = "700 axel:axel" ] || fail "/home/$U is $(stat -c '%a %U:%G' /home/$U)"
PWSTATE=$(passwd -S "$U" | awk '{print $2}')
echo "password state: $PWSTATE (expected L = no usable password)"
case "$PWSTATE" in
    P)  fail "axel has a usable password";;
    NP) fail "axel has an EMPTY password (would allow passwordless local login)";;
esac

step "2. Install axel's SSH public key"
install -d -m 0700 -o "$U" -g "$U" "/home/$U/.ssh"
install -m 0600 -o "$U" -g "$U" "$PUB" "/home/$U/.ssh/authorized_keys"
stat -c '%a %U:%G %n' "/home/$U/.ssh" "/home/$U/.ssh/authorized_keys"
[ "$(ssh-keygen -lf /home/$U/.ssh/authorized_keys | awk '{print $2}')" = "$FPR_WANT" ] || fail "installed key fingerprint differs"

if [ "$LIMITS" = yes ]; then
    step "3. Resource limits for axel's processes (user-${UID_WANT}.slice)"
    install -d -m 0755 "$SLICE_DIR"
    printf '%s\n' "$SLICE_CONTENT" > "$SLICE_FILE"; chmod 0644 "$SLICE_FILE"
    systemctl daemon-reload
    systemctl show "user-${UID_WANT}.slice" -p MemoryHigh -p MemoryMax -p CPUWeight
else
    step "3. Resource limits skipped (--no-limits)"
fi

step "4. Restrict SSH logins to daniel and axel"
printf '%s\n' "$SSHD_CONTENT" > "$SSHD_DROPIN"; chmod 0644 "$SSHD_DROPIN"
if ! sshd -t; then rm -f "$SSHD_DROPIN"; fail "sshd -t failed; removed $SSHD_DROPIN, ssh NOT reloaded"; fi
EFF=$(sshd -T)
grep -Ei '^(allowusers|passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication|allowtcpforwarding) ' <<<"$EFF"
grep -qx 'allowusers daniel' <<<"$EFF" || { rm -f "$SSHD_DROPIN"; fail "daniel missing from effective AllowUsers; removed drop-in, NOT reloaded"; }
grep -qx 'allowusers axel'   <<<"$EFF" || { rm -f "$SSHD_DROPIN"; fail "axel missing from effective AllowUsers; removed drop-in, NOT reloaded"; }
grep -qx 'passwordauthentication no' <<<"$EFF" || fail "password authentication is not off"
systemctl reload ssh && echo "ssh reloaded: $(systemctl is-active ssh)"

step "5. Isolation checks (as axel, non-interactive)"
SUDO_L=$(sudo -l -U "$U" 2>&1 || true); echo "sudo -l -U $U: $SUDO_L"
[[ $SUDO_L == *"not allowed"* ]] || fail "axel appears to have sudo rights"
if runuser -u "$U" -- docker ps >/dev/null 2>&1; then fail "axel can reach the Docker daemon"; fi
echo "docker as axel: denied (OK)"
if runuser -u "$U" -- ls /home/daniel >/dev/null 2>&1; then fail "axel can list /home/daniel"; fi
echo "/home/daniel as axel: denied (OK)"
for d in /srv/stacks /srv/appdata; do
    if [ -e "$d" ]; then
        if runuser -u "$U" -- ls "$d" >/dev/null 2>&1; then fail "axel can list $d"; fi
        echo "$d as axel: denied (OK)"
    else
        echo "$d does not exist yet (Phase S); check deferred"
    fi
done

echo; echo "PHASE U SERVER SIDE PASSED $(date -Is). Now test logins from Windows and dsoffice."
