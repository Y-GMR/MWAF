#!/bin/sh
# V2.7 - PRIMARY_SSID_PLACEHOLDER as primary SSID, dual MAC login, post-login retry loop

############################
# HARD SINGLETON (PROCESS)
############################
PIDFILE="/tmp/safe_wwan_monitor.pid"
LOG_TAG="wwan-safe"

if [ -f "$PIDFILE" ]; then
    OLD_PID="$(cat "$PIDFILE")"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
        logger -t "$LOG_TAG" "Already running (PID $OLD_PID), exiting"
        exit 0
    else
        logger -t "$LOG_TAG" "Stale PID file found, cleaning up..."
        rm -f "$PIDFILE"
    fi
fi

echo $$ > "$PIDFILE"
trap 'rm -f "$PIDFILE"' EXIT INT TERM

############################
# STATE / LOCK FILES
############################
STATE_FILE="/tmp/wwan_recovery_state"
LOCK_FILE="/tmp/wwan_recovery.lock"
HEALTH_FILE="/tmp/wwan_monitor_health"
DHCP_LOOP_FILE="/tmp/wwan_dhcp_loop"

############################
# CONFIGURATION
############################
MAX_LOGIN_ATTEMPTS=3 # Max attempts before cooldown
ATTEMPT_INTERVAL=60 # Seconds between login attempts
COOLDOWN_PERIOD=300 # Seconds to wait after max attempts before retrying
RECHECK_DELAY=3 # Seconds to wait between checks when idle
STABILITY_CHECK=5 # Seconds to confirm offline state before acting

DHCP_LOOP_THRESHOLD=10 # Number of DHCP renewals in window to consider a loop
DHCP_LOOP_WINDOW=120 # Seconds to look back for DHCP renewals when detecting loops
MAX_NETWORK_RESTARTS=5 # Max network restarts before enforcing cooldown
NETWORK_RESTART_COOLDOWN=120 # Seconds to wait after max network restarts before allowing more

TRAP_PREFIX="192.168.0." # Assuming captive portal IPs are in this range, adjust as needed
VALID_PREFIX="192.168.10." # Assuming valid IPs are in this range, adjust as needed

# Interfaces
WWAN_IFACE="phy1-sta0" # Primary WWAN interface
WWAN2_IFACE="phy0-sta0" # Secondary WWAN interface

# SSID Fallback
PRIMARY_SSID="PRIMARY_SSID_PLACEHOLDER"
FALLBACK_SSID="FALLBACK_SSID_PLACEHOLDER"
FALLBACK_PASSWORD=""
MAX_COOLDOWN_CYCLES=3

# Post-login internet check retry
POST_LOGIN_RETRIES=5      # retries per cycle
POST_LOGIN_RETRY_GAP=6    # seconds between retries
POST_LOGIN_CYCLE_WAIT=20  # seconds between full cycles
POST_LOGIN_MAX_CYCLES=3   # full cycles before giving up and observing

HEALTH_INTERVAL=3600

############################
# HEALTH TICK
############################
touch_health() {
    date +%s > "$HEALTH_FILE" 2>/dev/null || true
}

############################
# STATE HANDLING
############################
load_state() {
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
    else
        ATTEMPTS=0; LAST_LOGIN=0; ADGUARD_RUNNING=0
        LAST_STATE="unknown"; OFFLINE_CONFIRMED=0
        NETWORK_RESTARTS=0; LAST_NETWORK_RESTART=0
        COOLDOWN_CYCLES=0; USING_FALLBACK_SSID=0
    fi
}

save_state() {
    cat > "$STATE_FILE" << EOF
ATTEMPTS=$ATTEMPTS
LAST_LOGIN=$LAST_LOGIN
ADGUARD_RUNNING=$ADGUARD_RUNNING
LAST_STATE=$LAST_STATE
OFFLINE_CONFIRMED=$OFFLINE_CONFIRMED
NETWORK_RESTARTS=$NETWORK_RESTARTS
LAST_NETWORK_RESTART=$LAST_NETWORK_RESTART
COOLDOWN_CYCLES=$COOLDOWN_CYCLES
USING_FALLBACK_SSID=$USING_FALLBACK_SSID
EOF
}

reset_state() {
    ATTEMPTS=0; LAST_LOGIN=0; OFFLINE_CONFIRMED=0
    save_state
}

############################
# DHCP LOOP DETECTION
############################
record_dhcp_renewal() {
    NOW=$(date +%s)
    echo "$NOW" >> "$DHCP_LOOP_FILE"

    if [ -f "$DHCP_LOOP_FILE" ]; then
        CUTOFF=$((NOW - DHCP_LOOP_WINDOW))
        grep -v "^$" "$DHCP_LOOP_FILE" | awk -v c="$CUTOFF" '$1 > c' > "${DHCP_LOOP_FILE}.tmp"
        mv "${DHCP_LOOP_FILE}.tmp" "$DHCP_LOOP_FILE"
    fi
}

get_dhcp_renewal_count() {
    [ -f "$DHCP_LOOP_FILE" ] && wc -l < "$DHCP_LOOP_FILE" || echo 0
}

clear_dhcp_loop_tracking() {
    rm -f "$DHCP_LOOP_FILE"
}

is_dhcp_loop_detected() {
    COUNT=$(get_dhcp_renewal_count)
    [ "$COUNT" -ge "$DHCP_LOOP_THRESHOLD" ] && return 0
    return 1
}

############################
# SSID FALLBACK
############################
switch_to_fallback_ssid() {
    logger -t "$LOG_TAG" "LOGIN UNREACHABLE: Switching wwan to fallback SSID '$FALLBACK_SSID'"
    uci set wireless.wifinet1.ssid="$FALLBACK_SSID"
    uci del wireless.wifinet1.key
    uci commit wireless
    ifdown wwan >/dev/null 2>&1
    sleep 2
    ifup wwan >/dev/null 2>&1
    USING_FALLBACK_SSID=1
    COOLDOWN_CYCLES=0
    ATTEMPTS=0
    save_state
    logger -t "$LOG_TAG" "SSID SWITCHED: Now connecting to '$FALLBACK_SSID', waiting for IP..."
}

switch_to_primary_ssid() {
    logger -t "$LOG_TAG" "SSID RESTORE: Switching back to primary SSID '$PRIMARY_SSID'"
    uci set wireless.wifinet1.ssid="$PRIMARY_SSID"
    uci del wireless.wifinet1.key
    uci commit wireless
    ifdown wwan >/dev/null 2>&1
    sleep 2
    ifup wwan >/dev/null 2>&1
    USING_FALLBACK_SSID=0
    COOLDOWN_CYCLES=0
    ATTEMPTS=0
    save_state
}

############################
# SAFE NETWORK RESTART
############################
safe_network_restart() {
    NOW=$(date +%s)

    if [ "$NETWORK_RESTARTS" -ge "$MAX_NETWORK_RESTARTS" ]; then
        REMAINING=$((NETWORK_RESTART_COOLDOWN - (NOW - LAST_NETWORK_RESTART)))
        if [ "$REMAINING" -gt 0 ]; then
            logger -t "$LOG_TAG" "RESTART BLOCKED: Cooldown active (${REMAINING}s remaining)"
            return 1
        else
            logger -t "$LOG_TAG" "Restart cooldown expired, resetting counter"
            NETWORK_RESTARTS=0
        fi
    fi

    logger -t "$LOG_TAG" "NETWORK RESTART: Initiating safe restart (attempt $((NETWORK_RESTARTS + 1))/$MAX_NETWORK_RESTARTS)"

    WWAN2_IP=$(ip -4 addr show "$WWAN2_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    if ! in_valid_range "$WWAN2_IP"; then
        stop_adguard
    else
        logger -t "$LOG_TAG" "wwan2 active ($WWAN2_IP), keeping AdGuard running during restart"
    fi

    ifdown wwan >/dev/null 2>&1
    sleep 2
    ifup wwan >/dev/null 2>&1

    NETWORK_RESTARTS=$((NETWORK_RESTARTS + 1))
    LAST_NETWORK_RESTART=$NOW
    save_state

    clear_dhcp_loop_tracking

    logger -t "$LOG_TAG" "RESTART COMPLETE: Interface cycled, waiting for new IP"
    sleep 5

    return 0
}

############################
# ADGUARD CONTROL
############################
is_adguard_running() {
    /etc/init.d/adguardhome status >/dev/null 2>&1 && return 0
    pgrep -f '[Aa]dguard' >/dev/null 2>&1 && return 0
    return 1
}

stop_adguard() {
    if is_adguard_running; then
        logger -t "$LOG_TAG" "STOPPING AdGuard Home (saving resources)"
        /etc/init.d/adguardhome stop >/dev/null 2>&1 || true
        ADGUARD_RUNNING=0
        save_state
    fi
}

start_adguard() {
    if ! is_adguard_running; then
        logger -t "$LOG_TAG" "STARTING AdGuard Home"
        /etc/init.d/adguardhome start >/dev/null 2>&1 || true
        sleep 1
        /etc/init.d/dnsmasq restart >/dev/null 2>&1 || true
        ADGUARD_RUNNING=1
        save_state
    fi
}

############################
# NETWORK HELPERS
############################
get_default_route() {
    ip route show default 2>/dev/null | grep -q '^default'
}

get_ip() {
    ip -4 route show default 2>/dev/null | awk '{print $5}' | while read -r iface; do
        ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1
        return
    done
}

in_trap() {
    echo "$1" | grep -q "^$TRAP_PREFIX"
}

in_valid_range() {
    echo "$1" | grep -q "^$VALID_PREFIX"
}

has_internet() {
    STATUS=$(curl -o /dev/null -s -m 4 --connect-timeout 3 -w "%{http_code}" http://www.google.com/generate_204 2>/dev/null)
    [ "$STATUS" = "204" ] && return 0
    ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && return 0
    return 1
}

############################
# POST-LOGIN INTERNET WAIT
# Retries in cycles, then gives up and observes passively
############################
wait_for_internet_after_login() {
    CYCLE=0
    while [ "$CYCLE" -lt "$POST_LOGIN_MAX_CYCLES" ]; do
        CYCLE=$((CYCLE + 1))
        logger -t "$LOG_TAG" "POST-LOGIN CHECK: Cycle $CYCLE/$POST_LOGIN_MAX_CYCLES"

        RETRY=0
        while [ "$RETRY" -lt "$POST_LOGIN_RETRIES" ]; do
            RETRY=$((RETRY + 1))
            if has_internet; then
                logger -t "$LOG_TAG" "POST-LOGIN CHECK: Internet confirmed on retry $RETRY (cycle $CYCLE)"
                return 0
            fi
            logger -t "$LOG_TAG" "POST-LOGIN CHECK: Not yet... retry $RETRY/$POST_LOGIN_RETRIES"
            sleep "$POST_LOGIN_RETRY_GAP"
        done

        if [ "$CYCLE" -lt "$POST_LOGIN_MAX_CYCLES" ]; then
            logger -t "$LOG_TAG" "POST-LOGIN CHECK: Cycle $CYCLE exhausted, waiting ${POST_LOGIN_CYCLE_WAIT}s before next cycle..."
            sleep "$POST_LOGIN_CYCLE_WAIT"
        fi
    done

    logger -t "$LOG_TAG" "POST-LOGIN CHECK: All cycles exhausted, observing passively..."
    return 1
}

############################
# LOGIN ATTEMPT
############################
attempt_login() {
    logger -t "$LOG_TAG" "ATTEMPTING LOGIN: MikroTik authentication (attempt $ATTEMPTS/$MAX_LOGIN_ATTEMPTS)"
    /root/mikrotik_login.sh >/tmp/wwan_login.out 2>&1 || return 1
    LAST_LOGIN=$(date +%s)
    save_state

    if wait_for_internet_after_login; then
        logger -t "$LOG_TAG" "LOGIN SUCCESS: Internet reachable"
        ATTEMPTS=0
        COOLDOWN_CYCLES=0

        # Authorize both MACs on MikroTik
        WWAN_IP=$(ip -4 addr show "$WWAN_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        WWAN2_IP=$(ip -4 addr show "$WWAN2_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)

        if in_valid_range "$WWAN_IP"; then
            logger -t "$LOG_TAG" "DUAL LOGIN: Authorizing wwan MAC via $WWAN_IFACE"
            /root/mikrotik_login.sh "$WWAN_IFACE" >/tmp/wwan_login_wwan.out 2>&1 || true
        fi

        if in_valid_range "$WWAN2_IP"; then
            logger -t "$LOG_TAG" "DUAL LOGIN: Authorizing wwan2 MAC via $WWAN2_IFACE"
            /root/mikrotik_login.sh "$WWAN2_IFACE" >/tmp/wwan_login_wwan2.out 2>&1 || true
        fi

        if [ "$USING_FALLBACK_SSID" = "1" ]; then
            switch_to_primary_ssid
        fi
        start_adguard
        LAST_STATE="online"
        OFFLINE_CONFIRMED=0
        clear_dhcp_loop_tracking
        save_state
        return 0
    fi

    logger -t "$LOG_TAG" "LOGIN FAILED: Internet did not recover after all cycles"
    return 1
}

############################
# MAIN LOGIC
############################
check_and_act() {
    touch_health
    CURRENT_IP="$(get_ip)"
    NOW=$(date +%s)

    if [ -z "$CURRENT_IP" ]; then
        if [ "$LAST_STATE" != "no_ip" ]; then
            logger -t "$LOG_TAG" "No IP detected yet, waiting for interface..."
            LAST_STATE="no_ip"
            save_state
        fi
        return
    fi

    if in_trap "$CURRENT_IP"; then
        if [ "$LAST_STATE" != "trap" ]; then
            logger -t "$LOG_TAG" "TRAP DETECTED: Captive portal region ($CURRENT_IP)"
            WWAN2_IP=$(ip -4 addr show "$WWAN2_IFACE" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
            if ! in_valid_range "$WWAN2_IP"; then
                stop_adguard
            else
                logger -t "$LOG_TAG" "TRAP on wwan but wwan2 is active ($WWAN2_IP), keeping AdGuard running"
            fi
            LAST_STATE="trap"
            save_state
            clear_dhcp_loop_tracking
        fi

        record_dhcp_renewal

        if is_dhcp_loop_detected; then
            LOOP_COUNT=$(get_dhcp_renewal_count)
            logger -t "$LOG_TAG" "DHCP LOOP DETECTED: $LOOP_COUNT renewals in ${DHCP_LOOP_WINDOW}s window"

            if safe_network_restart; then
                logger -t "$LOG_TAG" "Waiting for network to stabilize after restart..."
                sleep 10
            fi
        fi

        return
    fi

    if in_valid_range "$CURRENT_IP" && has_internet; then
        if [ "$LAST_STATE" != "online" ]; then
            logger -t "$LOG_TAG" "INTERNET DETECTED: Connection active (IP: $CURRENT_IP)"
            start_adguard
            LAST_STATE="online"
            OFFLINE_CONFIRMED=0
            COOLDOWN_CYCLES=0
            clear_dhcp_loop_tracking
            save_state
        fi
        return
    fi

    if [ "$LAST_STATE" != "offline" ]; then
        logger -t "$LOG_TAG" "NO INTERNET: Waiting ${STABILITY_CHECK}s to confirm... (IP: $CURRENT_IP)"
        OFFLINE_CONFIRMED=$NOW
        LAST_STATE="offline"
        save_state
        return
    fi

    [ $((NOW - OFFLINE_CONFIRMED)) -lt "$STABILITY_CHECK" ] && return

    if [ "$ATTEMPTS" -ge "$MAX_LOGIN_ATTEMPTS" ]; then
        REMAINING=$((COOLDOWN_PERIOD - (NOW - LAST_LOGIN)))
        if [ "$REMAINING" -gt 0 ]; then
            [ $((REMAINING % 30)) -eq 0 ] && logger -t "$LOG_TAG" "MAX ATTEMPTS: Cooldown active (${REMAINING}s)"
            return
        else
            logger -t "$LOG_TAG" "Cooldown expired, resetting attempts"
            ATTEMPTS=0
            COOLDOWN_CYCLES=$((COOLDOWN_CYCLES + 1))
            save_state

            if [ "$COOLDOWN_CYCLES" -ge "$MAX_COOLDOWN_CYCLES" ] && [ "$USING_FALLBACK_SSID" = "0" ]; then
                switch_to_fallback_ssid
                return
            fi
        fi
    fi

    [ $((NOW - LAST_LOGIN)) -lt "$ATTEMPT_INTERVAL" ] && return

    ATTEMPTS=$((ATTEMPTS + 1))
    save_state
    attempt_login || true
}

############################
# STARTUP
############################
logger -t "$LOG_TAG" "SERVICE STARTING: Safe WWAN Monitor v2.7 initializing"
load_state
clear_dhcp_loop_tracking
logger -t "$LOG_TAG" "State loaded: attempts=$ATTEMPTS last_login=$LAST_LOGIN state=$LAST_STATE cycles=$COOLDOWN_CYCLES fallback=$USING_FALLBACK_SSID"

############################
# EVENT MONITOR
############################
(
    ip monitor route 2>/dev/null | while read -r _; do
        sleep 1
        kill -USR1 $$ 2>/dev/null || true
    done
) &

trap 'check_and_act' USR1

############################
# MAIN LOOP
############################
while true; do
    check_and_act
    sleep "$RECHECK_DELAY"
done