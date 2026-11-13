#!/usr/bin/env bash
# Q-Spot: open Wi-Fi + voucher-controlled captive portal for Manjaro/NetworkManager.
# Keeps the existing app/server.py, qspot-manager.py, and config.env.
# Wi-Fi is OPEN; internet forwarding remains blocked until the portal authorizes a client IP.

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
APP_FILE="$SCRIPT_DIR/app/server.py"
MANAGER_FILE="$SCRIPT_DIR/qspot-manager.py"
DATA_DIR="$SCRIPT_DIR/data"
RUNTIME_DIR="/run/q-spot"

# -----------------------------------------------------------------------------
# Root and configuration
# -----------------------------------------------------------------------------
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    exec sudo -E bash "$SCRIPT_DIR/$(basename -- "${BASH_SOURCE[0]}")" "${@:-start}"
fi

setup_config() {
    local detected uplink ssid admin_user admin_pass entered
    local interactive=0

    detected="$(ip route show default 2>/dev/null | awk 'NR==1 {print $5}')"
    if [[ -z "$detected" ]] && command -v nmcli >/dev/null 2>&1; then
        detected="$(nmcli -t -f DEVICE,TYPE device status 2>/dev/null | awk -F: '$2=="wifi"{print $1; exit}')"
    fi
    [[ -t 0 ]] && interactive=1

    printf 'Q-Spot first-time setup\n'
    if (( interactive )); then
        read -r -p "Internet uplink interface [${detected:-wlo1}]: " uplink || uplink=""
    fi
    uplink="${uplink:-${detected:-wlo1}}"

    if (( interactive )); then
        read -r -p "Wi-Fi hotspot name [Q-Spot]: " ssid || ssid=""
    fi
    ssid="${ssid:-Q-Spot}"

    if (( interactive )); then
        read -r -p "Admin username [admin]: " admin_user || admin_user=""
    fi
    admin_user="${admin_user:-admin}"

    admin_pass="$(LC_ALL=C tr -dc 'A-HJ-NP-Za-hj-np-z2-9' </dev/urandom | head -c 8 || true)"
    if (( interactive )); then
        read -r -p "Admin password [${admin_pass}]: " entered || entered=""
    fi
    admin_pass="${entered:-$admin_pass}"

    cat > "$CONFIG_FILE" <<EOF
UPLINK=$(printf '%q' "$uplink")
SSID=$(printf '%q' "$ssid")
ADMIN_USER=$(printf '%q' "$admin_user")
ADMIN_PASS=$(printf '%q' "$admin_pass")
AP_IFACE=qspot0
PORTAL_PORT=8081
GATEWAY_IP=10.42.0.1
EOF
    chmod 600 "$CONFIG_FILE"

    printf '\nAdmin login: %s / %s\n' "$admin_user" "$admin_pass"
    printf 'Saved in %s (keep it private).\n\n' "$CONFIG_FILE"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
    setup_config
fi

# config.env is a trusted shell-style configuration file. Quote values with
# spaces, e.g. SSID="Q-Spot Hotspot" or SSID=Q-Spot\ Hotspot.
set -a
# shellcheck disable=SC1090
source "$CONFIG_FILE"
set +a
cd "$SCRIPT_DIR"

UPLINK="${UPLINK:-wlo1}"
SSID="${SSID:-Q-Spot Hotspot}"
AP_IFACE="${AP_IFACE:-qspot0}"
GATEWAY_IP="${GATEWAY_IP:-10.42.0.1}"
PORTAL_PORT="${PORTAL_PORT:-8081}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-}"
COUNTRY_CODE="${COUNTRY_CODE:-PH}"
DHCP_LEASE_TIME="${DHCP_LEASE_TIME:-12h}"

# WIFI_PASS is intentionally NOT used. Q-Spot is an open Wi-Fi network;
# the voucher portal controls internet access instead of a Wi-Fi password.
WIFI_PASS="${WIFI_PASS:-}"

HOSTAPD_CONF="$RUNTIME_DIR/hostapd.conf"
DNSMASQ_CONF="$RUNTIME_DIR/dnsmasq.conf"
HOSTAPD_PID="$RUNTIME_DIR/hostapd.pid"
DNSMASQ_PID="$RUNTIME_DIR/dnsmasq.pid"
PORTAL_PID="$RUNTIME_DIR/portal.pid"
HOSTAPD_LOG="$DATA_DIR/hostapd.log"
DNSMASQ_LOG="$DATA_DIR/dnsmasq.log"
PORTAL_LOG="$DATA_DIR/portal.log"
FORWARD_STATE="$RUNTIME_DIR/ip_forward.before"

FILTER_INPUT_CHAIN="QSPOT_INPUT"
FILTER_FORWARD_CHAIN="QSPOT_FORWARD"

mkdir -p "$DATA_DIR" "$RUNTIME_DIR"
chmod 700 "$RUNTIME_DIR"
touch "$HOSTAPD_LOG" "$DNSMASQ_LOG" "$PORTAL_LOG"
chmod 600 "$HOSTAPD_LOG" "$DNSMASQ_LOG" "$PORTAL_LOG"

STARTUP_IN_PROGRESS=0

# Ensure the portal and manager receive the same settings as the shell script.
export UPLINK SSID AP_IFACE GATEWAY_IP PORTAL_PORT ADMIN_USER ADMIN_PASS

# Derive the /24 pool from the configured gateway address.
if [[ ! "$GATEWAY_IP" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
    printf 'ERROR: GATEWAY_IP must be an IPv4 address. Got: %s\n' "$GATEWAY_IP" >&2
    exit 1
fi
OCTET1="${BASH_REMATCH[1]}"
OCTET2="${BASH_REMATCH[2]}"
OCTET3="${BASH_REMATCH[3]}"
OCTET4="${BASH_REMATCH[4]}"
for octet in "$OCTET1" "$OCTET2" "$OCTET3" "$OCTET4"; do
    if (( 10#$octet > 255 )); then
        printf 'ERROR: Invalid GATEWAY_IP: %s\n' "$GATEWAY_IP" >&2
        exit 1
    fi
done
SUBNET="${OCTET1}.${OCTET2}.${OCTET3}.0/24"
DHCP_START="${DHCP_START:-${OCTET1}.${OCTET2}.${OCTET3}.20}"
DHCP_END="${DHCP_END:-${OCTET1}.${OCTET2}.${OCTET3}.250}"

if [[ ! "$PORTAL_PORT" =~ ^[0-9]+$ ]] || (( PORTAL_PORT < 1 || PORTAL_PORT > 65535 )); then
    printf 'ERROR: PORTAL_PORT must be between 1 and 65535.\n' >&2
    exit 1
fi
SSID_BYTES="$(LC_ALL=C printf '%s' "$SSID" | wc -c | tr -d '[:space:]')"
if (( SSID_BYTES < 1 || SSID_BYTES > 32 )) || [[ "$SSID" == *$'\n'* || "$SSID" == *$'\r'* ]]; then
    printf 'ERROR: SSID must contain 1–32 bytes and no line breaks.\n' >&2
    exit 1
fi

# Prefer a project virtual environment when present.
if [[ -x "$SCRIPT_DIR/.venv/bin/python" ]]; then
    PYTHON_BIN="$SCRIPT_DIR/.venv/bin/python"
else
    PYTHON_BIN="$(command -v python3 || true)"
fi
if [[ -z "$PYTHON_BIN" ]]; then
    printf 'ERROR: python3 is not installed.\n' >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Utilities
# -----------------------------------------------------------------------------
log() { printf '[Q-Spot] %s\n' "$*"; }
warn() { printf '[Q-Spot] WARNING: %s\n' "$*" >&2; }
die() { printf '[Q-Spot] ERROR: %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

install_dependencies() {
    local -a missing_packages=()
    local binary package
    local -A package_for=(
        [hostapd]=hostapd
        [dnsmasq]=dnsmasq
        [iw]=iw
        [ip]=iproute2
        [iptables]=iptables
        [nmcli]=networkmanager
        [sysctl]=procps-ng
        [conntrack]=conntrack-tools
        [qrencode]=qrencode
        [zbarimg]=zbar
        [python3]=python
        [flock]=util-linux
        [ss]=iproute2
    )

    for binary in "${!package_for[@]}"; do
        if ! have "$binary"; then
            package="${package_for[$binary]}"
            local already=0 existing
            for existing in "${missing_packages[@]:-}"; do
                [[ "$existing" == "$package" ]] && already=1
            done
            (( already == 1 )) || missing_packages+=("$package")
        fi
    done

    if ((${#missing_packages[@]})); then
        if ! have pacman; then
            die "Missing dependencies (${missing_packages[*]}) and pacman is unavailable."
        fi
        log "Installing required packages: ${missing_packages[*]}"
        pacman -S --needed --noconfirm "${missing_packages[@]}" || die "Dependency installation failed."
    fi

    for binary in hostapd dnsmasq iw ip iptables nmcli sysctl python3 flock ss; do
        have "$binary" || die "Required command is still missing: $binary"
    done

    [[ -f "$APP_FILE" ]] || die "Portal application not found: $APP_FILE"
    [[ -f "$MANAGER_FILE" ]] || warn "Voucher manager not found: $MANAGER_FILE (portal can still run)."
}

iptables_cmd() { iptables -w 5 "$@"; }

# Delete all identical copies of a rule from a chain.
delete_rule_all() {
    local table="$1" chain="$2"
    shift 2
    while iptables -w 5 -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -w 5 -t "$table" -D "$chain" "$@" || break
    done
}

# Remove per-client portal bypass rules left by the running portal.
remove_client_bypasses() {
    local rule
    while IFS= read -r rule; do
        [[ "$rule" == "-A PREROUTING"*"qspot-client"* ]] || continue
        # shellcheck disable=SC2086
        iptables -w 5 -t nat ${rule/-A /-D } || true
    done < <(iptables -w 5 -t nat -S PREROUTING 2>/dev/null || true)
}

# Install exactly one copy of a rule at the beginning of a chain.
ensure_rule_first() {
    local table="$1" chain="$2"
    shift 2
    delete_rule_all "$table" "$chain" "$@"
    iptables -w 5 -t "$table" -I "$chain" 1 "$@"
}

process_from_pidfile() {
    local pidfile="$1" match="$2" pid cmd i
    [[ -s "$pidfile" ]] || return 1
    read -r pid < "$pidfile" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || { rm -f "$pidfile"; return 1; }
    [[ -r "/proc/$pid/cmdline" ]] || { rm -f "$pidfile"; return 1; }
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    if [[ "$cmd" != *"$match"* ]]; then
        rm -f "$pidfile"
        return 1
    fi
    printf '%s' "$pid"
}

start_daemon() {
    local pidfile="$1" logfile="$2" match="$3"
    shift 3
    local existing
    existing="$(process_from_pidfile "$pidfile" "$match" || true)"
    if [[ -n "$existing" ]]; then
        log "$match is already running (PID $existing)."
        return 0
    fi

    log "Starting $match..."
    # Daemons must not inherit the operation lock (fd 9), or they will keep it
    # held for their entire lifetime and block future start/stop/restart calls.
    nohup "$@" >> "$logfile" 2>&1 </dev/null 9>&- &
    local pid=$!
    printf '%s\n' "$pid" > "$pidfile"
    sleep 1
    if ! kill -0 "$pid" 2>/dev/null; then
        rm -f "$pidfile"
        warn "$match failed to start. Last log lines:"
        tail -n 40 "$logfile" 2>/dev/null || true
        return 1
    fi
    return 0
}

stop_daemon() {
    local pidfile="$1" match="$2" pid i cmd
    pid="$(process_from_pidfile "$pidfile" "$match" || true)"
    if [[ -n "$pid" ]]; then
        log "Stopping $match (PID $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        for ((i=0; i<30; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
            cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
            if [[ "$cmd" == *"$match"* ]]; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    fi
    rm -f "$pidfile"
}

# Kill Q-Spot daemons left behind when /run/q-spot was removed or the pidfiles
# were lost. Without this, the old portal keeps serving stale code and blocks
# the configured port on the next start.
stop_orphaned_daemon() {
    local pidfile="$1" match="$2" pid i
    if process_from_pidfile "$pidfile" "$match" >/dev/null 2>&1; then
        return 0
    fi
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        log "Stopping orphaned $match (PID $pid)..."
        kill -TERM "$pid" 2>/dev/null || true
        for ((i=0; i<30; i++)); do
            kill -0 "$pid" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
    done < <(pgrep -f -- "$match" 2>/dev/null || true)
    return 0
}

stop_orphaned_daemons() {
    stop_orphaned_daemon "$PORTAL_PID" "$APP_FILE"
    stop_orphaned_daemon "$DNSMASQ_PID" "--conf-file=$DNSMASQ_CONF"
    stop_orphaned_daemon "$HOSTAPD_PID" "$HOSTAPD_CONF"
}

# -----------------------------------------------------------------------------
# Wi-Fi interface and channel
# -----------------------------------------------------------------------------
get_uplink_channel() {
    local channel freq

    channel="$(iw dev "$UPLINK" info 2>/dev/null | awk '$1 == "channel" { print $2; exit }')"
    if [[ "$channel" =~ ^[0-9]+$ ]]; then
        HOTSPOT_CHANNEL="$channel"
    else
        # iw link often reports decimal frequencies, e.g. 2437.0; round to integer.
        freq="$(iw dev "$UPLINK" link 2>/dev/null | awk '/freq:/ { printf "%.0f\n", $2; exit }')"
        [[ "$freq" =~ ^[0-9]+$ ]] || die "Cannot determine the channel/frequency of $UPLINK."
        if (( freq == 2484 )); then
            HOTSPOT_CHANNEL=14
        elif (( freq >= 2412 && freq <= 2472 )); then
            HOTSPOT_CHANNEL=$(( (freq - 2407) / 5 ))
        elif (( freq >= 5000 && freq <= 5900 )); then
            HOTSPOT_CHANNEL=$(( (freq - 5000) / 5 ))
        elif (( freq >= 5955 && freq <= 7115 )); then
            HOTSPOT_CHANNEL=$(( (freq - 5950) / 5 ))
        else
            die "Unsupported Wi-Fi frequency: ${freq} MHz"
        fi
    fi

    if (( HOTSPOT_CHANNEL <= 14 )); then
        HOSTAPD_HW_MODE="g"
        # Do not use a bare arithmetic && at the end of this function:
        # with `set -e`, channel 6 would make the function return status 1.
        if (( HOTSPOT_CHANNEL == 14 )); then
            HOSTAPD_HW_MODE="b"
        fi
    else
        HOSTAPD_HW_MODE="a"
    fi

    # A successful channel lookup must always return success.
    return 0
}

check_uplink() {
    iw dev "$UPLINK" info >/dev/null 2>&1 || die "Uplink interface $UPLINK does not exist."
    if ! iw dev "$UPLINK" link 2>/dev/null | grep -q '^Connected to '; then
        die "$UPLINK is not connected to a Wi-Fi network. Connect to the café Wi-Fi first."
    fi
}

create_or_prepare_ap_interface() {
    local info mode

    log "Preparing virtual AP interface $AP_IFACE..."
    if ! iw dev "$AP_IFACE" info >/dev/null 2>&1; then
        # Some drivers/NetworkManager combinations immediately register the new
        # netdev as managed. We release it from NM and explicitly switch its type.
        if ! iw dev "$UPLINK" interface add "$AP_IFACE" type __ap; then
            # A race can create the interface even when the command reports an error.
            iw dev "$AP_IFACE" info >/dev/null 2>&1 || die "Could not create $AP_IFACE. Check iw/driver logs."
        fi
    fi

    # This ordering is important on this Manjaro adapter: mark unmanaged first,
    # then bring it down, then explicitly set AP mode.
    if have nmcli; then
        nmcli device set "$AP_IFACE" managed no >/dev/null 2>&1 || \
            warn "NetworkManager did not confirm unmanaged state for $AP_IFACE; continuing with explicit AP-mode check."
    fi
    sleep 0.3
    ip link set "$AP_IFACE" down 2>/dev/null || true

    info="$(iw dev "$AP_IFACE" info 2>/dev/null || true)"
    mode="$(awk '$1 == "type" { print $2; exit }' <<< "$info")"
    if [[ "$mode" != "AP" ]]; then
        iw dev "$AP_IFACE" set type __ap || die "Could not switch $AP_IFACE to AP mode. Current mode: ${mode:-unknown}"
    fi

    info="$(iw dev "$AP_IFACE" info 2>/dev/null || true)"
    grep -Eq '^[[:space:]]*type AP$' <<< "$info" || die "$AP_IFACE is not in AP mode after configuration."

    ip -4 addr flush dev "$AP_IFACE" 2>/dev/null || true
    ip addr replace "${GATEWAY_IP}/24" dev "$AP_IFACE"
    ip link set "$AP_IFACE" up

    log "$AP_IFACE is ready in AP mode at ${GATEWAY_IP}/24."
}

write_hostapd_config() {
    local ssid_hex
    ssid_hex="$(printf '%s' "$SSID" | od -An -tx1 | tr -d ' \n')"
    mkdir -p /run/hostapd

    cat > "$HOSTAPD_CONF" <<EOF2
# Q-Spot open Wi-Fi configuration. Voucher authentication is handled by the portal.
interface=$AP_IFACE
driver=nl80211
ssid2=$ssid_hex
country_code=$COUNTRY_CODE
ieee80211d=1
hw_mode=$HOSTAPD_HW_MODE
channel=$HOTSPOT_CHANNEL
ieee80211n=1
wmm_enabled=1
auth_algs=1
wpa=0
ignore_broadcast_ssid=0
beacon_int=100
dtim_period=2
max_num_sta=100
ctrl_interface=/run/hostapd
ctrl_interface_group=0
EOF2
    chmod 600 "$HOSTAPD_CONF"
}

write_dnsmasq_config() {
    cat > "$DNSMASQ_CONF" <<EOF2
# Q-Spot DHCP and DNS. Clients use the laptop as their DNS resolver.
interface=$AP_IFACE
bind-dynamic
listen-address=$GATEWAY_IP
port=53
no-hosts
domain-needed
bogus-priv
no-negcache
cache-size=1000
dhcp-authoritative
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,$DHCP_LEASE_TIME
dhcp-option=option:router,$GATEWAY_IP
dhcp-option=option:dns-server,$GATEWAY_IP
dhcp-leasefile=$DATA_DIR/dnsmasq.leases
log-dhcp
EOF2
    chmod 600 "$DNSMASQ_CONF"
}

# -----------------------------------------------------------------------------
# Firewall: DNS/DHCP/portal allowed locally; forwarding denied until voucher.
# -----------------------------------------------------------------------------
setup_firewall() {
    log "Configuring voucher-gated firewall..."
    remove_client_bypasses

    iptables -w 5 -N "$FILTER_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -N "$FILTER_FORWARD_CHAIN" 2>/dev/null || true

    # INPUT chain: only DHCP, DNS, portal HTTP and ping are reachable from clients.
    iptables -w 5 -F "$FILTER_INPUT_CHAIN"
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -p udp --dport 67 -j ACCEPT
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -p udp --dport 53 -j ACCEPT
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -p tcp --dport 53 -j ACCEPT
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -p tcp --dport "$PORTAL_PORT" -j ACCEPT
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -p icmp --icmp-type echo-request -j ACCEPT
    iptables -w 5 -A "$FILTER_INPUT_CHAIN" -j DROP

    # Preserve voucher ACCEPT rules if the script is started again without a
    # clean stop. Rebuild only the common state rule and final catch-all DROP.
    while iptables -w 5 -C "$FILTER_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null; do
        iptables -w 5 -D "$FILTER_FORWARD_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    done
    while iptables -w 5 -C "$FILTER_FORWARD_CHAIN" -j DROP 2>/dev/null; do
        iptables -w 5 -D "$FILTER_FORWARD_CHAIN" -j DROP
    done
    iptables -w 5 -I "$FILTER_FORWARD_CHAIN" 1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -w 5 -A "$FILTER_FORWARD_CHAIN" -j DROP

    # One jump from AP -> uplink enters the voucher gate.
    ensure_rule_first filter FORWARD -i "$AP_IFACE" -o "$UPLINK" -j "$FILTER_FORWARD_CHAIN"

    # Permit only return traffic from the uplink back to the AP subnet.
    ensure_rule_first filter FORWARD -i "$UPLINK" -o "$AP_IFACE" -d "$SUBNET" -j ACCEPT

    # Let clients reach the local DHCP/DNS/portal services.
    ensure_rule_first filter INPUT -i "$AP_IFACE" -j "$FILTER_INPUT_CHAIN"

    # Redirect ordinary HTTP requests to the captive portal. HTTPS is not
    # intercepted; devices use their OS captive-portal detection mechanism.
    ensure_rule_first nat PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$PORTAL_PORT"

    # NAT only applies to traffic that passes the voucher-gated FORWARD chain.
    ensure_rule_first nat POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE

    # Some shared uplinks (the café AP here) rewrite the TTL of every reply to
    # 1 to block connection sharing. Locally delivered packets ignore TTL, so
    # the host still works, but forwarded replies are dropped by the kernel's
    # forward TTL check before they ever reach a guest. Restore a normal TTL on
    # the way in, and normalize it on the way out so forwarded traffic looks
    # identical to the host's own traffic.
    ensure_rule_first mangle PREROUTING -i "$UPLINK" -d "$SUBNET" -j TTL --ttl-set 64
    ensure_rule_first mangle POSTROUTING -s "$SUBNET" -o "$UPLINK" -j TTL --ttl-set 64
}

remove_firewall() {
    log "Removing Q-Spot firewall rules..."
    remove_client_bypasses
    delete_rule_all filter INPUT -i "$AP_IFACE" -j "$FILTER_INPUT_CHAIN"
    delete_rule_all filter FORWARD -i "$AP_IFACE" -o "$UPLINK" -j "$FILTER_FORWARD_CHAIN"
    delete_rule_all filter FORWARD -i "$UPLINK" -o "$AP_IFACE" -d "$SUBNET" \
        -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    delete_rule_all nat PREROUTING -i "$AP_IFACE" -p tcp --dport 80 -j REDIRECT --to-ports "$PORTAL_PORT"
    delete_rule_all nat POSTROUTING -s "$SUBNET" -o "$UPLINK" -j MASQUERADE
    delete_rule_all mangle PREROUTING -i "$UPLINK" -d "$SUBNET" -j TTL --ttl-set 64
    delete_rule_all mangle POSTROUTING -s "$SUBNET" -o "$UPLINK" -j TTL --ttl-set 64

    iptables -w 5 -F "$FILTER_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$FILTER_INPUT_CHAIN" 2>/dev/null || true
    iptables -w 5 -F "$FILTER_FORWARD_CHAIN" 2>/dev/null || true
    iptables -w 5 -X "$FILTER_FORWARD_CHAIN" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# Start / stop / status
# -----------------------------------------------------------------------------
save_forwarding_state() {
    if [[ ! -f "$FORWARD_STATE" ]]; then
        cat /proc/sys/net/ipv4/ip_forward > "$FORWARD_STATE"
        chmod 600 "$FORWARD_STATE"
    fi
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

restore_forwarding_state() {
    if [[ -r "$FORWARD_STATE" ]]; then
        local previous
        read -r previous < "$FORWARD_STATE" || previous=0
        [[ "$previous" == 0 || "$previous" == 1 ]] || previous=0
        sysctl -w "net.ipv4.ip_forward=$previous" >/dev/null 2>&1 || true
        rm -f "$FORWARD_STATE"
    fi
}

start_qspot() {
    log "Checking Q-Spot dependencies..."
    install_dependencies
    check_uplink
    get_uplink_channel

    log "Starting Q-Spot..."
    stop_orphaned_daemons
    log "Uplink: $UPLINK"
    log "SSID: $SSID (open Wi-Fi; no Wi-Fi password)"
    log "Uplink channel: $HOTSPOT_CHANNEL"
    log "Hotspot channel: $HOTSPOT_CHANNEL"

    save_forwarding_state
    create_or_prepare_ap_interface
    write_hostapd_config
    write_dnsmasq_config
    setup_firewall

    # Portal is started before hostapd, so the login page is ready as soon as
    # clients begin associating with the access point.
    if ss -H -ltn "sport = :$PORTAL_PORT" 2>/dev/null | grep -q .; then
        if ! process_from_pidfile "$PORTAL_PID" "server.py" >/dev/null 2>&1; then
            die "TCP port $PORTAL_PORT is already occupied by another process."
        fi
    fi

    start_daemon "$PORTAL_PID" "$PORTAL_LOG" "server.py" "$PYTHON_BIN" "$APP_FILE" || die "Portal failed to start."
    start_daemon "$DNSMASQ_PID" "$DNSMASQ_LOG" "dnsmasq.conf" dnsmasq --no-daemon --conf-file="$DNSMASQ_CONF" --pid-file="$DNSMASQ_PID" || die "dnsmasq failed to start."
    start_daemon "$HOSTAPD_PID" "$HOSTAPD_LOG" "hostapd.conf" hostapd "$HOSTAPD_CONF" || die "hostapd failed to start."

    sleep 1
    if ! iw dev "$AP_IFACE" info 2>/dev/null | grep -Eq '^[[:space:]]*type AP$'; then
        die "The hotspot interface is no longer in AP mode."
    fi

    printf '\n'
    printf '=============================================\n'
    printf ' Q-Spot is running\n'
    printf ' SSID:       %s\n' "$SSID"
    printf ' Security:   Open (no Wi-Fi password)\n'
    printf ' Gateway:    %s\n' "$GATEWAY_IP"
    printf ' Portal:     http://%s:%s/\n' "$GATEWAY_IP" "$PORTAL_PORT"
    printf ' Uplink:     %s\n' "$UPLINK"
    printf ' Channel:    %s\n' "$HOTSPOT_CHANNEL"
    printf ' Access:     Voucher required for internet\n'
    printf '=============================================\n'
    printf 'Connect to the Wi-Fi, then open http://neverssl.com if the portal does not pop up.\n'
}

stop_qspot() {
    log "Stopping Q-Spot..."
    stop_orphaned_daemons
    stop_daemon "$HOSTAPD_PID" "hostapd.conf"
    stop_daemon "$DNSMASQ_PID" "dnsmasq.conf"
    stop_daemon "$PORTAL_PID" "server.py"
    remove_firewall
    restore_forwarding_state

    if iw dev "$AP_IFACE" info >/dev/null 2>&1; then
        ip link set "$AP_IFACE" down 2>/dev/null || true
        iw dev "$AP_IFACE" del 2>/dev/null || true
    fi

    rm -f "$HOSTAPD_PID" "$DNSMASQ_PID" "$PORTAL_PID"
    log "Q-Spot stopped. Your uplink interface $UPLINK was not disconnected."
}

show_process_status() {
    local label="$1" pidfile="$2" match="$3" pid
    pid="$(process_from_pidfile "$pidfile" "$match" || true)"
    if [[ -n "$pid" ]]; then
        printf '%-10s RUNNING (PID %s)\n' "$label" "$pid"
    else
        printf '%-10s STOPPED\n' "$label"
    fi
}

status_qspot() {
    printf '\nQ-Spot status\n'
    printf '%s\n' '------------------------------'
    show_process_status hostapd "$HOSTAPD_PID" hostapd.conf
    show_process_status dnsmasq "$DNSMASQ_PID" dnsmasq.conf
    show_process_status portal "$PORTAL_PID" server.py
    printf '\n'
    if iw dev "$AP_IFACE" info >/dev/null 2>&1; then
        iw dev "$AP_IFACE" info | grep -E '^[[:space:]]*(Interface|ssid|type|channel)' || true
        ip -4 -o addr show dev "$AP_IFACE" || true
        printf '\nConnected stations:\n'
        iw dev "$AP_IFACE" station dump 2>/dev/null || true
    else
        printf '%s is not present.\n' "$AP_IFACE"
    fi
    printf '\n'
    if iptables -w 2 -S "$FILTER_FORWARD_CHAIN" >/dev/null 2>&1; then
        printf 'Voucher firewall:\n'
        iptables -w 2 -S "$FILTER_FORWARD_CHAIN"
    else
        printf 'Voucher firewall: not installed\n'
    fi
}

show_logs() {
    tail -n 80 -f "$HOSTAPD_LOG" "$DNSMASQ_LOG" "$PORTAL_LOG"
}

run_manager() {
    [[ -f "$MANAGER_FILE" ]] || die "Voucher manager not found: $MANAGER_FILE"
    exec "$PYTHON_BIN" "$MANAGER_FILE"
}

usage() {
    cat <<EOF2
Usage: sudo ./q-spot.sh {start|stop|restart|status|manager|logs}

  start    Start open Q-Spot Wi-Fi and voucher captive portal (default)
  stop     Stop Q-Spot without disconnecting the café Wi-Fi uplink
  restart  Restart Q-Spot
  status   Show daemon, AP interface, station and firewall status
  manager  Open the existing voucher manager
  logs     Follow hostapd, dnsmasq and portal logs

Wi-Fi is open (no Wi-Fi password). Internet forwarding is blocked until
app/server.py authorizes a client through a valid voucher.
EOF2
}

cleanup_on_failed_start() {
    local rc=$?
    if (( rc != 0 )) && (( STARTUP_IN_PROGRESS == 1 )); then
        trap - EXIT ERR
        warn "Startup failed (exit code $rc) near command: ${BASH_COMMAND:-unknown}; cleaning up Q-Spot resources."
        # Stop only Q-Spot's own daemons, firewall rules and virtual interface.
        stop_qspot || true
    fi
    return "$rc"
}

main() {
    local action="${1:-start}"
    case "$action" in
        start)
            exec 9>"$RUNTIME_DIR/q-spot.lock"
            flock -n 9 || die "Another Q-Spot operation is already running."
            STARTUP_IN_PROGRESS=1
            trap cleanup_on_failed_start EXIT
            start_qspot
            STARTUP_IN_PROGRESS=0
            trap - EXIT ERR
            ;;
        stop)
            exec 9>"$RUNTIME_DIR/q-spot.lock"
            flock -n 9 || die "Another Q-Spot operation is already running."
            stop_qspot
            ;;
        restart)
            exec 9>"$RUNTIME_DIR/q-spot.lock"
            flock -n 9 || die "Another Q-Spot operation is already running."
            stop_qspot || true
            STARTUP_IN_PROGRESS=1
            trap cleanup_on_failed_start EXIT
            start_qspot
            STARTUP_IN_PROGRESS=0
            trap - EXIT ERR
            ;;
        status)
            status_qspot
            ;;
        manager)
            run_manager
            ;;
        logs)
            show_logs
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
