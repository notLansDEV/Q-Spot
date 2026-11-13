#!/usr/bin/env python3
import os, json, sqlite3, secrets, string, time, threading, subprocess, re, hmac, hashlib, html, socket
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
QR_DIR = ROOT / "qr"
DB = DATA / "qspot.sqlite3"
PORT = int(os.environ.get("PORTAL_PORT", "8081"))
GATEWAY = os.environ.get("GATEWAY_IP", "10.42.0.1")
SUBNET = ".".join(GATEWAY.split(".")[:3]) + ".0/24"
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
AP_IFACE = os.environ.get("AP_IFACE", "qspot0")
UPLINK = os.environ.get("UPLINK", "")
HTML_FILE = ROOT / "app" / "index.html"
STATUS_FILE = ROOT / "app" / "status.html"
ADMIN_FILE = ROOT / "app" / "admin.html"
ADMIN_SESSIONS = {}
BYPASS_COMMENT = "qspot-client"
LOCK = threading.Lock()

def db():
    con = sqlite3.connect(DB, timeout=10)
    con.row_factory = sqlite3.Row
    return con

def init_db():
    DATA.mkdir(exist_ok=True)
    QR_DIR.mkdir(exist_ok=True)
    with db() as c:
        c.execute("""CREATE TABLE IF NOT EXISTS vouchers(
            id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT UNIQUE NOT NULL,
            password TEXT NOT NULL, token TEXT UNIQUE NOT NULL, minutes INTEGER NOT NULL,
            created REAL NOT NULL, used INTEGER NOT NULL DEFAULT 0, revoked INTEGER NOT NULL DEFAULT 0
        )""")
        c.execute("""CREATE TABLE IF NOT EXISTS sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, username TEXT NOT NULL, ip TEXT NOT NULL,
            mac TEXT, started REAL NOT NULL, expires REAL NOT NULL, active INTEGER NOT NULL DEFAULT 1
        )""")
        columns = {row["name"] for row in c.execute("PRAGMA table_info(vouchers)")}
        if "expires" not in columns:
            # Persist the absolute end time so a voucher can be used again after
            # logging out without restarting its full duration.
            c.execute("ALTER TABLE vouchers ADD COLUMN expires REAL NOT NULL DEFAULT 0")
            c.execute("UPDATE vouchers SET expires=created+minutes*60 WHERE used=1")

def run_cmd(args):
    try:
        return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=4)
    except Exception:
        return None

def client_ip(handler):
    return handler.client_address[0]

def mac_for(ip):
    p = run_cmd(["ip", "neigh", "show", ip])
    if not p or p.returncode != 0:
        return ""
    m = re.search(r"\blladdr\s+([0-9a-fA-F:]{17})", p.stdout)
    return m.group(1).lower() if m else ""

def iptables(args, timeout=10):
    try:
        return subprocess.run(["iptables", "-w", "5", *args],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              text=True, timeout=timeout)
    except Exception:
        return None

def ip_allowed(ip):
    if os.geteuid() != 0 or not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip):
        return False
    p = iptables(["-C", "QSPOT_FORWARD", "-s", ip, "-j", "ACCEPT"])
    return bool(p and p.returncode == 0)

def bypass_rule(action, ip):
    return ["-t", "nat", action, "PREROUTING", "-s", ip, "-p", "tcp", "--dport", "80",
            "-j", "RETURN", "-m", "comment", "--comment", BYPASS_COMMENT]

def check_rule(table, chain, args):
    if os.geteuid() != 0:
        return False
    p = iptables(["-t", table, "-C", chain, *args])
    return bool(p and p.returncode == 0)

def add_rule(table, chain, args, position=None):
    if os.geteuid() != 0:
        return False
    if position is None:
        command = ["-t", table, "-A", chain, *args]
    else:
        command = ["-t", table, "-I", chain, str(position), *args]
    p = iptables(command)
    return bool(p and p.returncode == 0)

def ip_forward_enabled():
    try:
        return Path("/proc/sys/net/ipv4/ip_forward").read_text().strip() == "1"
    except OSError:
        return False

def forwarding_jump_present():
    return bool(UPLINK and AP_IFACE and check_rule(
        "filter", "FORWARD", ["-i", AP_IFACE, "-o", UPLINK, "-j", "QSPOT_FORWARD"]))

def return_rule_present():
    return bool(UPLINK and AP_IFACE and check_rule(
        "filter", "FORWARD", ["-i", UPLINK, "-o", AP_IFACE, "-d", SUBNET, "-j", "ACCEPT"]))

def masquerade_present():
    return bool(UPLINK and check_rule(
        "nat", "POSTROUTING", ["-s", SUBNET, "-o", UPLINK, "-j", "MASQUERADE"]))

def inbound_ttl_present():
    """Replies from some shared uplinks arrive with TTL 1; restore a usable TTL."""
    return bool(UPLINK and check_rule(
        "mangle", "PREROUTING", ["-i", UPLINK, "-d", SUBNET, "-j", "TTL", "--ttl-set", "64"]))

def outbound_ttl_present():
    return bool(UPLINK and check_rule(
        "mangle", "POSTROUTING", ["-s", SUBNET, "-o", UPLINK, "-j", "TTL", "--ttl-set", "64"]))

def portal_bypass_present(ip):
    if os.geteuid() != 0 or not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip):
        return False
    p = iptables(bypass_rule("-C", ip))
    return bool(p and p.returncode == 0)

def internet_allowed(ip):
    return (ip_allowed(ip) and portal_bypass_present(ip)
            and ip_forward_enabled() and forwarding_jump_present()
            and return_rule_present() and masquerade_present()
            and inbound_ttl_present() and outbound_ttl_present())

def firewall_details(ip):
    return {
        "client_rule": ip_allowed(ip),
        "portal_bypass": portal_bypass_present(ip),
        "ip_forward": ip_forward_enabled(),
        "forward_jump": forwarding_jump_present(),
        "return_rule": return_rule_present(),
        "masquerade": masquerade_present(),
        "ttl_repair": inbound_ttl_present(),
        "ttl_normalize": outbound_ttl_present(),
    }

def _read_int(path):
    try:
        return int(Path(path).read_text().strip())
    except (OSError, ValueError):
        return None

def upstream_ttl():
    """Report the TTL of replies from the uplink (1 means the uplink mangles it)."""
    p = run_cmd(["ping", "-c", "1", "-W", "2", "1.1.1.1"])
    if not p or p.returncode != 0:
        return None
    m = re.search(r"ttl=(\d+)", p.stdout or "")
    return int(m.group(1)) if m else None

def upstream_reachable():
    try:
        with socket.create_connection(("1.1.1.1", 443), timeout=3):
            return True
    except OSError:
        return False

def ensure_portal_firewall():
    """Re-create the base forwarding rules if another firewall reload removed them."""
    if os.geteuid() != 0 or not (UPLINK and AP_IFACE):
        return False
    ok = True
    if not ip_forward_enabled():
        try:
            Path("/proc/sys/net/ipv4/ip_forward").write_text("1\n")
        except OSError as e:
            ok = False
            print(f"Q-Spot: could not enable IP forwarding: {e}", flush=True)
    iptables(["-N", "QSPOT_FORWARD"])
    if not check_rule("filter", "QSPOT_FORWARD",
                      ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"]):
        ok = add_rule("filter", "QSPOT_FORWARD",
                      ["-m", "conntrack", "--ctstate", "ESTABLISHED,RELATED", "-j", "ACCEPT"]) and ok
    if not check_rule("filter", "QSPOT_FORWARD", ["-j", "DROP"]):
        ok = add_rule("filter", "QSPOT_FORWARD", ["-j", "DROP"]) and ok
    if not forwarding_jump_present():
        ok = add_rule("filter", "FORWARD",
                      ["-i", AP_IFACE, "-o", UPLINK, "-j", "QSPOT_FORWARD"], 1) and ok
    if not return_rule_present():
        ok = add_rule("filter", "FORWARD",
                      ["-i", UPLINK, "-o", AP_IFACE, "-d", SUBNET, "-j", "ACCEPT"], 1) and ok
    if not masquerade_present():
        ok = add_rule("nat", "POSTROUTING",
                      ["-s", SUBNET, "-o", UPLINK, "-j", "MASQUERADE"]) and ok
    if not inbound_ttl_present():
        ok = add_rule("mangle", "PREROUTING",
                      ["-i", UPLINK, "-d", SUBNET, "-j", "TTL", "--ttl-set", "64"], 1) and ok
    if not outbound_ttl_present():
        ok = add_rule("mangle", "POSTROUTING",
                      ["-s", SUBNET, "-o", UPLINK, "-j", "TTL", "--ttl-set", "64"]) and ok
    # Keep the portal redirect below per-client RETURN rules so authorized
    # clients are never sent back to the login page.
    if not check_rule("nat", "PREROUTING",
                      ["-i", AP_IFACE, "-p", "tcp", "--dport", "80",
                       "-j", "REDIRECT", "--to-ports", str(PORT)]):
        ok = add_rule("nat", "PREROUTING",
                      ["-i", AP_IFACE, "-p", "tcp", "--dport", "80",
                       "-j", "REDIRECT", "--to-ports", str(PORT)]) and ok
    return ok

def allow_ip(ip):
    if os.geteuid() != 0 or not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip):
        return False
    ok = True
    changed = False
    if not ip_allowed(ip):
        p = iptables(["-I", "QSPOT_FORWARD", "1", "-s", ip, "-j", "ACCEPT"])
        if not p or p.returncode != 0:
            ok = False
            detail = (p.stderr or p.stdout).strip() if p else "iptables could not be run"
            print(f"Q-Spot: could not allow forwarding for {ip}: {detail}", flush=True)
        else:
            changed = True
    if not portal_bypass_present(ip):
        p = iptables(bypass_rule("-I", ip))
        if not p or p.returncode != 0:
            ok = False
            detail = (p.stderr or p.stdout).strip() if p else "iptables could not be run"
            print(f"Q-Spot: could not bypass the captive portal for {ip}: {detail}", flush=True)
        else:
            changed = True
    # Connections opened before authorization are still tracked as redirects to
    # the portal. Drop those entries after allowing the IP, whether or not the
    # firewall rules were already present (e.g. re-login on the same IP).
    flush = run_cmd(["conntrack", "-D", "-s", ip])
    if flush is None:
        print(f"Q-Spot: conntrack flush failed for {ip} (conntrack may be unavailable)", flush=True)
    elif flush.returncode not in (0, 1):
        print(f"Q-Spot: conntrack flush for {ip} returned {flush.returncode}: {(flush.stderr or '').strip()}", flush=True)
    return ok

def block_ip(ip):
    if os.geteuid() != 0:
        return
    while True:
        p = iptables(["-D", "QSPOT_FORWARD", "-s", ip, "-j", "ACCEPT"])
        if not p or p.returncode != 0:
            break
    while True:
        p = iptables(bypass_rule("-D", ip))
        if not p or p.returncode != 0:
            break
    run_cmd(["conntrack", "-D", "-s", ip])

def activate_voucher(voucher, ip):
    now = time.time()
    expires = float(voucher["expires"] or 0)
    if not int(voucher["used"]):
        expires = now + int(voucher["minutes"]) * 60
    elif expires <= now:
        return False
    mac = mac_for(ip)
    with db() as c:
        c.execute("UPDATE vouchers SET used=1, expires=? WHERE id=?", (expires, voucher["id"]))
        c.execute("UPDATE sessions SET active=0 WHERE ip=? AND active=1", (ip,))
        c.execute("INSERT INTO sessions(username,ip,mac,started,expires,active) VALUES(?,?,?,?,?,1)",
                  (voucher["username"], ip, mac, now, expires))
    ensure_portal_firewall()
    if not allow_ip(ip):
        print(f"Q-Spot: session for {voucher['username']} is active, but the firewall rule for {ip} is missing.", flush=True)
    # Force-clear any stale conntrack entries that survived the allow_ip flush.
    run_cmd(["conntrack", "-D", "-s", ip])
    run_cmd(["conntrack", "-D", "--orig-src", ip])
    return True

def expire_worker():
    while True:
        time.sleep(3)
        now = time.time()
        with db() as c:
            rows = c.execute("SELECT id,ip FROM sessions WHERE active=1 AND expires<=?", (now,)).fetchall()
            for row in rows:
                c.execute("UPDATE sessions SET active=0 WHERE id=?", (row["id"],))
                block_ip(row["ip"])

def enforce_worker():
    # Re-apply the base forwarding path and per-client ACCEPT rules if another
    # firewall reload removed them.
    while True:
        time.sleep(10)
        try:
            ensure_portal_firewall()
            now = time.time()
            with db() as c:
                rows = c.execute("SELECT DISTINCT ip FROM sessions WHERE active=1 AND expires>?", (now,)).fetchall()
            for row in rows:
                allow_ip(row["ip"])
        except Exception as e:
            print(f"Q-Spot: firewall rule refresh failed: {e}", flush=True)

def random_code(n=5):
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(n))

def random_pin(n=4):
    return "".join(secrets.choice(string.digits) for _ in range(n))

def create_voucher(minutes, username="", password=""):
    username = str(username).strip().upper()
    password = str(password)
    if username and not re.fullmatch(r"[A-Za-z0-9]{5}", username):
        raise ValueError("Voucher code must be exactly 5 letters or numbers.")
    if password and not re.fullmatch(r"[0-9]{4}", password):
        raise ValueError("Voucher password must be exactly 4 numbers.")
    if username and not password:
        raise ValueError("A password is required when you choose a voucher code.")
    for _ in range(30):
        user = username or random_code(5)
        passwd = password or random_pin(4)
        token = secrets.token_urlsafe(24)
        try:
            with db() as c:
                cur = c.execute("INSERT INTO vouchers(username,password,token,minutes,created) VALUES(?,?,?,?,?)",
                                (user,passwd,token,minutes,time.time()))
                vid = cur.lastrowid
            url = f"http://{GATEWAY}:{PORT}/?token={token}"
            png = QR_DIR / f"qspot-{vid}.png"
            q = run_cmd(["qrencode", "-o", str(png), "-s", "8", "-m", "2", url])
            if not q or q.returncode != 0:
                png = None
            return {"id":vid,"username":user,"password":passwd,"minutes":minutes,"url":url,"qr":str(png) if png else ""}
        except sqlite3.IntegrityError:
            if username:
                raise ValueError("That voucher code is already in use.")
            continue
    raise RuntimeError("Could not generate a unique voucher.")

def json_body(h):
    n = int(h.headers.get("Content-Length", "0"))
    if n > 1024*1024:
        raise ValueError("Request too large.")
    return json.loads(h.rfile.read(n) or b"{}")

class Handler(BaseHTTPRequestHandler):
    server_version = "Q-Spot/1.0"
    def log_message(self, fmt, *args):
        print("Q-Spot:", fmt % args, flush=True)
    def send_json(self, data, status=200, headers=None):
        raw = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type","application/json; charset=utf-8")
        self.send_header("Content-Length",str(len(raw)))
        self.send_header("Cache-Control","no-store")
        if headers:
            for k,v in headers.items(): self.send_header(k,v)
        self.end_headers()
        self.wfile.write(raw)
    def send_html(self, content, status=200, headers=None):
        raw = content.encode()
        self.send_response(status)
        self.send_header("Content-Type","text/html; charset=utf-8")
        self.send_header("Content-Length",str(len(raw)))
        self.send_header("Cache-Control","no-store")
        if headers:
            for k,v in headers.items(): self.send_header(k,v)
        self.end_headers()
        self.wfile.write(raw)
    def admin_ok(self):
        cookie = self.headers.get("Cookie","")
        sid = ""
        for part in cookie.split(";"):
            if part.strip().startswith("qspot_admin="):
                sid = part.strip().split("=",1)[1]
        expiry = ADMIN_SESSIONS.get(sid, 0)
        return bool(sid and expiry > time.time())
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html", "/login"):
            self.send_html(HTML_FILE.read_text())
        elif path in ("/admin", "/admin.html"):
            if not self.admin_ok():
                self.send_response(302)
                self.send_header("Location", "/")
                self.end_headers()
                return
            self.send_html(ADMIN_FILE.read_text())
        elif path == "/api/status":
            ip = client_ip(self)
            now = time.time()
            with db() as c:
                row = c.execute(
                    "SELECT username,ip,mac,started,expires,active FROM sessions WHERE ip=? ORDER BY id DESC LIMIT 1",
                    (ip,),
                ).fetchone()
            if not row:
                return self.send_json({"active": False})
            status = dict(row)
            status["active"] = bool(status["active"]) and status["expires"] > now
            status["remaining"] = max(0, int(status["expires"] - now)) if status["active"] else 0
            if status["active"]:
                ensure_portal_firewall()
                allow_ip(ip)
                status["internet"] = internet_allowed(ip)
                status["firewall"] = firewall_details(ip)
            else:
                status["internet"] = False
                status["firewall"] = {}
            self.send_json(status)
        elif path == "/api/admin/data":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            with db() as c:
                sessions = [dict(x) for x in c.execute("SELECT id,username,ip,mac,started,expires,active FROM sessions ORDER BY started DESC LIMIT 50")]
                vouchers = [dict(x) for x in c.execute("SELECT id,username,password,minutes,created,used,revoked,expires FROM vouchers ORDER BY id DESC LIMIT 100")]
            for voucher in vouchers:
                qr = QR_DIR / f"qspot-{voucher['id']}.png"
                voucher["qr"] = f"/qr/{qr.name}" if qr.exists() else ""
            self.send_json({"sessions":sessions,"vouchers":vouchers})
        elif path == "/api/diag":
            # Loopback-only diagnostic used to inspect the live forwarding path.
            if client_ip(self) not in ("127.0.0.1", "::1"):
                return self.send_json({"error":"Not found"},404)
            def rules(args):
                p = run_cmd(["iptables", "-w", "5", *args])
                return p.stdout.strip().splitlines() if p and p.returncode == 0 else []
            conn = run_cmd(["conntrack", "-L"])
            conn_lines = conn.stdout.strip().splitlines() if conn and conn.returncode == 0 else []
            self.send_json({
                "uplink": UPLINK, "ap": AP_IFACE, "subnet": SUBNET, "portal_port": PORT,
                "ip_forward": ip_forward_enabled(),
                "forward_jump": forwarding_jump_present(),
                "return_rule": return_rule_present(),
                "masquerade": masquerade_present(),
                "ttl_repair": inbound_ttl_present(),
                "ttl_normalize": outbound_ttl_present(),
                "upstream_ttl": upstream_ttl(),
                "upstream": upstream_reachable(),
                "conntrack_count": len(conn_lines),
                "conntrack_max": _read_int("/proc/sys/net/netfilter/nf_conntrack_max"),
                "conntrack_for_client": [l for l in conn_lines if "10.42.0." in l][:30],
                "docker_chains": rules(["-S", "DOCKER"]),
                "docker_user": rules(["-S", "DOCKER-USER"]),
                "docker_forward": rules(["-S", "DOCKER-FORWARD"]),
                "input_chain": rules(["-S", "INPUT"]),
                "forward": rules(["-S", "FORWARD"]),
                "voucher_chain": rules(["-S", "QSPOT_FORWARD"]),
                "nat_prerouting": rules(["-t", "nat", "-S", "PREROUTING"]),
                "nat_postrouting": rules(["-t", "nat", "-S", "POSTROUTING"]),
                "nat_docker": rules(["-t", "nat", "-S", "DOCKER"]),
                "mangle_prerouting": rules(["-t", "mangle", "-S", "PREROUTING"]),
                "mangle_postrouting": rules(["-t", "mangle", "-S", "POSTROUTING"]),
            })
        elif path in ("/connected", "/connected.html", "/status", "/status.html"):
            self.send_html(STATUS_FILE.read_text())
        elif path.startswith("/qr/"):
            name = Path(path).name
            if not re.fullmatch(r"qspot-\d+\.png",name): return self.send_json({"error":"Not found"},404)
            p = QR_DIR / name
            if not p.exists(): return self.send_json({"error":"Not found"},404)
            raw=p.read_bytes(); self.send_response(200); self.send_header("Content-Type","image/png"); self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
        else:
            self.send_response(302)
            self.send_header("Location", f"http://{GATEWAY}:{PORT}/")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            try: data=json_body(self)
            except Exception: return self.send_json({"error":"Invalid request."},400)
            user=str(data.get("username","")).strip()
            pw=str(data.get("password",""))
            if hmac.compare_digest(user,ADMIN_USER) and hmac.compare_digest(pw,ADMIN_PASS):
                sid=secrets.token_urlsafe(32); ADMIN_SESSIONS[sid]=time.time()+8*3600
                return self.send_json({"redirect":"/admin.html"},headers={"Set-Cookie":f"qspot_admin={sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800"})
            with db() as c:
                v=c.execute("SELECT * FROM vouchers WHERE username=? AND password=? AND revoked=0",(user.upper(),pw)).fetchone()
            if not v: return self.send_json({"error":"Wrong username or password."},401)
            if int(v["used"]) and float(v["expires"] or 0) <= time.time():
                return self.send_json({"error":"This voucher has expired."},401)
            if not activate_voucher(v,client_ip(self)):
                return self.send_json({"error":"This voucher has expired."},401)
            self.send_json({"redirect":"/status.html"})
        elif path == "/api/redeem":
            try: data=json_body(self)
            except Exception: return self.send_json({"error":"Invalid request."},400)
            token=str(data.get("token",""))
            with db() as c:
                v=c.execute("SELECT * FROM vouchers WHERE token=? AND revoked=0",(token,)).fetchone()
            if not v: return self.send_json({"error":"This QR voucher is invalid or has been revoked."},401)
            if int(v["used"]) and float(v["expires"] or 0) <= time.time():
                return self.send_json({"error":"This QR voucher has expired."},401)
            if not activate_voucher(v,client_ip(self)):
                return self.send_json({"error":"This QR voucher has expired."},401)
            self.send_json({"redirect":"/status.html"})
        elif path == "/api/logout":
            ip=client_ip(self)
            with db() as c:
                rows=c.execute("SELECT id FROM sessions WHERE ip=? AND active=1",(ip,)).fetchall()
                for row in rows:
                    c.execute("UPDATE sessions SET active=0 WHERE id=?",(row["id"],))
            if rows:
                block_ip(ip)
            self.send_json({"ok":True})
        elif path == "/api/admin/voucher":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            try:
                data=json_body(self)
                minutes=max(1,min(10080,int(data.get("minutes",60))))
                username=str(data.get("username","")).strip()
                password=str(data.get("password",""))
            except Exception: return self.send_json({"error":"Enter a valid voucher and duration."},400)
            try: self.send_json(create_voucher(minutes,username,password))
            except ValueError as e: self.send_json({"error":str(e)},400)
            except Exception as e: self.send_json({"error":str(e)},500)
        elif path == "/api/admin/update":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            try:
                data=json_body(self)
                vid=int(data.get("id"))
                username=str(data.get("username","")).strip().upper()
                password=str(data.get("password",""))
                minutes=max(1,min(10080,int(data.get("minutes",60))))
            except Exception: return self.send_json({"error":"Enter valid voucher details."},400)
            if not username or not password:
                return self.send_json({"error":"Voucher code and password are required."},400)
            if not re.fullmatch(r"[A-Za-z0-9]{5}", username):
                return self.send_json({"error":"Voucher code must be exactly 5 letters or numbers."},400)
            if not re.fullmatch(r"[0-9]{4}", password):
                return self.send_json({"error":"Voucher password must be exactly 4 numbers."},400)
            with db() as c:
                old=c.execute("SELECT username,minutes,expires FROM vouchers WHERE id=?",(vid,)).fetchone()
                if not old: return self.send_json({"error":"Voucher not found."},404)
                clash=c.execute("SELECT id FROM vouchers WHERE username=? AND id<>?",(username,vid)).fetchone()
                if clash: return self.send_json({"error":"That voucher code is already in use."},400)
                now=time.time()
                if old["expires"] and int(old["minutes"])==minutes:
                    expires=float(old["expires"])
                elif old["expires"]:
                    expires=now+minutes*60
                else:
                    expires=0
                c.execute("UPDATE vouchers SET username=?,password=?,minutes=?,expires=? WHERE id=?",
                          (username,password,minutes,expires,vid))
                c.execute("UPDATE sessions SET username=? WHERE username=?",(username,old["username"]))
                if expires:
                    c.execute("UPDATE sessions SET expires=? WHERE username=? AND active=1",(expires,username))
            self.send_json({"ok":True})
        elif path == "/api/admin/delete":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            try: data=json_body(self); vid=int(data.get("id"))
            except Exception: return self.send_json({"error":"Invalid voucher."},400)
            with db() as c:
                voucher=c.execute("SELECT username FROM vouchers WHERE id=?",(vid,)).fetchone()
                if not voucher: return self.send_json({"error":"Voucher not found."},404)
                rows=c.execute("SELECT ip FROM sessions WHERE username=? AND active=1",(voucher["username"],)).fetchall()
                c.execute("UPDATE sessions SET active=0 WHERE username=? AND active=1",(voucher["username"],))
                c.execute("DELETE FROM vouchers WHERE id=?",(vid,))
            for row in rows:
                block_ip(row["ip"])
            qr=QR_DIR / f"qspot-{vid}.png"
            try: qr.unlink()
            except OSError: pass
            self.send_json({"ok":True})
        elif path == "/api/admin/revoke":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            try: data=json_body(self); sid=int(data.get("id"))
            except Exception: return self.send_json({"error":"Invalid session."},400)
            with db() as c:
                row=c.execute("SELECT ip FROM sessions WHERE id=? AND active=1",(sid,)).fetchone()
                if row:
                    c.execute("UPDATE sessions SET active=0 WHERE id=?",(sid,))
                    block_ip(row["ip"])
            self.send_json({"ok":True})
        elif path == "/api/admin/logout":
            cookie=self.headers.get("Cookie","")
            sid=""
            for part in cookie.split(";"):
                if part.strip().startswith("qspot_admin="): sid=part.strip().split("=",1)[1]
            ADMIN_SESSIONS.pop(sid,None)
            self.send_json({"ok":True},headers={"Set-Cookie":"qspot_admin=; HttpOnly; Path=/; Max-Age=0"})
        elif path == "/api/scan":
            # Mobile browsers can open their native camera via input[capture] even on a local HTTP portal.
            # Decode the captured image on the gateway with zbarimg.
            length=int(self.headers.get("Content-Length","0"))
            if length > 8*1024*1024: return self.send_json({"error":"Image is too large."},413)
            body=self.rfile.read(length)
            boundary=self.headers.get("Content-Type","").split("boundary=")[-1].encode()
            if not boundary: return self.send_json({"error":"Missing image."},400)
            chunks=body.split(b"--"+boundary)
            payload=None
            for chunk in chunks:
                if b"filename=" in chunk:
                    payload=chunk.split(b"\r\n\r\n",1)[-1].rsplit(b"\r\n",1)[0]
                    break
            if not payload: return self.send_json({"error":"No image was uploaded."},400)
            tmp=DATA/"scan-upload.bin"; tmp.write_bytes(payload)
            p=run_cmd(["zbarimg","--quiet","--raw",str(tmp)])
            try: tmp.unlink()
            except: pass
            if not p or p.returncode != 0: return self.send_json({"error":"Could not decode that image. Try a clearer QR photo."},422)
            value=p.stdout.strip()
            m=re.search(r"[?&]token=([A-Za-z0-9_-]+)",value)
            if not m: return self.send_json({"error":"That QR code is not a Q-Spot voucher."},422)
            self.send_json({"token":m.group(1)})
        else:
            self.send_json({"error":"Not found"},404)

def main():
    init_db()
    if not ADMIN_PASS:
        raise SystemExit("ADMIN_PASS is missing. Run q-spot.sh to configure the admin account.")
    ensure_portal_firewall()
    threading.Thread(target=expire_worker,daemon=True).start()
    threading.Thread(target=enforce_worker,daemon=True).start()
    print(f"Q-Spot portal: http://{GATEWAY}:{PORT}",flush=True)
    ThreadingHTTPServer(("0.0.0.0",PORT),Handler).serve_forever()

if __name__=="__main__": main()
