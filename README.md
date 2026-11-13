# Q-Spot — Wi-Fi rolling voucher portal (Manjaro / NetworkManager)

Q-Spot replaces the previous hotspot launcher: it creates its own AP interface and NetworkManager shared connection, starts the captive portal, issues one-time QR vouchers, and expires sessions automatically.

## Run

1. Extract this folder somewhere writable.
2. Open a terminal in the `q-spot` folder.
3. Run:

```bash
sudo ./q-spot.sh
```

First run asks for:
- Internet uplink interface (auto-detected from the default route; e.g. `wlo1`)
- Hotspot SSID (default `Q-Spot`)
- Hotspot WPA2 password (at least 8 characters)
- Admin username (default `admin`)
- Admin password (defaults to a generated short password)

The script installs Manjaro/Arch packages if missing, starts the AP and portal, opens the local admin login page where possible, then opens the keyboard-driven terminal manager. The manager supports `j`/`k` or arrow keys, Enter, and `q`.

## Commands

```bash
sudo ./q-spot.sh              # start and open terminal manager
sudo ./q-spot.sh start        # same
sudo ./q-spot.sh status
sudo ./q-spot.sh manager           # open terminal manager if already running
sudo ./q-spot.sh logs
sudo ./q-spot.sh stop
```

The script uses `qspot0` as a virtual AP interface, `10.42.0.1/24` as the gateway, and port `8081` for the portal. Adjust `config.env` to change these values. It leaves the upstream Wi-Fi connection alone on stop.

## Guest access

- Guest joins the `Q-Spot` hotspot using its WPA2 password.
- NetworkManager shared mode provides DHCP/DNS and NAT.
- HTTP captive-portal checks are redirected to the Q-Spot page. If a device does not pop up automatically, open `http://10.42.0.1:8081`.
- Guests use a short 4-character username and 4-character password, or scan the one-time QR.
- The timer starts when the voucher is redeemed. Only that guest IP is allowed through the AP-to-uplink firewall rule.
- Admin login uses the exact same username/password fields as guests; matching admin credentials opens the admin dashboard.

## QR camera button

The portal camera button opens the phone's native camera/photo capture using the file input capture hint, then the gateway decodes the photo using `zbarimg` (installed as `zbar`). Browser live-camera APIs are restricted on ordinary HTTP pages, so this approach avoids requiring HTTPS for the local hotspot portal. If the phone/browser does not offer camera capture, scan the QR using the phone's regular camera app instead.

## Important limitations / safety

- This is a prototype for a network you own or are authorized to administer. Get permission before sharing or reselling upstream café internet.
- AP+station concurrency depends on the Wi-Fi adapter/driver. Some adapters cannot stay connected to upstream Wi-Fi while hosting an AP. If so, use Ethernet for uplink or a second Wi-Fi adapter.
- Authorization currently follows the client's IPv4 address. DHCP address changes, MAC randomization, and reconnect behavior need additional hardening.
- HTTPS traffic cannot be transparently redirected. Captive portal auto-popup varies by Android/iOS; manual HTTP portal URL is the fallback.
- The server currently runs as root because it changes iptables. Do not expose port 8081 on the public internet or café uplink.
- This MVP does not yet include production-grade HTTPS, CSRF protection, rate limiting, multi-admin roles, or hardened persistent admin sessions.
- The firewall logic assumes the AP interface routes to the selected uplink interface. Verify with `ip route`, `nmcli`, and the logs before using with guests.
- Keep `config.env` private; it contains the hotspot and admin passwords.
- If a start attempt fails, inspect `data/portal.log` and run `sudo ./q-spot.sh status`.

## Files

- `q-spot.sh`: one-command launcher and hotspot/firewall setup/teardown.
- `app/server.py`: portal, voucher/session database, timer enforcement, QR scan decoding.
- `app/index.html`: adapted from the supplied design.
- `qspot-manager.py`: Vim/LazyVim-inspired terminal manager.
