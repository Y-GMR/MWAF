#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command /root/safe_wwan_monitor.sh
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    killall safe_wwan_monitor.sh 2>/dev/null || true
    rm -f /tmp/wwan_recovery.lock
    rm -f /tmp/wwan_recovery_state
    rm -f /tmp/wwan_monitor_health
}