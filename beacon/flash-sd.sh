#!/bin/bash
# Beacon: write Raspberry Pi OS Lite 64-bit (2026-10-06, trixie) to the microSD card and add the
# headless first-boot configuration (cloud-init). Run as root in Konsole:
#   sudo bash /srv/stacks/beacon/flash-sd.sh <path to 2026-10-06-raspios-trixie-arm64-lite.img.xz>
#
# Safety: the target is fixed to the USB card reader's by-id name and exact size below. The script
# refuses anything else (non-USB, non-removable, other size, anything holding / or /boot/efi), shows
# lsblk, and asks you to type the device name before writing. Writes nothing inside the repository.
set -euo pipefail

TARGET_ID=/dev/disk/by-id/usb-Generic_STORAGE_DEVICE_000000000819-0:0
TARGET_BYTES=127865454592
IMAGE_SHA256=483db18a48da399b5b7022ffae9a07bc6d99daab30e593aedac09b69ff422843   # from downloads.raspberrypi.com .sha256; image GPG signature verified (key F4AADD86C4687D69AE04543E796C114AD12B2292)
IMAGE_NAME=2026-10-06-raspios-trixie-arm64-lite.img.xz
HERE=$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")
CI=$HERE/cloud-init
PUBKEY_FPR=SHA256:FUeaboVVG1shD6LYcaBEbHi0qHNHwzHEB8cPmJNlIaM
UDEV_SERIAL=Generic_STORAGE_DEVICE_000000000819-0:0
RULE=/run/udev/rules.d/99-beacon-flash-noautomount.rules   # runtime only, removed on exit
MNT=""

cleanup() {
    if [ -n "$MNT" ]; then umount "$MNT" 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true; fi
    if [ -e "$RULE" ]; then rm -f "$RULE"; udevadm control --reload || true; fi
}
trap cleanup EXIT

fail() { echo; echo "FAILED: $*"; echo "Stopped."; exit 1; }
step() { echo; echo "=== $*"; }
ok()   { echo "ok    $*"; }

[ "$(id -u)" = 0 ] || fail "run with sudo"
[ $# = 1 ] || fail "usage: sudo bash $0 /path/to/$IMAGE_NAME"
IMG=$1
[ "$(basename "$IMG")" = "$IMAGE_NAME" ] || fail "unexpected image file name: $IMG"
for f in user-data meta-data; do [ -s "$CI/$f" ] || fail "missing $CI/$f"; done

step "1. Image"
echo "checking SHA-256 of $IMG ..."
[ "$(sha256sum "$IMG" | cut -d' ' -f1)" = "$IMAGE_SHA256" ] || fail "image checksum mismatch"
IMG_BYTES=$(xz --robot -l "$IMG" | awk '$1=="totals"{print $5}')
ok "image verified ($IMG_BYTES bytes uncompressed)"

step "2. Target device"
[ -e "$TARGET_ID" ] || fail "$TARGET_ID not present (card reader unplugged?)"
DEV=$(readlink -f "$TARGET_ID"); NAME=$(basename "$DEV")
[[ $NAME == sd[a-z] ]] || fail "$TARGET_ID resolves to $DEV, not a whole sdX disk"
[ "$(cat /sys/block/$NAME/removable)" = 1 ] || fail "$DEV is not removable"
[ "$(lsblk -dno TRAN "$DEV")" = usb ] || fail "$DEV is not on USB"
SIZE=$(( $(cat /sys/block/$NAME/size) * 512 )); [ "$SIZE" = "$TARGET_BYTES" ] || fail "$DEV size $SIZE != $TARGET_BYTES"
[ "$IMG_BYTES" -lt "$TARGET_BYTES" ] || fail "image larger than card"
for m in / /boot /boot/efi /home /srv; do
    src=$(findmnt -no SOURCE "$m" 2>/dev/null || true)
    [ -z "$src" ] && continue
    pk=$(lsblk -no PKNAME "$src" 2>/dev/null || true)
    [ "$pk" != "$NAME" ] || fail "$DEV holds $m"
done
grep -q "^/dev/$NAME" /proc/swaps && fail "$DEV is used as swap"
lsblk -o NAME,PATH,SIZE,TYPE,TRAN,RM,MODEL,SERIAL,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
ok "$DEV = USB removable 'Generic STORAGE DEVICE' serial 000000000819, $TARGET_BYTES bytes"

echo
echo "ALL DATA ON $DEV WILL BE ERASED (the old dsoffice card: bootfs + rootfs)."
read -r -p "Type the device name ($NAME) to continue, anything else aborts: " answer </dev/tty
[ "$answer" = "$NAME" ] || fail "aborted by user; nothing was written"

step "3. Stop desktop auto-mounting of this card (temporary), unmount its partitions"
mkdir -p /run/udev/rules.d
echo "SUBSYSTEM==\"block\", ENV{ID_SERIAL}==\"$UDEV_SERIAL\", ENV{UDISKS_IGNORE}=\"1\", ENV{UDISKS_AUTO}=\"0\"" > "$RULE"
udevadm control --reload
ok "runtime rule $RULE (removed when this script exits)"
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
    while findmnt -rno TARGET -S "$p" >/dev/null; do umount "$p"; done
done
[ -z "$(lsblk -lnpo MOUNTPOINTS "$DEV" | tr -d '[:space:]')" ] || fail "partitions still mounted"
ok "nothing on $DEV is mounted"

step "4. Write image"
xz -dc "$IMG" | dd of="$DEV" bs=4M iflag=fullblock oflag=direct conv=fsync status=progress
sync
ok "written"

step "5. Verify by reading the card back"
blockdev --flushbufs "$DEV"; echo 3 > /proc/sys/vm/drop_caches
xz -dc "$IMG" | cmp -n "$IMG_BYTES" - "$DEV" || fail "read-back differs from the image"
ok "first $IMG_BYTES bytes on $DEV are identical to the image"

step "6. First-boot configuration on the boot partition"
blockdev --rereadpt "$DEV" || partprobe "$DEV" || true
udevadm settle
BOOT=${DEV}1
for i in $(seq 1 20); do [ -b "$BOOT" ] && break; sleep 0.5; done
[ -b "$BOOT" ] || fail "$BOOT did not appear"
sleep 2; udevadm settle
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
    while findmnt -rno TARGET -S "$p" >/dev/null; do umount "$p"; done   # auto-mounted again
done
[ "$(lsblk -no FSTYPE "$BOOT")" = vfat ] || fail "$BOOT is not vfat"
MNT=$(mktemp -d)
mount -o rw,nosuid,nodev,noexec "$BOOT" "$MNT"
echo "--- shipped files in the boot partition:"; ls "$MNT" | grep -vE '\.(dtb|dat|elf|bin)$|^overlays$' | tr '\n' ' '; echo
for f in user-data meta-data network-config; do
    if [ -e "$MNT/$f" ]; then echo "--- shipped $f:"; sed 's/^/    /' "$MNT/$f"; fi
done
grep -q 'ds=nocloud\|cloud-init' "$MNT/cmdline.txt" && echo "info  cmdline.txt mentions cloud-init/nocloud" || echo "info  cmdline.txt: $(cat "$MNT/cmdline.txt")"
cp "$CI/user-data" "$MNT/user-data"
cp "$CI/meta-data" "$MNT/meta-data"
: > "$MNT/ssh"
sync
cmp "$CI/user-data" "$MNT/user-data" && cmp "$CI/meta-data" "$MNT/meta-data" || fail "config files differ after writing"
[ -e "$MNT/ssh" ] || fail "ssh flag file missing"
fp=$(grep -o 'ssh-ed25519 [A-Za-z0-9+/=]* .*' "$MNT/user-data" | ssh-keygen -lf - | awk '{print $2}')
[ "$fp" = "$PUBKEY_FPR" ] || fail "authorized key on card has fingerprint $fp, expected $PUBKEY_FPR"
grep -q '^hostname: beacon$' "$MNT/user-data" || fail "hostname missing"
grep -q 'PRIVATE KEY' "$MNT/user-data" "$MNT/meta-data" && fail "private key material found on card"
[ -e "$MNT/network-config" ] && echo "info  keeping the image's network-config (shown above)"
ok "user-data, meta-data and ssh flag written and verified (key $PUBKEY_FPR, hostname beacon)"
umount "$MNT"; rmdir "$MNT"; MNT=""

step "7. Eject"
sync
for p in $(lsblk -lnpo NAME "$DEV" | tail -n +2); do
    while findmnt -rno TARGET -S "$p" >/dev/null; do umount "$p"; done
done
if command -v udisksctl >/dev/null && udisksctl power-off -b "$DEV" 2>/dev/null; then ok "card powered off; safe to remove"
else blockdev --flushbufs "$DEV"; ok "flushed; safe to remove once the reader's light stops"; fi
echo; echo "FLASH COMPLETE $(date -Is). Put the card in the Pi 5, connect Ethernet, power on."
