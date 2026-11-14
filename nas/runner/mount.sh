#!/bin/bash
# Mount DATASERVER shares READ-ONLY. Reads "username=..\npassword=.." on stdin, uses a tmpfs credential file
# only for the duration of the mount calls, then deletes it (the kernel keeps the session for reconnects).
set -u
W=/volume1/@claude-migration; CRED=/run/claude-cifs.$$
trap 'rm -f "$CRED"' EXIT
umask 077; cat > "$CRED"
for s in "$@"; do
  m="$W/src/$s"; mkdir -p "$m"
  if mount | grep -q " on $m type cifs"; then echo "already mounted: $s"; continue; fi
  mount -t cifs "//192.168.68.119/$s" "$m" -o ro,vers=3.0,credentials="$CRED",iocharset=utf8,uid=0,gid=0,file_mode=0444,dir_mode=0555,soft,actimeo=5,echo_interval=30 \
    && echo "mounted ro: $s" || echo "MOUNT FAILED: $s"
done
rm -f "$CRED"
date +%s > $W/heartbeat
