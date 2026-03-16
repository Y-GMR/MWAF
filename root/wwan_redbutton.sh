#!/bin/sh
/etc/init.d/wwan-safe stop
/etc/init.d/wwan-safe disable
killall safe_wwan_monitor.sh 2>/dev/null
rm -f /tmp/wwan_recovery.lock
rm -f /tmp/wwan_recovery_state
rm -f /tmp/wwan_monitor_health
echo "[OK] WWAN monitor fully stopped"