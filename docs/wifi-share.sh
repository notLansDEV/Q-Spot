#!/usr/bin/env bash
# LEGACY / UNUSED FOR THE CURRENT Q-SPOT SETUP
# This script creates the old "Manjaro-Share" hotspot on the NetworkManager
# interface ap0 (ipv4.method shared). The current Q-Spot hotspot is created by
# q-spot.sh using the dedicated qspot0 interface + hostapd + dnsmasq and is
# voucher-gated. Do not use this script while the Q-Spot portal is running.
set -Eeuo pipefail

UPLINK="wlo1"
HOTSPOT="ap0"
NETWORK="Manjaro-Share"
SUBNET="10.42.0.0/24"
TTL_TABLE="hotspot_ttl_test"

# Prevent simultaneous script executions
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/wifi-share.lock"
flock -n 9 || {
    echo "Wi-Fi sharing script is already running."
    exit 1
}

start_share() {
    echo "=== Starting Wi-Fi Sharing ==="
    sudo -v

    # Check upstream connection
    if ! nmcli -t -f DEVICE,STATE device status |
         grep -Fxq "$UPLINK:connected"; then
        echo "ERROR: Connect to café Wi-Fi first."
        exit 1
    fi

    # Get upstream channel
    CHANNEL=$(iw dev "$UPLINK" info |
        awk '$1 == "channel" {print $2; exit}')

    if [[ -z "$CHANNEL" ]]; then
        echo "ERROR: Cannot determine Wi-Fi channel."
        exit 1
    fi

    if (( CHANNEL <= 14 )); then
        BAND="bg"
    else
        BAND="a"
    fi

    # Disable automatic activation.
    # The script itself will activate the hotspot.
    sudo nmcli connection modify "$NETWORK" \
        connection.autoconnect no \
        connection.interface-name "$HOTSPOT" \
        wifi.mode ap \
        wifi.band "$BAND" \
        wifi.channel "$CHANNEL" \
        ipv4.method shared \
        ipv4.addresses 10.42.0.1/24 \
        ipv6.method disabled

    # Don't restart an already working hotspot
    ACTIVE=$(nmcli -g GENERAL.CONNECTION \
        device show "$HOTSPOT" 2>/dev/null || true)

    if [[ "$ACTIVE" != "$NETWORK" ]]; then

        sudo nmcli connection down "$NETWORK" 2>/dev/null || true

        # Release and remove a broken virtual interface
        if iw dev "$HOTSPOT" info >/dev/null 2>&1; then
            sudo nmcli device set "$HOTSPOT" managed no || true
            sudo ip link set "$HOTSPOT" down || true
            sudo iw dev "$HOTSPOT" del
        fi

        # Create a fresh virtual AP interface
        echo "Creating $HOTSPOT..."
        sudo iw dev "$UPLINK" interface add "$HOTSPOT" type __ap

        sudo ip link set "$HOTSPOT" up

        # Give NetworkManager control
        sudo nmcli device set "$HOTSPOT" managed yes

        # Wait until NetworkManager reports disconnected/ready
        echo "Waiting for NetworkManager..."

        READY=0

        for i in {1..30}; do
            STATE=$(nmcli -g GENERAL.STATE \
                device show "$HOTSPOT" 2>/dev/null || true)

            if [[ "$STATE" == 30* ]]; then
                READY=1
                break
            fi

            sleep 1
        done

        if [[ "$READY" != 1 ]]; then
            echo "ERROR: $HOTSPOT did not become ready."
            nmcli -f GENERAL.STATE,GENERAL.REASON,GENERAL.NM-MANAGED \
                device show "$HOTSPOT" || true
            exit 1
        fi

        # Activate exactly once
        echo "Activating hotspot..."

        sudo nmcli --wait 30 connection up \
            id "$NETWORK" ifname "$HOTSPOT"
    else
        echo "Hotspot is already active. Keeping it running."
    fi

    # Enable IPv4 forwarding
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Remove duplicate rules, then install one copy
    ensure_rule() {
        local CHAIN="$1"
        shift

        while sudo iptables -C "$CHAIN" "$@" 2>/dev/null; do
            sudo iptables -D "$CHAIN" "$@"
        done

        sudo iptables -I "$CHAIN" 1 "$@"
    }

    # Android -> café Wi-Fi
    ensure_rule FORWARD \
        -i "$HOTSPOT" -o "$UPLINK" \
        -s "$SUBNET" -j ACCEPT

    # Café Wi-Fi -> Android (return traffic)
    ensure_rule FORWARD \
        -i "$UPLINK" -o "$HOTSPOT" \
        -d "$SUBNET" \
        -m conntrack --ctstate ESTABLISHED,RELATED \
        -j ACCEPT

    # Restore the tested TTL adjustment
    sudo nft delete table inet "$TTL_TABLE" 2>/dev/null || true
    sudo nft add table inet "$TTL_TABLE"

    sudo nft 'add chain inet hotspot_ttl_test prerouting { type filter hook prerouting priority mangle; policy accept; }'

    sudo nft add rule inet "$TTL_TABLE" prerouting \
        iifname "$UPLINK" \
        ct direction reply \
        ct original ip saddr "$SUBNET" \
        ip protocol tcp \
        counter ip ttl set 64

    echo ""
    echo "================================="
    echo " Wi-Fi sharing is enabled!"
    echo " SSID: Manjaro-Share"
    echo " Interface: ap0"
    echo " IP: 10.42.0.1"
    echo "================================="
    echo "Connect your Android phone."
}

stop_share() {
    echo "Stopping hotspot..."

    sudo nmcli connection down "$NETWORK" 2>/dev/null || true
    sudo nft delete table inet "$TTL_TABLE" 2>/dev/null || true

    echo "Hotspot stopped."
}

show_status() {
    nmcli device status
    echo ""
    sudo nft list table inet "$TTL_TABLE" 2>/dev/null ||
        echo "TTL adjustment is not active."
}

case "${1:-start}" in
    start)  start_share ;;
    stop)   stop_share ;;
    status) show_status ;;
    *)
        echo "Usage: $0 {start|stop|status}"
        exit 1
        ;;
esac
