#!/bin/bash
# Beacon base setup after first boot (idempotent). Run from dsserver:
#   ssh beacon 'sudo bash -s' < /srv/stacks/beacon/setup-base.sh
# - unattended-upgrades: Debian security + stable updates (package default) plus the Raspberry Pi
#   archive (kernel, firmware, bootloader come only from there). Daily. No automatic reboot.
# - sshd: no root login, only user daniel (password auth is already off via cloud-init).
# Installs no monitoring software and no Docker.
set -euo pipefail
ok()   { echo "ok    $*"; }
fail() { echo "FAILED: $*"; exit 1; }
[ "$(id -u)" = 0 ] || fail "run as root"
[ "$(hostname)" = beacon ] || fail "not beacon"

echo "=== unattended-upgrades"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q unattended-upgrades >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// Beacon (/srv/stacks/beacon/setup-base.sh): refresh lists and run unattended-upgrades daily.
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
cat > /etc/apt/apt.conf.d/52beacon-unattended-upgrades <<'EOF'
// Beacon (/srv/stacks/beacon/setup-base.sh). Debian origins stay at the package default
// (50unattended-upgrades: Debian stable + Debian-Security). Added: the Raspberry Pi archive, the
// only source of the Pi kernel, firmware and bootloader updates.
Unattended-Upgrade::Origins-Pattern {
    "origin=Raspberry Pi Foundation,codename=${distro_codename},label=Raspberry Pi Foundation";
    "origin=Debian,codename=${distro_codename}-updates";
};
// Never reboot automatically; /var/run/reboot-required shows when a reboot is due.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Mail "";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1
ok "configured; timers: $(systemctl is-active apt-daily.timer) / $(systemctl is-active apt-daily-upgrade.timer)"

echo "=== sshd"
cat > /etc/ssh/sshd_config.d/10-beacon.conf <<'EOF'
# Beacon (/srv/stacks/beacon/setup-base.sh): key-only, no root, only daniel.
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
AllowUsers daniel
EOF
sshd -t || fail "sshd config test failed"
systemctl reload ssh
sshd -T | grep -E '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers) ' | sed 's/^/      /'
ok "sshd reloaded (existing sessions unaffected)"
