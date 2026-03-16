#!/bin/sh
# MikroTik Captive Portal Login Script
# V2.4 - Interface binding + credential fallback (PRIMARY_USERNAME primary, FALLBACK_USERNAME fallback)

LOGIN_URL="http://192.168.10.1/login" # Login URL for the MikroTik captive portal (change if different)

BIND_IFACE="${1:-}"
COOKIE_JAR="/tmp/mikrotik_cookie_${1:-default}"
LOGIN_PAGE="/tmp/login_page_${1:-default}.html"

CURL_IFACE=""
[ -n "$BIND_IFACE" ] && CURL_IFACE="--interface $BIND_IFACE"

# Try credentials in order: Primary first, Fallback as fallback
for CREDS in "PRIMARY_USERNAME:PRIMARY_PASSWORD" "FALLBACK_USERNAME:FALLBACK_PASSWORD"; do
    USERNAME="${CREDS%%:*}"
    PASSWORD="${CREDS##*:}"

    logger -t wwan-login "Trying credentials: $USERNAME${BIND_IFACE:+ via $BIND_IFACE}"

    # 1. Fetch login page to obtain salt/challenge
    if ! curl -s -m 10 $CURL_IFACE -c "$COOKIE_JAR" "$LOGIN_URL" > "$LOGIN_PAGE"; then
        logger -t wwan-login "ERROR: Could not fetch login page from $LOGIN_URL${BIND_IFACE:+ via $BIND_IFACE}"
        rm -f "$LOGIN_PAGE" "$COOKIE_JAR"
        exit 1
    fi

    # 2. Extract salt components
    SALT_PREFIX=$(grep "hexMD5" "$LOGIN_PAGE" | awk -F"'" '{print $2}')
    SALT_SUFFIX=$(grep "hexMD5" "$LOGIN_PAGE" | awk -F"'" '{print $4}')

    if [ -z "$SALT_SUFFIX" ]; then
        logger -t wwan-login "ERROR: Could not extract salt from login page${BIND_IFACE:+ via $BIND_IFACE}"
        logger -t wwan-login "DEBUG: $(grep -i 'hexMD5\|password\|login' "$LOGIN_PAGE" | head -c 200)"
        rm -f "$LOGIN_PAGE" "$COOKIE_JAR"
        exit 1
    fi

    # 3. Compute MD5 hash response
    HASH=$(printf "${SALT_PREFIX}${PASSWORD}${SALT_SUFFIX}" | md5sum | awk '{print $1}')
    logger -t wwan-login "Salt found, hash calculated. Submitting $USERNAME...${BIND_IFACE:+ (interface: $BIND_IFACE)}"

    # 4. Submit login request
    RESPONSE=$(curl -s -m 15 $CURL_IFACE -b "$COOKIE_JAR" -X POST "$LOGIN_URL" \
        -d "username=$USERNAME" \
        -d "password=$HASH" \
        -d "dst=" \
        -d "popup=true")

    # 5. Validate authentication
    if echo "$RESPONSE" | grep -qi "error\|invalid\|failed"; then
        logger -t wwan-login "LOGIN REJECTED: $USERNAME denied, trying next credentials..."
        rm -f "$LOGIN_PAGE" "$COOKIE_JAR"
    else
        logger -t wwan-login "LOGIN SUCCESS: $USERNAME accepted${BIND_IFACE:+ via $BIND_IFACE}"
        rm -f "$LOGIN_PAGE" "$COOKIE_JAR"
        exit 0
    fi
done

# If we exhaust all credentials
logger -t wwan-login "LOGIN FAILED: All credentials exhausted${BIND_IFACE:+ via $BIND_IFACE}"
exit 1