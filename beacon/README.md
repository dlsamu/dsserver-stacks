# Beacon

Raspberry Pi 5 (8 GB), headless observability host. Raspberry Pi OS Lite 64-bit 2026-10-06 (Debian 13 trixie), 128 GB microSD, wired Ethernet with DHCP (`beacon.local`, 192.168.68.121 on 2026-11-10). No Docker or monitoring software yet.

| Item | Setting |
|---|---|
| Install | `flash-sd.sh` (image SHA-256 + GPG-verified, read-back compared) with `cloud-init/user-data` + `meta-data` and the `ssh` flag. First boot 2026-11-10: cloud-init `done` (one harmless warning: missing `cc_netplan_nm_patch` module) |
| Access | from dsserver: `ssh beacon` (`~/.ssh/config`: `beacon.local`, key `~/.ssh/beacon_admin` `SHA256:FUeaboVVG1shD6LYcaBEbHi0qHNHwzHEB8cPmJNlIaM`, no passphrase; `~/.ssh/known_hosts_beacon`, `StrictHostKeyChecking yes`) |
| Host key | ED25519 `SHA256:418PbwFoGJ9+lZdnllHq0NLDFNOKr86v76L8KIDB8hs` (trusted on first use over the LAN, matches Beacon's own `/etc/ssh/ssh_host_ed25519_key.pub`) |
| Account | `daniel`, password locked, passwordless sudo (Pi OS default via cloud-init). No root login |
| sshd | `/etc/ssh/sshd_config.d/10-beacon.conf`: `PermitRootLogin no`, no password/keyboard-interactive auth, `AllowUsers daniel` |
| Updates | `setup-base.sh`: unattended-upgrades daily (Debian stable/security/updates + Raspberry Pi archive for kernel/firmware/bootloader), **no automatic reboot**; reboot due when `/var/run/reboot-required` exists |
| Also present | `rpi-connect-lite` (Raspberry Pi Connect) installed by the image, **disabled**, not running |

**Reboot test (2026-11-10 22:49):** `systemctl reboot` over SSH → back in ~15 s, new boot ID, SSH key login ok, `is-system-running` = running, no failed units, NTP synchronized within a minute, throttling 0x0.

**Recovery:** if SSH is lost, power-cycle first (headless). If still unreachable, the card can be read on dsserver (USB reader) to inspect logs, or re-flashed with `flash-sd.sh` (everything on Beacon is reproducible from this directory). Physical console is the last resort.
