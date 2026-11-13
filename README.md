# Q-Spot --- Wi-Fi Rolling Voucher Portal

<p align="center">
  <img src="app/images/logo_qspot.png" alt="Q-Spot logo" width="160" />
</p>

Q-Spot is a lightweight Wi-Fi hotspot and captive portal manager built
for Manjaro/Arch Linux and NetworkManager. It provisions a virtual
Access Point (AP) interface, manages NAT/DHCP sharing, issues
time-limited QR vouchers, and automatically expires client sessions.

------------------------------------------------------------------------

## Quick Start

1.  Extract the project directory to a writable location and open a
    terminal inside `q-spot`:

    ``` bash
    cd q-spot
    sudo ./q-spot.sh
    ```

2.  On the initial run, you will be prompted to configure:

    -   **Internet uplink interface** (auto-detected from the default
        route, e.g., `wlo1`)
    -   **Hotspot SSID** (default: `Q-Spot`)
    -   **Hotspot WPA2 password** (minimum 8 characters)
    -   **Admin username** (default: `admin`)
    -   **Admin password** (defaults to an auto-generated password)

The launcher automatically installs missing Manjaro/Arch dependencies,
starts the AP and captive portal, opens the local admin login page, and
launches the terminal manager (navigate with `j`/`k` or arrow keys,
`Enter` to select, `q` to quit).

------------------------------------------------------------------------

## CLI Commands

``` bash
sudo ./q-spot.sh           # Start services and open the terminal manager
sudo ./q-spot.sh start     # Same as above
sudo ./q-spot.sh status    # Check AP, firewall, and portal status
sudo ./q-spot.sh manager   # Attach to the terminal manager while running
sudo ./q-spot.sh logs      # View live portal logs
sudo ./q-spot.sh stop      # Stop hotspot and clean up virtual interface
```

### Default Network Configuration

-   **Virtual AP Interface:** `qspot0`
-   **Gateway IP:** `10.42.0.1/24`
-   **Portal Port:** `8081`

Modify `config.env` to customize these values. Stopping Q-Spot tears
down the virtual AP without disrupting your upstream Wi-Fi connection.

------------------------------------------------------------------------

## How It Works

### Guest & Admin Access

-   **Connection:** Guests connect to the `Q-Spot` SSID using the WPA2
    password; NetworkManager handles DHCP, DNS, and NAT.
-   **Captive Portal:** HTTP requests redirect automatically to the
    portal. If a device does not trigger the captive portal sheet
    automatically, navigate to `http://10.42.0.1:8081`.
-   **Authentication:** Guests log in using a 4-character voucher code
    and 4-character password, or by scanning a one-time QR voucher.
-   **Session Enforcement:** The countdown timer begins upon voucher
    redemption, and `iptables` permits internet access exclusively for
    that guest's IP address until expiration.
-   **Admin Dashboard:** Administrators sign in using the same login
    form on the portal page; entering admin credentials redirects to the
    management dashboard.

### QR Code Scanning

Because standard browsers restrict live camera APIs over unencrypted
HTTP, the portal's camera button triggers the mobile device's native
photo capture (`<input type="file" capture>`). Uploaded images are
decoded server-side using `zbarimg` (`zbar`). Guests can also scan
vouchers directly using their phone's built-in camera app.

------------------------------------------------------------------------

## Security & Operational Notes

-   **Authorization:** Deploy only on networks you own or are explicitly
    authorized to manage.
-   **Hardware Concurrency:** Simultaneous AP + Station mode depends on
    your Wi-Fi chipset and driver. If your adapter cannot maintain an
    upstream Wi-Fi connection while broadcasting an AP, use Ethernet or
    a secondary USB Wi-Fi adapter for the uplink.
-   **Captive Portal Behavior:** HTTPS traffic cannot be transparently
    intercepted; auto-popup behavior varies across Android and iOS
    devices.
-   **Client Tracking:** Session authorization is tied to the client's
    IPv4 address. DHCP lease changes or MAC randomization may require
    re-authentication.
-   **Privileges & Exposure:** The portal runs as `root` to manage
    `iptables` rules and is designed strictly for local LAN deployment.
    **Do not expose port `8081` to the public internet or upstream
    network.**
-   **Credentials:** Keep `config.env` restricted, as it stores
    plaintext hotspot and admin credentials.
-   **Troubleshooting:** If startup fails, inspect `data/portal.log` and
    run `sudo ./q-spot.sh status` or verify routing with `ip route` and
    `nmcli`.

------------------------------------------------------------------------

## Project Structure

-   `q-spot.sh` --- Entrypoint script for dependency checks, AP
    provisioning, `iptables` rules, and teardown.
-   `app/server.py` --- Backend web server, SQLite voucher/session
    store, timer enforcement, and `zbarimg` QR decoder.
-   `app/index.html` --- Guest captive portal login interface.
-   `app/admin.html` --- Admin dashboard for voucher generation, session
    monitoring, and analytics.
-   `qspot-manager.py` --- Keyboard-driven terminal UI for service
    control and monitoring.
