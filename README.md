# MWAF — MikroTik Wireless Auto Failover

Automatic dual-WAN failover with MikroTik hotspot authentication for OpenWrt routers. Designed for setups where your router connects to upstream WiFi access points (repeater/client mode) and needs to maintain internet connectivity when the primary AP drops.

## What it does

- **Automatic failover** — when the primary 5GHz uplink (wwan) drops, traffic switches to the 2.4GHz backup (wwan2) within ~5 seconds
- **Automatic recovery** — when the primary uplink comes back, traffic switches back automatically
- **MikroTik hotspot login** — automatically authenticates with the captive portal after a session reset (e.g. nightly kicks)
- **Dual MAC authorization** — logs in through both radio interfaces so both are authorized on MikroTik simultaneously
- **Credential fallback** — tries primary credentials first, falls back to secondary if rejected (e.g. max users reached)
- **AdGuard Home aware** — keeps AdGuard running during failover when the backup interface is already active
- **Captive portal detection** — detects when the upstream router serves a trap IP and handles it gracefully

## Hardware tested

Xiaomi Mi Router 4 (MiR4) running OpenWrt, with:
- `radio1` (5GHz, phy1-sta0) as primary WAN — `wwan`
- `radio0` (2.4GHz, phy0-sta0) as backup WAN — `wwan2`
- MikroTik-based upstream hotspot system

## Dependencies

Install on your OpenWrt router:

```sh
opkg update
opkg install mwan3 luci-app-mwan3
```

Also required (usually pre-installed):
- `curl`
- `iwinfo`
- `ip` (from `ip-full` or `iproute2`)

## File structure

```
mwaf/
├── README.md
├── root/
│   ├── safe_wwan_monitor.sh      → main monitor daemon
│   ├── mikrotik_login.sh         → MikroTik captive portal login
│   └── wwan_redbutton.sh         → emergency stop script
└── etc/
    ├── init.d/
    │   └── wwan-safe             → procd init script (autostart)
    └── hotplug.d/
        └── iface/
            └── 25-mwan3-mainroute → fixes main routing table on failover
```

## Installation

### 1. Set up two wireless STA interfaces in OpenWrt

In LuCI → **Network → Wireless**, scan and join your upstream SSIDs:

- On `radio1` (5GHz) → join your primary SSID → network name: `wwan`
- On `radio0` (2.4GHz) → join your backup SSID → network name: `wwan2`

Both should use **DHCP client** protocol. Verify both appear in **Network → Interfaces** with valid IPs.

### 2. Configure mwan3

In LuCI → **Network → Load Balancing**:

**Interfaces tab** — add two interfaces:

| Setting | wwan | wwan2 |
|---|---|---|
| Enabled | ✅ | ✅ |
| Track IPs | 8.8.8.8, 1.1.1.1 | 8.8.8.8, 1.1.1.1 |
| Tracking method | ping | ping |
| Down | 3 | 3 |
| Up | 5 | 5 |
| Interval | 5 | 5 |
| Timeout | 2 | 2 |

**Members tab** — add two members:

| Member | Interface | Metric | Weight |
|---|---|---|---|
| wwan_m1 | wwan | 1 | 1 |
| wwan2_m2 | wwan2 | 2 | 1 |

**Policies tab** — add a policy named `failover`:
- Add `wwan_m1` and `wwan2_m2`
- Last resort: `unreachable`

**Rules tab** — add a rule:
- Destination: `0.0.0.0/0`
- Policy: `failover`
- Family: `IPv4`

Make sure the `failover` rule is at the **top** of the rules list (above any pre-existing rules like `balanced`).

### 3. Assign both interfaces to the WAN firewall zone

In LuCI → **Network → Firewall → Zones** → edit the `wan` zone → make sure both `wwan` and `wwan2` are listed under Covered Networks.

### 4. Install the hotplug script

```sh
scp etc/hotplug.d/iface/25-mwan3-mainroute root@192.168.1.1:/etc/hotplug.d/iface/25-mwan3-mainroute
chmod +x /etc/hotplug.d/iface/25-mwan3-mainroute
```

### 5. Configure and install the scripts

Edit `root/mikrotik_login.sh` and set your credentials and login URL:

```sh
LOGIN_URL="http://192.168.10.1/login"   # your MikroTik login page URL

# Credentials tried in order — first accepted wins
for CREDS in "username1:password1" "username2:password2"; do
```

Edit `root/safe_wwan_monitor.sh` and update the configuration section:

```sh
# Network prefixes — adjust to match your upstream subnet
TRAP_PREFIX="192.168.0."     # IP range that indicates captive portal trap
VALID_PREFIX="192.168.10."   # IP range that indicates real internet

# Interface names — check yours with: ip link show
WWAN_IFACE="phy1-sta0"       # primary radio interface
WWAN2_IFACE="phy0-sta0"      # backup radio interface

# SSID fallback — wwan switches to FALLBACK_SSID after repeated login failures
PRIMARY_SSID="your_primary_ssid"
FALLBACK_SSID="your_fallback_ssid"
FALLBACK_PASSWORD=""          # leave empty if open network, otherwise set password
```

Copy scripts to the router:

```sh
scp root/safe_wwan_monitor.sh root@192.168.1.1:/root/safe_wwan_monitor.sh
scp root/mikrotik_login.sh root@192.168.1.1:/root/mikrotik_login.sh
scp root/wwan_redbutton.sh root@192.168.1.1:/root/wwan_redbutton.sh
scp etc/init.d/wwan-safe root@192.168.1.1:/etc/init.d/wwan-safe

chmod +x /root/safe_wwan_monitor.sh
chmod +x /root/mikrotik_login.sh
chmod +x /root/wwan_redbutton.sh
chmod +x /etc/init.d/wwan-safe
```

### 6. Enable and start

```sh
/etc/init.d/wwan-safe enable
/etc/init.d/wwan-safe start
```

Verify it's running:

```sh
logread | grep wwan-safe
```

You should see:
```
wwan-safe: SERVICE STARTING: Safe WWAN Monitor v2.7 initializing
wwan-safe: State loaded: attempts=0 last_login=0 state=unknown cycles=0 fallback=0
```

## How it works

### Failover routing

mwan3 handles policy-based routing — when wwan fails its ping checks, it marks the interface offline and routes all forwarded traffic through wwan2. However, mwan3 does not update the router's **main routing table**, which is used by local processes like AdGuard Home for DNS.

The `25-mwan3-mainroute` hotplug script fixes this. It fires on every `ifup`/`ifdown` event for wwan and updates the main table default route to point to whichever interface is currently active. A `sleep 3` delay ensures mwan3 has finished writing its own routing tables before the script reads them. The `25` prefix ensures it runs after mwan3's own hotplug script (`15-mwan3`).

### MikroTik login

`mikrotik_login.sh` handles the MikroTik challenge-response authentication:

1. Fetches the login page to extract the salt values
2. Computes `MD5(salt_prefix + password + salt_suffix)`
3. POSTs the username and hash to the login endpoint
4. Tries credentials in order — if the first set is rejected it automatically tries the next

When called with an interface argument (e.g. `mikrotik_login.sh phy1-sta0`), curl binds the request to that specific interface using `--interface`. This causes MikroTik to see the request coming from that interface's IP, look up its MAC in the ARP table, and authorize that specific MAC — allowing both radios to be authorized independently without disconnecting either one.

### Recovery monitor

`safe_wwan_monitor.sh` runs as a daemon and watches for internet loss. When detected:

1. Checks if wwan landed on a captive portal IP (trap detection)
2. Attempts MikroTik login
3. Waits for internet to come back in retry cycles rather than a fixed delay
4. Once internet is confirmed, fires dual login for both radio interfaces
5. If login keeps failing after multiple cooldown cycles, switches wwan to a fallback SSID

## Configuration reference

### safe_wwan_monitor.sh

| Variable | Default | Description |
|---|---|---|
| `MAX_LOGIN_ATTEMPTS` | 3 | Login attempts before entering cooldown |
| `ATTEMPT_INTERVAL` | 60 | Seconds between login attempts |
| `COOLDOWN_PERIOD` | 300 | Seconds to wait after max attempts |
| `TRAP_PREFIX` | 192.168.0. | IP prefix that indicates captive portal |
| `VALID_PREFIX` | 192.168.10. | IP prefix that indicates real internet |
| `WWAN_IFACE` | phy1-sta0 | Primary radio interface name |
| `WWAN2_IFACE` | phy0-sta0 | Backup radio interface name |
| `PRIMARY_SSID` | — | SSID wwan connects to normally |
| `FALLBACK_SSID` | — | SSID wwan switches to after repeated failures |
| `MAX_COOLDOWN_CYCLES` | 3 | Cooldown cycles before switching SSID |
| `POST_LOGIN_RETRIES` | 5 | Internet check retries per cycle after login |
| `POST_LOGIN_RETRY_GAP` | 6 | Seconds between retries |
| `POST_LOGIN_CYCLE_WAIT` | 20 | Seconds between retry cycles |
| `POST_LOGIN_MAX_CYCLES` | 3 | Cycles before giving up and observing passively |

### mikrotik_login.sh

| Variable | Description |
|---|---|
| `LOGIN_URL` | Full URL to your MikroTik login endpoint |
| `CREDS` loop | Credential pairs in `username:password` format, tried in order |

## Emergency stop

If the monitor is causing issues:

```sh
/root/wwan_redbutton.sh
```

This stops the service, disables autostart, and clears all state files.

## Monitoring

Watch live:
```sh
logread -f | grep -E "wwan-safe|wwan-login|mwan3-mainroute"
```

Check failover status:
```sh
mwan3 status
```

Check routing tables:
```sh
ip route show table main
ip route show table 1   # wwan routes
ip route show table 2   # wwan2 routes
```

## Notes

- Interface names (`phy1-sta0`, `phy0-sta0`) may differ on your hardware. Check with `ip link show` or `iwinfo` after connecting the STAs.
- mwan3's policy routing only applies to forwarded traffic (LAN clients). The router's own traffic uses the main table — which is why the hotplug script is needed for AdGuard and other local processes.
- MikroTik authorizes by MAC address. Each radio has a different MAC, so both need to be logged in separately for full coverage.
- The `TRAP_PREFIX` and `VALID_PREFIX` values are specific to your network. Check what IP your router gets when it hits the captive portal to determine the correct trap prefix.