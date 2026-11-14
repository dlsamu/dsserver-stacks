#!/bin/bash
# Unmount every DATASERVER mount and remove any leftover credential file. Safe to run repeatedly.
W=/volume1/@claude-migration
pkill -TERM -f "$W/migrate.py" 2>/dev/null; sleep 5
for m in $(mount | awk '$5=="cifs" && $3 ~ "^/volume1/@claude-migration/src/" {print $3}'); do umount "$m" 2>/dev/null || umount -l "$m"; done
rm -f /run/claude-cifs.*
echo "$(date '+%F %T') cleanup: $1; cifs mounts left: $(mount | grep -c ' type cifs ')" >> $W/logs/watchdog.log
