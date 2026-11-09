#!/bin/sh
# dsserver SSH Phase B (approved): key-only auth, no root login. Run as root.
set -u
F=/etc/ssh/sshd_config.d/10-dsserver-auth.conf

if [ -e "$F" ]; then echo "ABORT: $F already exists; not overwriting."; exit 1; fi

cat > "$F" <<'EOF'
# dsserver: key-only SSH. Revert: delete this file, then "sshd -t && systemctl reload ssh".
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
EOF
chmod 0644 "$F"

if ! sshd -t; then
    echo "ABORT: sshd -t failed. Removing $F; ssh NOT reloaded."
    rm -f "$F"
    exit 1
fi
echo "CONFIG-OK (sshd -t passed)"

sshd -T | grep -Ei '^(passwordauthentication|kbdinteractiveauthentication|permitrootlogin|pubkeyauthentication) '

systemctl reload ssh && echo "ssh reloaded: $(systemctl is-active ssh)"
