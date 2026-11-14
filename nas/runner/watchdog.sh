#!/bin/bash
# Dead-man switch, started with setsid. Unmounts DATASERVER if the migration goes silent (no heartbeat for 45 min)
# or at UNMOUNT_DEADLINE (before Replay's nightly window). At LOCKDOWN_DEADLINE it also turns SSH off and disables
# the temporary claude-setup account. Never touches data, shares, or other accounts.
W=/volume1/@claude-migration
UNMOUNT_DEADLINE=$(date -d "2026-11-14 23:30" +%s)
LOCKDOWN_DEADLINE=$(date -d "2026-11-15 10:00" +%s)
echo $$ > $W/watchdog.pid
echo "$(date '+%F %T') watchdog started (unmount deadline 2026-11-14 23:30, lockdown 2026-11-15 10:00)" >> $W/logs/watchdog.log
while true; do
  now=$(date +%s); hb=$(cat $W/heartbeat 2>/dev/null | cut -d. -f1); hb=${hb:-0}
  mounted=$(mount | awk '$5=="cifs" && $3 ~ "^/volume1/@claude-migration/src/"' | wc -l)
  if [ "$mounted" -gt 0 ] && [ $((now - hb)) -gt 2700 ]; then $W/cleanup.sh "no heartbeat for $(( (now-hb)/60 )) min"; fi
  if [ "$mounted" -gt 0 ] && [ "$now" -gt "$UNMOUNT_DEADLINE" ]; then $W/cleanup.sh "unmount deadline reached"; fi
  if [ "$now" -gt "$LOCKDOWN_DEADLINE" ]; then
    $W/cleanup.sh "lockdown deadline"
    /usr/syno/bin/synowebapi --exec api=SYNO.Core.Terminal method=set version=3 enable_ssh=false >/dev/null 2>&1
    /usr/syno/sbin/synouser --modify claude-setup "temporary setup account (disabled by watchdog)" 1 "" >/dev/null 2>&1
    echo "$(date '+%F %T') lockdown: SSH off, claude-setup disabled" >> $W/logs/watchdog.log
    exit 0
  fi
  sleep 60
done
