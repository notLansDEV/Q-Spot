#!/usr/bin/env python3
import os, json, sqlite3, secrets, string, time, threading, subprocess, re, hmac, hashlib, html
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATA = ROOT / "data"
QR_DIR = ROOT / "qr"
DB = DATA / "qspot.sqlite3"
PORT = int(os.environ.get("PORTAL_PORT", "8081"))
GATEWAY = os.environ.get("GATEWAY_IP", "10.42.0.1")
ADMIN_USER = os.environ.get("ADMIN_USER", "admin")
ADMIN_PASS = os.environ.get("ADMIN_PASS", "")
AP_IFACE = os.environ.get("AP_IFACE", "qspot0")
UPLINK = os.environ.get("UPLINK", "")
HTML_FILE = ROOT / "app" / "index.html"
STATUS_FILE = ROOT / "app" / "status.html"
ADMIN_SESSIONS = {}
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

def allow_ip(ip):
    if not re.fullmatch(r"\d{1,3}(?:\.\d{1,3}){3}", ip):
        return
    run_cmd(["iptables", "-C", "QSPOT_FORWARD", "-s", ip, "-j", "ACCEPT"])
    p = subprocess.run(["iptables", "-C", "QSPOT_FORWARD", "-s", ip, "-j", "ACCEPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if p.returncode != 0:
        run_cmd(["iptables", "-I", "QSPOT_FORWARD", "1", "-s", ip, "-j", "ACCEPT"])

def block_ip(ip):
    while True:
        p = subprocess.run(["iptables", "-D", "QSPOT_FORWARD", "-s", ip, "-j", "ACCEPT"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if p.returncode != 0:
            break
    run_cmd(["conntrack", "-D", "-s", ip])

def activate_voucher(voucher, ip):
    now = time.time()
    expires = now + int(voucher["minutes"]) * 60
    mac = mac_for(ip)
    with db() as c:
        c.execute("UPDATE vouchers SET used=1 WHERE id=?", (voucher["id"],))
        c.execute("UPDATE sessions SET active=0 WHERE ip=? AND active=1", (ip,))
        c.execute("INSERT INTO sessions(username,ip,mac,started,expires,active) VALUES(?,?,?,?,?,1)",
                  (voucher["username"], ip, mac, now, expires))
    allow_ip(ip)

def expire_worker():
    while True:
        time.sleep(3)
        now = time.time()
        with db() as c:
            rows = c.execute("SELECT id,ip FROM sessions WHERE active=1 AND expires<=?", (now,)).fetchall()
            for row in rows:
                c.execute("UPDATE sessions SET active=0 WHERE id=?", (row["id"],))
                block_ip(row["ip"])

def random_code(n=4):
    alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
    return "".join(secrets.choice(alphabet) for _ in range(n))

def create_voucher(minutes):
    for _ in range(30):
        username, password, token = random_code(4), random_code(4), secrets.token_urlsafe(24)
        try:
            with db() as c:
                cur = c.execute("INSERT INTO vouchers(username,password,token,minutes,created) VALUES(?,?,?,?,?)",
                                (username,password,token,minutes,time.time()))
                vid = cur.lastrowid
            url = f"http://{GATEWAY}:{PORT}/?token={token}"
            png = QR_DIR / f"qspot-{vid}.png"
            q = run_cmd(["qrencode", "-o", str(png), "-s", "8", "-m", "2", url])
            if not q or q.returncode != 0:
                png = None
            return {"id":vid,"username":username,"password":password,"minutes":minutes,"url":url,"qr":str(png) if png else ""}
        except sqlite3.IntegrityError:
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
        elif path == "/admin":
            if not self.admin_ok():
                self.send_html(HTML_FILE.read_text())
            else:
                self.send_html(admin_page())
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
            status["remaining"] = max(0, int(status["expires"] - now))
            self.send_json(status)
        elif path == "/api/admin/data":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            with db() as c:
                sessions = [dict(x) for x in c.execute("SELECT id,username,ip,mac,started,expires,active FROM sessions ORDER BY started DESC LIMIT 50")]
                vouchers = [dict(x) for x in c.execute("SELECT id,username,minutes,created,used,revoked FROM vouchers ORDER BY id DESC LIMIT 30")]
            self.send_json({"sessions":sessions,"vouchers":vouchers})
        elif path in ("/connected", "/status"):
            self.send_html(STATUS_FILE.read_text())
        elif path.startswith("/qr/"):
            name = Path(path).name
            if not re.fullmatch(r"qspot-\d+\.png",name): return self.send_json({"error":"Not found"},404)
            p = QR_DIR / name
            if not p.exists(): return self.send_json({"error":"Not found"},404)
            raw=p.read_bytes(); self.send_response(200); self.send_header("Content-Type","image/png"); self.send_header("Content-Length",str(len(raw))); self.end_headers(); self.wfile.write(raw)
        else:
            self.send_json({"error":"Not found"},404)
    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/api/login":
            try: data=json_body(self)
            except Exception: return self.send_json({"error":"Invalid request."},400)
            user=str(data.get("username","")).strip()
            pw=str(data.get("password",""))
            if hmac.compare_digest(user,ADMIN_USER) and hmac.compare_digest(pw,ADMIN_PASS):
                sid=secrets.token_urlsafe(32); ADMIN_SESSIONS[sid]=time.time()+8*3600
                return self.send_json({"redirect":"/admin"},headers={"Set-Cookie":f"qspot_admin={sid}; HttpOnly; SameSite=Strict; Path=/; Max-Age=28800"})
            with db() as c:
                v=c.execute("SELECT * FROM vouchers WHERE username=? AND password=? AND used=0 AND revoked=0",(user,pw)).fetchone()
            if not v: return self.send_json({"error":"Wrong username/password, or this voucher was already used."},401)
            activate_voucher(v,client_ip(self))
            self.send_json({"redirect":"/connected"})
        elif path == "/api/redeem":
            try: data=json_body(self)
            except Exception: return self.send_json({"error":"Invalid request."},400)
            token=str(data.get("token",""))
            with db() as c:
                v=c.execute("SELECT * FROM vouchers WHERE token=? AND used=0 AND revoked=0",(token,)).fetchone()
            if not v: return self.send_json({"error":"This QR voucher is invalid, expired, or already used."},401)
            activate_voucher(v,client_ip(self))
            self.send_json({"redirect":"/connected"})
        elif path == "/api/admin/voucher":
            if not self.admin_ok(): return self.send_json({"error":"Admin login required."},401)
            try: data=json_body(self); minutes=max(1,min(10080,int(data.get("minutes",60))))
            except Exception: return self.send_json({"error":"Enter a valid duration."},400)
            try: self.send_json(create_voucher(minutes))
            except Exception as e: self.send_json({"error":str(e)},500)
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

def admin_page():
    return r"""<!doctype html><html><head><meta name="viewport" content="width=device-width"><title>Q-Spot Admin</title>
<style>
*{box-sizing:border-box}body{margin:0;background:#0b1020;color:#e7ecf7;font:14px system-ui;padding:22px}
main{max-width:1000px;margin:auto}.top{display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap}
h1{margin:0;font-size:26px}p{color:#aab6cc}.panel{background:#141d31;border:1px solid #273650;border-radius:14px;padding:18px;margin:16px 0}
input,button{font:inherit;border-radius:8px;padding:10px 12px;border:1px solid #344866}input{background:#0d1526;color:white}button{background:#4d76ef;color:white;border:0;cursor:pointer;font-weight:700}
.row{display:flex;gap:8px;flex-wrap:wrap}.row input{width:130px}table{width:100%;border-collapse:collapse}th,td{text-align:left;padding:10px;border-bottom:1px solid #293750}small{color:#9caec8}.danger{background:#a83c50}.qr{max-width:220px;background:white;padding:8px;border-radius:8px}a{color:#9bb7ff}
</style></head><body><main><div class="top"><div><h1>Q-Spot / Admin</h1><p>Voucher control · live sessions · expiry enforcement</p></div><button onclick="logout()">Log out</button></div>
<section class="panel"><h2>Create one-time voucher</h2><div class="row"><input id="minutes" type="number" min="1" max="10080" value="60"><button onclick="createVoucher()">Generate voucher</button></div><p id="newmsg"></p><div id="newqr"></div></section>
<section class="panel"><h2>Active sessions</h2><div id="sessions">Loading…</div></section>
<section class="panel"><h2>Recent vouchers</h2><div id="vouchers">Loading…</div></section></main>
<script>
async function api(url,body){let r=await fetch(url,{method:body?'POST':'GET',headers:body?{'Content-Type':'application/json'}:{},body:body?JSON.stringify(body):undefined});let j=await r.json();if(!r.ok)throw Error(j.error||'Request failed');return j}
async function refresh(){try{let d=await api('/api/admin/data');document.getElementById('sessions').innerHTML='<table><tr><th>User</th><th>IP</th><th>Expires</th><th>Action</th></tr>'+d.sessions.filter(x=>x.active).map(x=>'<tr><td>'+x.username+'</td><td>'+x.ip+'</td><td>'+new Date(x.expires*1000).toLocaleString()+'</td><td><button class="danger" onclick="revoke('+x.id+')">Revoke</button></td></tr>').join('')+'</table>'||'No active sessions';document.getElementById('vouchers').innerHTML='<table><tr><th>User</th><th>Minutes</th><th>Used</th><th>Revoked</th></tr>'+d.vouchers.map(x=>'<tr><td>'+x.username+'</td><td>'+x.minutes+'</td><td>'+!!x.used+'</td><td>'+!!x.revoked+'</td></tr>').join('')+'</table>'}catch(e){document.getElementById('sessions').textContent=e.message}}
async function createVoucher(){try{let d=await api('/api/admin/voucher',{minutes:document.getElementById('minutes').value});document.getElementById('newmsg').textContent='Voucher created · '+d.minutes+' minutes';document.getElementById('newqr').innerHTML='<p><b>Username:</b> '+d.username+' &nbsp; <b>Password:</b> '+d.password+'</p>'+(d.qr?'<img class="qr" src="/qr/'+d.qr.split('/').pop()+'"><br>':'')+'<a href="'+d.url+'">'+d.url+'</a>'}catch(e){document.getElementById('newmsg').textContent=e.message}}
async function revoke(id){if(!confirm('Revoke this session?'))return;try{await api('/api/admin/revoke',{id});refresh()}catch(e){alert(e.message)}}
async function logout(){await fetch('/api/admin/logout',{method:'POST'});location.href='/'}
refresh();setInterval(refresh,5000);
</script></body></html>"""

def main():
    init_db()
    if not ADMIN_PASS:
        raise SystemExit("ADMIN_PASS is missing. Run q-spot.sh to configure the admin account.")
    threading.Thread(target=expire_worker,daemon=True).start()
    print(f"Q-Spot portal: http://{GATEWAY}:{PORT}",flush=True)
    ThreadingHTTPServer(("0.0.0.0",PORT),Handler).serve_forever()

if __name__=="__main__": main()
