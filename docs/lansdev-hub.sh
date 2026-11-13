#!/usr/bin/env bash
# LansDev-HUB - a LazyVim-inspired terminal dashboard.
# Manages Wi-Fi sharing, Wi-Fi clients, and safely ejects Dev_Drive.

# Play keyboard pump once per LansDev-HUB launch
"$HOME/bin/kbd-pump.sh"

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Configuration - edit these values if your paths or connection names change.
# -----------------------------------------------------------------------------
WIFI_SCRIPT="${WIFI_SCRIPT:-$HOME/bin/wifi-share.sh}"
WIFI_AP_IFACE="${WIFI_AP_IFACE:-ap0}"
WIFI_CONNECTION="${WIFI_CONNECTION:-Manjaro-Share}"
HDD_MOUNT="${HDD_MOUNT:-/mnt/Dev_Drive}"
DOCKER_STOP_TIMEOUT="${DOCKER_STOP_TIMEOUT:-20}"

# Wi-Fi client blocks are saved here and restored when the hub starts the AP.
WIFI_BLOCK_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/lansdev-hub"
WIFI_BLOCK_FILE="$WIFI_BLOCK_DIR/blocked-wifi-clients"
WIFI_NAME_FILE="$WIFI_BLOCK_DIR/wifi-client-names"
WIFI_FIREWALL_TABLE="lansdev_hub_wifi"

# -----------------------------------------------------------------------------
# Colors (256-color terminal). Set NO_COLOR=1 to disable them.
# -----------------------------------------------------------------------------
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  RESET=$'\033[0m'
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  CYAN=$'\033[38;5;81m'
  BLUE=$'\033[38;5;75m'
  PURPLE=$'\033[38;5;141m'
  GREEN=$'\033[38;5;114m'
  YELLOW=$'\033[38;5;221m'
  RED=$'\033[38;5;203m'
  MUTED=$'\033[38;5;245m'
  PANEL=$'\033[48;5;235m'
else
  RESET='' BOLD='' DIM='' CYAN='' BLUE='' PURPLE='' GREEN=''
  YELLOW='' RED='' MUTED='' PANEL=''
fi

# Return the current terminal width, with a safe fallback for non-standard TTYs.
terminal_width() {
  local width
  width="${COLUMNS:-}"
  if [[ ! "$width" =~ ^[0-9]+$ ]] || ((width < 20)); then
    width="$(tput cols 2>/dev/null || printf '80')"
  fi
  printf '%s' "$width"
}

# Count UTF-8 characters so the block-art logo is centered even in a C locale.
text_length() {
  printf '%s' "$1" | LC_ALL=C.utf8 wc -m | tr -d '[:space:]'
}

# Center plain text, optionally applying a terminal color/bold prefix.
center_print() {
  local text="$1"
  local style="${2:-}"
  local width pad length
  width="$(terminal_width)"
  length="$(text_length "$text")"
  pad=$(( (width - length) / 2 ))
  ((pad < 0)) && pad=0
  printf '%*s%b%s%b\n' "$pad" '' "$style" "$text" "$RESET"
}

# Center text that already contains ANSI color sequences (used for live status).
center_colored() {
  local text="$1"
  local plain width pad length

  # Strip ANSI escape sequences without relying on fragile sed ranges.
  plain="$(printf '%s' "$text" | perl -pe 's/\e\[[0-9;?]*[ -\/]*[@-~]//g')"

  # Read the actual terminal width; COLUMNS may be stale in Kitty or menus.
  width="$(stty size 2>/dev/null | awk '{print $2}')"
  if [[ ! "$width" =~ ^[0-9]+$ ]] || ((width < 20)); then
    width="$(tput cols 2>/dev/null || true)"
  fi
  if [[ ! "$width" =~ ^[0-9]+$ ]] || ((width < 20)); then
    width="$(terminal_width)"
  fi

  length="$(text_length "$plain")"
  pad=$(( (width - length) / 2 ))
  ((pad < 0)) && pad=0
  printf '%*s%s\n' "$pad" '' "$text"
}

center_prompt() {
  local text="$1"
  local width pad
  width="$(terminal_width)"
  pad=$(( (width - $(text_length "$text")) / 2 ))
  ((pad < 0)) && pad=0
  printf '%*s%b%s%b' "$pad" '' "$BOLD" "$text" "$RESET"
}

hr() {
  local width rule_width rule
  width="$(terminal_width)"
  rule_width=72
  ((width < rule_width)) && rule_width="$width"
  printf -v rule '%*s' "$rule_width" ''
  rule="${rule// /─}"
  center_print "$rule" "$MUTED"
}

wifi_is_active() {
  command -v nmcli >/dev/null 2>&1 || return 1
  nmcli -t -f NAME connection show --active 2>/dev/null \
    | grep -Fxq -- "$WIFI_CONNECTION"
}

wifi_status() {
  if wifi_is_active; then
    printf '%s' "${GREEN}ACTIVE${RESET}"
  elif command -v nmcli >/dev/null 2>&1 \
      && nmcli -t -f DEVICE,STATE device status 2>/dev/null \
        | awk -F: -v dev="$WIFI_AP_IFACE" '$1 == dev && $2 == "connected" { found=1 } END { exit !found }'; then
    printf '%s' "${YELLOW}CONNECTED (CHECK AP)${RESET}"
  else
    printf '%s' "${MUTED}OFFLINE${RESET}"
  fi
}

hdd_status() {
  if mountpoint -q "$HDD_MOUNT"; then
    printf '%s' "${GREEN}MOUNTED${RESET}"
  else
    printf '%s' "${MUTED}UNMOUNTED${RESET}"
  fi
}

# -----------------------------------------------------------------------------
# Wi-Fi client management
# -----------------------------------------------------------------------------
valid_mac() {
  [[ "${1:-}" =~ ^([[:xdigit:]]{2}:){5}[[:xdigit:]]{2}$ ]]
}

# Look up a manually assigned friendly name for a device MAC address.
# File format: lowercase-mac|friendly name
client_custom_name() {
  local mac="${1,,}" saved_mac saved_name
  [[ -r "$WIFI_NAME_FILE" ]] || return 1

  while IFS='|' read -r saved_mac saved_name; do
    if [[ "${saved_mac,,}" == "$mac" && -n "$saved_name" ]]; then
      printf '%s' "$saved_name"
      return 0
    fi
  done < "$WIFI_NAME_FILE"

  return 1
}

# Save or replace a friendly name without disturbing other device mappings.
set_client_custom_name() {
  local mac="${1,,}" name="$2" saved_mac saved_name temp_file
  mkdir -p -- "$WIFI_BLOCK_DIR"
  temp_file="$(mktemp "$WIFI_NAME_FILE.tmp.XXXXXX")" || return 1

  if [[ -f "$WIFI_NAME_FILE" ]]; then
    while IFS='|' read -r saved_mac saved_name; do
      [[ -n "$saved_mac" ]] || continue
      if [[ "${saved_mac,,}" != "$mac" ]]; then
        printf '%s|%s\n' "$saved_mac" "$saved_name" >> "$temp_file"
      fi
    done < "$WIFI_NAME_FILE"
  fi

  printf '%s|%s\n' "$mac" "$name" >> "$temp_file"
  chmod 600 "$temp_file"
  mv -- "$temp_file" "$WIFI_NAME_FILE"
}

# Remove only the custom display name; this does not unblock the device.
remove_client_custom_name() {
  local mac="${1,,}" saved_mac saved_name found=0 temp_file
  [[ -f "$WIFI_NAME_FILE" ]] || return 1
  temp_file="$(mktemp "$WIFI_NAME_FILE.tmp.XXXXXX")" || return 1

  while IFS='|' read -r saved_mac saved_name; do
    [[ -n "$saved_mac" ]] || continue
    if [[ "${saved_mac,,}" == "$mac" ]]; then
      found=1
    else
      printf '%s|%s\n' "$saved_mac" "$saved_name" >> "$temp_file"
    fi
  done < "$WIFI_NAME_FILE"

  if ((found)); then
    chmod 600 "$temp_file"
    mv -- "$temp_file" "$WIFI_NAME_FILE"
    return 0
  fi

  rm -f -- "$temp_file"
  return 1
}

# Create firewall hooks that block selected MAC addresses from both the
# laptop itself and forwarded internet traffic. A drop verdict also works
# when the existing iptables FORWARD rules accept other clients.
ensure_wifi_block_firewall() {
  local mac

  command -v nft >/dev/null 2>&1 || {
    printf '%s\n' "${RED}[!] nftables is not installed; client blocking is unavailable.${RESET}"
    return 1
  }
  command -v iw >/dev/null 2>&1 || {
    printf '%s\n' "${RED}[!] iw is not installed; client detection is unavailable.${RESET}"
    return 1
  }

  mkdir -p -- "$WIFI_BLOCK_DIR"
  touch -- "$WIFI_BLOCK_FILE"
  sudo -v || return 1

  if ! sudo nft list table inet "$WIFI_FIREWALL_TABLE" >/dev/null 2>&1; then
    sudo nft add table inet "$WIFI_FIREWALL_TABLE" || return 1
  fi

  if ! sudo nft list set inet "$WIFI_FIREWALL_TABLE" blocked_macs >/dev/null 2>&1; then
    sudo nft "add set inet $WIFI_FIREWALL_TABLE blocked_macs { type ether_addr; }" || return 1
  fi

  # Use prerouting so the source MAC is still available before routing.
  if ! sudo nft list chain inet "$WIFI_FIREWALL_TABLE" prerouting >/dev/null 2>&1; then
    sudo nft "add chain inet $WIFI_FIREWALL_TABLE prerouting { type filter hook prerouting priority -10; policy accept; }" || return 1
  fi

  if ! sudo nft list chain inet "$WIFI_FIREWALL_TABLE" prerouting 2>/dev/null \
      | grep -Fq 'ether saddr @blocked_macs'; then
    sudo nft add rule inet "$WIFI_FIREWALL_TABLE" prerouting \
      iifname "$WIFI_AP_IFACE" ether saddr @blocked_macs counter drop || return 1
  fi

  # Reapply saved blocks after a reboot or firewall-table recreation.
  while IFS= read -r mac; do
    mac="${mac,,}"
    [[ -n "$mac" ]] || continue
    valid_mac "$mac" || continue
    sudo nft add element inet "$WIFI_FIREWALL_TABLE" blocked_macs "{ $mac }" 2>/dev/null || true
  done < "$WIFI_BLOCK_FILE"
}

client_ip() {
  local mac="$1"
  ip neigh show dev "$WIFI_AP_IFACE" 2>/dev/null \
    | awk -v wanted="$mac" '{ for (i=1; i<NF; i++) if (tolower($i) == "lladdr" && tolower($(i+1)) == wanted) { print $1; exit } }'
}

client_name() {
  local mac="$1" ip="$2" name lease_file
  local -a lease_files=(/var/lib/NetworkManager/dnsmasq-ap0.leases
                        /var/lib/NetworkManager/dnsmasq-*.leases
                        /var/lib/misc/dnsmasq.leases)

  # Prefer a user-assigned name over DHCP or reverse-DNS hostnames.
  name="$(client_custom_name "$mac" 2>/dev/null || true)"
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
    return 0
  fi

  # NetworkManager's dnsmasq lease format: expiry MAC IP hostname client-id.
  for lease_file in "${lease_files[@]}"; do
    [[ -r "$lease_file" ]] || continue
    name="$(awk -v wanted="${mac,,}" '$2 == wanted { print $4; exit }' "$lease_file")"
    if [[ -n "$name" && "$name" != '*' ]]; then
      printf '%s' "$name"
      return 0
    fi
  done

  # Reverse DNS can provide a name when the client publishes one.
  if [[ -n "$ip" && "$ip" != '--' ]]; then
    name="$(getent hosts "$ip" 2>/dev/null | awk 'NR == 1 {print $2}')"
    if [[ -n "$name" ]]; then
      printf '%s' "$name"
      return 0
    fi
  fi

  printf '%s' 'Unknown'
}

client_stat() {
  local dump="$1" mac="$2" field="$3"
  awk -v wanted="$mac" -v field="$field" '
    /^Station / { active=(tolower($2) == wanted); next }
    active && field == "signal" && $1 == "signal:" { print $2; exit }
    active && field == "rx" && $1 == "rx" && $2 == "bytes:" { print $3; exit }
    active && field == "tx" && $1 == "tx" && $2 == "bytes:" { print $3; exit }
  ' <<< "$dump"
}

format_bytes() {
  local value="${1:-}"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    numfmt --to=iec-i --suffix=B "$value" 2>/dev/null || printf '%sB' "$value"
  else
    printf '%s' '--'
  fi
}

manage_wifi_clients() {
  local station_dump line mac ip name signal rx tx state action number selected temp_file selected_name
  local index
  local -a client_macs=() client_states=()
  local -A seen=()

  printf '\n%s\n' "${CYAN}[*] Preparing Wi-Fi client manager...${RESET}"
  if ! ensure_wifi_block_firewall; then
    return 1
  fi

  while true; do
    station_dump=''
    client_macs=()
    client_states=()
    seen=()

    if iw dev "$WIFI_AP_IFACE" info >/dev/null 2>&1; then
      station_dump="$(iw dev "$WIFI_AP_IFACE" station dump 2>/dev/null || true)"
    fi

    # Associated stations first.
    while IFS= read -r line; do
      if [[ "$line" =~ ^Station[[:space:]]+([[:xdigit:]:]{17}) ]]; then
        mac="${BASH_REMATCH[1],,}"
        if [[ -z "${seen[$mac]+x}" ]]; then
          seen[$mac]=1
          client_macs+=("$mac")
          if grep -Fxiq -- "$mac" "$WIFI_BLOCK_FILE"; then
            client_states+=("BLOCKED")
          else
            client_states+=("CONNECTED")
          fi
        fi
      fi
    done <<< "$station_dump"

    # Include blocked devices even though they were deauthenticated and are no
    # longer present in the station list, so they can still be unblocked here.
    while IFS= read -r mac; do
      mac="${mac,,}"
      [[ -n "$mac" ]] || continue
      valid_mac "$mac" || continue
      if [[ -z "${seen[$mac]+x}" ]]; then
        seen[$mac]=1
        client_macs+=("$mac")
        client_states+=("BLOCKED")
      fi
    done < "$WIFI_BLOCK_FILE"

    clear 2>/dev/null || true
    center_print 'LansDev-HUB  /  WIFI CLIENTS' "${CYAN}${BOLD}"
    printf '\n'
    if ! nmcli -g GENERAL.CONNECTION device show "$WIFI_AP_IFACE" 2>/dev/null \
        | grep -Fxq -- "$WIFI_CONNECTION"; then
      center_print 'Hotspot is not currently active on ap0.' "$YELLOW"
    fi
    printf '\n'
    printf '%-4s %-18s %-17s %-16s %-9s %-10s %-10s %-11s\n' \
      'NO.' 'DEVICE NAME' 'MAC ADDRESS' 'IP ADDRESS' 'SIGNAL' 'RX' 'TX' 'STATUS'
    printf '%-4s %-18s %-17s %-16s %-9s %-10s %-10s %-11s\n' \
      '----' '------------------' '-----------------' '----------------' '---------' '----------' '----------' '-----------'

    if ((${#client_macs[@]} == 0)); then
      printf '%s\n' 'No connected or blocked clients found.'
    else
      for index in "${!client_macs[@]}"; do
        mac="${client_macs[$index]}"
        state="${client_states[$index]}"
        ip="$(client_ip "$mac")"
        name="$(client_name "$mac" "${ip:---}")"
        signal="$(client_stat "$station_dump" "$mac" signal)"
        rx="$(client_stat "$station_dump" "$mac" rx)"
        tx="$(client_stat "$station_dump" "$mac" tx)"
        [[ -n "$ip" ]] || ip='--'
        [[ -n "$signal" ]] && signal="${signal} dBm" || signal='--'
        printf '%-4s %-18.18s %-17s %-16s %-9s %-10s %-10s %-11s\n' \
          "$((index + 1))" "$name" "$mac" "$ip" "$signal" \
          "$(format_bytes "$rx")" "$(format_bytes "$tx")" "$state"
      done
    fi

    printf '\n'
    printf '%s\n' 'b = Block   u = Unblock   n = Set/rename device   x = Clear custom name'
    printf '%s\n' 'r = Refresh   q = Back'
    printf 'Action: '
    read -r action || return 0

    case "${action,,}" in
      b|u|n|x)
        if ((${#client_macs[@]} == 0)); then
          printf '%s\n' 'There are no clients to select.'
          read -r -p 'Press Enter to continue...' _ || true
          continue
        fi

        printf 'Enter client number: '
        read -r number || return 0
        if [[ ! "$number" =~ ^[0-9]+$ ]] || ((number < 1 || number > ${#client_macs[@]})); then
          printf '%s\n' "${YELLOW}[!] Invalid client number.${RESET}"
          read -r -p 'Press Enter to continue...' _ || true
          continue
        fi

        selected="${client_macs[$((number - 1))]}"
        state="${client_states[$((number - 1))]}"

        case "${action,,}" in
          b)
            if [[ "$state" == BLOCKED ]]; then
              printf '%s\n' "${YELLOW}[i] $selected is already blocked.${RESET}"
            elif sudo nft add element inet "$WIFI_FIREWALL_TABLE" blocked_macs "{ $selected }"; then
              printf '%s\n' "$selected" >> "$WIFI_BLOCK_FILE"
              # Disconnect immediately; the firewall rule prevents reconnection
              # from passing traffic until this MAC is unblocked.
              sudo iw dev "$WIFI_AP_IFACE" station del "$selected" 2>/dev/null || true
              printf '%s\n' "${GREEN}[+] Blocked $selected.${RESET}"
            else
              printf '%s\n' "${RED}[!] Could not add the block rule for $selected.${RESET}"
            fi
            ;;
          u)
            if [[ "$state" != BLOCKED ]]; then
              printf '%s\n' "${YELLOW}[i] $selected is not blocked.${RESET}"
            else
              sudo nft delete element inet "$WIFI_FIREWALL_TABLE" blocked_macs "{ $selected }" 2>/dev/null || true
              temp_file="${WIFI_BLOCK_FILE}.tmp.$$"
              grep -Fivx -- "$selected" "$WIFI_BLOCK_FILE" > "$temp_file" || true
              mv -- "$temp_file" "$WIFI_BLOCK_FILE"
              printf '%s\n' "${GREEN}[+] Unblocked $selected. The device can reconnect now.${RESET}"
            fi
            ;;
          n)
            printf 'Enter a friendly name for %s (avoid the | character): ' "$selected"
            read -r selected_name || return 0
            selected_name="${selected_name#"${selected_name%%[![:space:]]*}"}"
            selected_name="${selected_name%"${selected_name##*[![:space:]]}"}"
            if [[ -z "$selected_name" || "$selected_name" == *'|'* ]]; then
              printf '%s\n' "${YELLOW}[!] Name cannot be empty or contain |.${RESET}"
            elif set_client_custom_name "$selected" "$selected_name"; then
              printf '%s\n' "${GREEN}[+] Saved name: $selected_name ($selected).${RESET}"
            else
              printf '%s\n' "${RED}[!] Could not save the device name.${RESET}"
            fi
            ;;
          x)
            if remove_client_custom_name "$selected"; then
              printf '%s\n' "${GREEN}[+] Removed the custom name for $selected.${RESET}"
            else
              printf '%s\n' "${YELLOW}[i] No custom name is saved for $selected.${RESET}"
            fi
            ;;
        esac
        read -r -p 'Press Enter to refresh the table...' _ || true
        ;;
      r|'')
        ;;
      q|quit|back)
        return 0
        ;;
      *)
        printf '%s\n' "${YELLOW}[!] Choose b, u, r, or q.${RESET}"
        read -r -p 'Press Enter to continue...' _ || true
        ;;
    esac
  done
}

header() {
  local line
  local logo_art
  # Large block-art wordmark. Terminal font size cannot be changed per line.
  logo_art=$(cat <<'LOGO'
 █████                                    ██████████                                   █████   █████ █████  █████ ███████████
░░███                                    ░░███░░░░███                                 ░░███   ░░███ ░░███  ░░███ ░░███░░░░░███
 ░███         ██████   ████████    █████  ░███   ░░███  ██████  █████ █████            ░███    ░███  ░███   ░███  ░███    ░███
 ░███        ░░░░░███ ░░███░░███  ███░░   ░███    ░███ ███░░███░░███ ░░███  ██████████ ░███████████  ░███   ░███  ░██████████
 ░███         ███████  ░███ ░███ ░░█████  ░███    ░███░███████  ░███  ░███ ░░░░░░░░░░  ░███░░░░░███  ░███   ░███  ░███░░░░░███
 ░███      █ ███░░███  ░███ ░███  ░░░░███ ░███    ███ ░███░░░   ░░███ ███              ░███    ░███  ░███   ░███  ░███    ░███
 ███████████░░████████ ████ █████ ██████  ██████████  ░░██████   ░░█████               █████   █████ ░░████████   ███████████
░░░░░░░░░░░  ░░░░░░░░ ░░░░ ░░░░░ ░░░░░░  ░░░░░░░░░░    ░░░░░░     ░░░░░               ░░░░░   ░░░░░   ░░░░░░░░   ░░░░░░░░░░░
LOGO
)

  clear 2>/dev/null || true
  printf '\n'
  while IFS= read -r line; do
    center_print "$line" "${CYAN}${BOLD}"
  done <<< "$logo_art"
  printf '\n'
  center_print 'LOCAL CONTROL PANEL' "$DIM"
  printf '\n'
  hr
  center_colored "WIFI SHARE  [$(wifi_status)]  │  DEV_DRIVE  [$(hdd_status)]"
  hr
  printf '\n'
}

pause() {
  printf '\n'
  center_print 'Press Enter to return to the menu...' "$DIM"
  center_prompt '  > '
  read -r _ || true
}

run_wifi() {
  local action="$1"
  printf '\n%s\n' "${CYAN}[*] Wi-Fi sharing: ${action}${RESET}"

  if [[ ! -f "$WIFI_SCRIPT" ]]; then
    printf '%s\n' "${RED}[!] Cannot find: $WIFI_SCRIPT${RESET}"
    printf '%s\n' "Place your existing wifi-share.sh script there, or edit WIFI_SCRIPT at the top."
    return 1
  fi

  # The existing script is called using the same start/stop arguments used
  # from the terminal. Run it with Bash even if its executable bit is missing.
  if bash "$WIFI_SCRIPT" "$action"; then
    printf '\n%s\n' "${GREEN}[+] Wi-Fi script finished.${RESET}"
    # Recreate the MAC block rules after a reboot/firewall reset when the AP
    # has just been started through LansDev-HUB.
    if [[ "$action" == start && -s "$WIFI_BLOCK_FILE" ]]; then
      if ensure_wifi_block_firewall; then
        printf '%s\n' "${GREEN}[+] Saved Wi-Fi client blocks restored.${RESET}"
      else
        printf '%s\n' "${YELLOW}[!] Could not restore the saved Wi-Fi client blocks.${RESET}"
      fi
    fi
  else
    local rc=$?
    printf '\n%s\n' "${RED}[!] Wi-Fi script failed (exit code $rc).${RESET}"
    return "$rc"
  fi
}

# Return a usable Docker command in DOCKER_CMD. Abort if the daemon is active
# but cannot be inspected, because unmounting without checking would be unsafe.
prepare_docker() {
  DOCKER_CMD=()

  if ! command -v docker >/dev/null 2>&1; then
    if systemctl is-active --quiet docker.service 2>/dev/null \
      || systemctl is-active --quiet docker.socket 2>/dev/null; then
      printf '%s\n' "${RED}[!] Docker is running but the Docker CLI is unavailable.${RESET}"
      return 1
    fi
    return 0
  fi

  if docker info >/dev/null 2>&1; then
    DOCKER_CMD=(docker)
    return 0
  fi

  if systemctl is-active --quiet docker.service 2>/dev/null \
    || systemctl is-active --quiet docker.socket 2>/dev/null; then
    printf '%s\n' "${YELLOW}[*] Docker needs administrator access; requesting it...${RESET}"
    sudo -v || return 1
    if sudo docker info >/dev/null 2>&1; then
      DOCKER_CMD=(sudo docker)
      return 0
    fi
    printf '%s\n' "${RED}[!] Cannot inspect Docker. HDD unmount cancelled.${RESET}"
    return 1
  fi

  # The Docker daemon is not active, so there cannot be running containers.
  return 0
}

unmount_devdrive() {
  local docker_root id name source uses_hdd
  local -a running_ids=() containers_to_stop=()

  printf '\n%s\n' "${CYAN}[*] Preparing to unmount $HDD_MOUNT${RESET}"

  if ! mountpoint -q "$HDD_MOUNT"; then
    printf '%s\n' "${YELLOW}[i] Dev_Drive is already unmounted.${RESET}"
    return 0
  fi

  if ! command -v sudo >/dev/null 2>&1; then
    printf '%s\n' "${RED}[!] sudo is required to unmount this drive.${RESET}"
    return 1
  fi
  sudo -v || return 1

  if ! prepare_docker; then
    return 1
  fi

  if ((${#DOCKER_CMD[@]} > 0)); then
    docker_root="$("${DOCKER_CMD[@]}" info --format '{{.DockerRootDir}}' 2>/dev/null)" || {
      printf '%s\n' "${RED}[!] Could not read Docker's data directory. Unmount cancelled.${RESET}"
      return 1
    }

    case "$docker_root" in
      "$HDD_MOUNT"|"$HDD_MOUNT"/*)
        printf '%s\n' "${RED}[!] Docker's entire data directory is on Dev_Drive.${RESET}"
        printf '%s\n' "Stop Docker itself and review its storage configuration before ejecting this drive."
        return 1
        ;;
    esac

    mapfile -t running_ids < <("${DOCKER_CMD[@]}" ps -q)

    for id in "${running_ids[@]}"; do
      name="$("${DOCKER_CMD[@]}" inspect --format '{{.Name}}' "$id" 2>/dev/null | sed 's#^/##')"
      uses_hdd=false

      while IFS= read -r source; do
        case "$source" in
          "$HDD_MOUNT"|"$HDD_MOUNT"/*)
            uses_hdd=true
            break
            ;;
        esac
      done < <("${DOCKER_CMD[@]}" inspect \
        --format '{{range .Mounts}}{{println .Source}}{{end}}' "$id")

      if [[ "$uses_hdd" == true ]]; then
        printf '  %s- %s%s\n' "$YELLOW" "$name" "$RESET"
        containers_to_stop+=("$id")
      fi
    done

    if ((${#containers_to_stop[@]} > 0)); then
      printf '\n%s\n' "${YELLOW}[*] Stopping only containers that mount Dev_Drive...${RESET}"
      if ! "${DOCKER_CMD[@]}" stop --time "$DOCKER_STOP_TIMEOUT" "${containers_to_stop[@]}"; then
        printf '%s\n' "${RED}[!] At least one container did not stop cleanly. Unmount cancelled.${RESET}"
        return 1
      fi
    else
      printf '%s\n' "${GREEN}[+] No running Docker containers use Dev_Drive.${RESET}"
    fi
  else
    printf '%s\n' "${MUTED}[i] Docker daemon is not running; skipping container checks.${RESET}"
  fi

  printf '%s\n' "${CYAN}[*] Syncing pending disk writes...${RESET}"
  sync

  printf '%s\n' "${CYAN}[*] Unmounting...${RESET}"
  if sudo umount -- "$HDD_MOUNT"; then
    printf '%s\n' "${GREEN}[+] Dev_Drive safely unmounted.${RESET}"
  else
    printf '%s\n' "${RED}[!] Unmount failed. Something may still be using the HDD.${RESET}"
    printf '%s\n' "Close programs using $HDD_MOUNT and try again. The drive was not force-unmounted."
    return 1
  fi
}

show_menu() {
  header
  center_print 'A C T I O N S' "${BOLD}${PURPLE}"
  printf '\n'
  center_print '[1]  Start Wi-Fi sharing' "$CYAN"
  center_print '[2]  Stop Wi-Fi sharing' "$CYAN"
  center_print '[3]  Manage Wi-Fi clients (view / block / unblock)' "$CYAN"
  center_print '[4]  Safely unmount Dev_Drive' "$CYAN"
  center_print '[5]  Refresh status' "$CYAN"
  center_print '[q]  Quit' "$RED"
  printf '\n'
  hr
  center_prompt 'Select an option: '
}

main() {
  local choice

  while true; do
    show_menu
    read -r choice || exit 0

    case "${choice,,}" in
      1)
        run_wifi start || true
        pause
        ;;
      2)
        run_wifi stop || true
        pause
        ;;
      3)
        manage_wifi_clients || true
        ;;
      4)
        unmount_devdrive || true
        pause
        ;;
      5)
        ;;
      q|quit|exit)
        printf '\n%s\n' "${PURPLE}See you. Stay productive.${RESET}"
        exit 0
        ;;
      *)
        printf '\n%s\n' "${YELLOW}[!] Choose 1, 2, 3, 4, 5, or q.${RESET}"
        pause
        ;;
    esac
  done
}

main "$@"
