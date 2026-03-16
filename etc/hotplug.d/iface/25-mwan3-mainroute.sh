#!/bin/sh
[ "$ACTION" = "ifup" ] || [ "$ACTION" = "ifdown" ] || exit 0
logger -t mwan3-mainroute "Fired: ACTION=$ACTION INTERFACE=$INTERFACE"

if [ "$ACTION" = "ifdown" ] && [ "$INTERFACE" = "wwan" ]; then
    sleep 3
    GW2=$(ip route show table 2 | awk '/^default/{print $3}')
    DEV2=$(ip route show table 2 | awk '/^default/{print $5}')
    logger -t mwan3-mainroute "GW2=$GW2 DEV2=$DEV2"
    [ -n "$GW2" ] && ip route replace default via $GW2 dev $DEV2
fi

if [ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wwan" ]; then
    sleep 3
    GW1=$(ip route show table 1 | awk '/^default/{print $3}')
    DEV1=$(ip route show table 1 | awk '/^default/{print $5}')
    WWAN_IP=$(ip -4 addr show phy1-sta0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    logger -t mwan3-mainroute "GW1=$GW1 DEV1=$DEV1 WWAN_IP=$WWAN_IP"
    case "$WWAN_IP" in
        192.168.0.*) logger -t mwan3-mainroute "Captive portal detected, skipping route restore" ;;
        *) [ -n "$GW1" ] && ip route replace default via $GW1 dev $DEV1 ;;
    esac
fi
