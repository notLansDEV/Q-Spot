# Q-Spot — Wi-Fi rolling voucher portal (Manjaro / NetworkManager)

<p align="center">
  <img src="app/images/logo_qspot.png" alt="Q-Spot logo" width="160" />
</p>

Q-Spot replaces the previous hotspot launcher: it creates its own AP interface, runs DHCP/DNS and NAT, starts the captive portal, issues QR vouchers, and expires sessions automatically.

## Run

1. Extract this folder somewhere writable.
2. Open a terminal in the `q-spot` folder.
3. Run:

```bash
sudo ./q-spot.sh
```

First run asks for:
- Internet uplink interface (auto-detected from the default route; e.g. `wlo1`)
- Hotspot SSID (default `Q-Spot Hotspot`)
- Admin username (default `admin`)
- Admin password (defaults to a generated short password)

The Wi-Fi network is open (no Wi-Fi password); internet access is gated by vouchers instead.

The script installs Manjaro/Arch packages if missing, starts the AP and portal, then prints the portal URL. Run:

```bash
sudo ./q-spot.sh manager          # open the terminal voucher manager
http://10.42.0.1:8081/             # guest portal / admin login
http://10.42.0.1:8081/admin.html   # admin dashboard
```

The manager supports `j`/`k` or arrow keys, Enter, and `q`.

## Commands

```bash
sudo ./q-spot.sh              # start the hotspot and portal (default)
sudo ./q-spot.sh start        # same
sudo ./q-spot.sh status
sudo ./q-spot.sh manager           # open terminal manager if already running
sudo ./q-spot.sh logs
sudo ./q-spot.sh stop
```

The script uses `qspot0` as a virtual AP interface, `10.42.0.1/24` as the gateway, and port `8081` for the portal. Adjust `config.env` to change these values. It leaves the upstream Wi-Fi connection alone on stop.

## Guest access

- Guest joins the open `Q-Spot` hotspot (no Wi-Fi password).
- Q-Spot runs its own DHCP/DNS (dnsmasq) and NAT/firewall rules on the AP interface.
- HTTP captive-portal checks are redirected to the Q-Spot page. If a device does not pop up automatically, open `http://10.42.0.1:8081`.
- Guests use a short 5-character username (letters/numbers) and 4-digit password, or scan the QR.
- The timer starts on first login. Only that guest IP is allowed through the AP-to-uplink firewall rule. After login, guests land on `status.html` with their own username, IP, and live connection time.
- Vouchers are one-to-one with a user device. Logging out ends the session but keeps the voucher's remaining time; the same device may sign in again until the voucher expires. A voucher cannot be shared with or transferred to a second device.
- Admin login uses the exact same username/password fields as guests; matching admin credentials opens the admin dashboard at `admin.html`.
- The Terms of Service & Acceptable Use Policy is served at `/terms` from `app/Terms_&_Privacy.html`; guests accept it before logging in (see the footer checkbox on the login page).

## QR camera button

The portal camera button opens the phone's native camera/photo capture using the file input capture hint, then the gateway decodes the photo using `zbarimg` (installed as `zbar`). Browser live-camera APIs are restricted on ordinary HTTP pages, so this approach avoids requiring HTTPS for the local hotspot portal. If the phone/browser does not offer camera capture, scan the QR using the phone's regular camera app instead.

## Important limitations / safety

- This is a prototype for a network you own or are authorized to administer. Get permission before sharing or reselling upstream café internet.
- AP+station concurrency depends on the Wi-Fi adapter/driver. Some adapters cannot stay connected to upstream Wi-Fi while hosting an AP. If so, use Ethernet for uplink or a second Wi-Fi adapter.
- Some shared uplinks rewrite the TTL of all replies to 1 to block connection sharing. Locally delivered traffic ignores TTL, so the host still works, but forwarded guest traffic is dropped by the kernel's forward TTL check. Q-Spot restores a normal TTL on the uplink return path (`mangle PREROUTING`) and normalizes it on the way out.
- Authorization currently follows the client's IPv4 address. DHCP address changes, MAC randomization, and reconnect behavior need additional hardening.
- HTTPS traffic cannot be transparently redirected. Captive portal auto-popup varies by Android/iOS; manual HTTP portal URL is the fallback.
- The server currently runs as root because it changes iptables. Do not expose port 8081 on the public internet or café uplink.
- This MVP does not yet include production-grade HTTPS, CSRF protection, rate limiting, multi-admin roles, or hardened persistent admin sessions.
- The firewall logic assumes the AP interface routes to the selected uplink interface. Verify with `ip route`, `nmcli`, and the logs before using with guests.
- Keep `config.env` private; it contains the hotspot and admin passwords.
- If a start attempt fails, inspect `data/portal.log` and run `sudo ./q-spot.sh status`.

## Files

- `q-spot.sh`: one-command launcher and hotspot/firewall setup/teardown.
- `app/server.py`: portal, voucher/session database, timer enforcement, QR scan decoding, firewall repair.
- `app/index.html`: guest login page, QR camera/scan, terms checkbox.
- `app/admin.html`: admin voucher and live-session dashboard.
- `app/status.html`: guest status page with live session details.
- `app/Terms_&_Privacy.html`: Terms of Service & Acceptable Use Policy served at `/terms`.
- `.gitignore`: ignores Python caches, runtime data (voucher DB, logs, leases) and secrets.
- `qspot-manager.py`: Vim/LazyVim-inspired terminal manager.
- `config.env`: local runtime configuration (not tracked).
- `data/`: runtime state directory (not tracked).
