#!/usr/bin/env python3
import os, sys, sqlite3, subprocess, secrets, string, time, shutil, termios, tty
from pathlib import Path
ROOT=Path(__file__).resolve().parent
DB=ROOT/"data"/"qspot.sqlite3"
QR=ROOT/"qr"
GATEWAY=os.environ.get("GATEWAY_IP","10.42.0.1")
PORT=int(os.environ.get("PORTAL_PORT","8081"))
def run(a): return subprocess.run(a,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
def code(n=5): return ''.join(secrets.choice("ABCDEFGHJKLMNPQRSTUVWXYZ23456789") for _ in range(n))
def pin(n=4): return ''.join(secrets.choice("0123456789") for _ in range(n))
def create(minutes):
    con=sqlite3.connect(DB)
    for _ in range(30):
        u,p,t=code(),pin(),secrets.token_urlsafe(24)
        try:
            cur=con.execute("INSERT INTO vouchers(username,password,token,minutes,created) VALUES(?,?,?,?,?)",(u,p,t,minutes,time.time()))
            con.commit(); vid=cur.lastrowid; break
        except sqlite3.IntegrityError: continue
    url=f"http://{GATEWAY}:{PORT}/?token={t}"
    QR.mkdir(exist_ok=True); png=QR/f"qspot-{vid}.png"
    run(["qrencode","-o",str(png),"-s","8","-m","2",url])
    con.close()
    return u,p,url,png
def active():
    con=sqlite3.connect(DB); rows=con.execute("SELECT id,username,ip,expires FROM sessions WHERE active=1 ORDER BY expires").fetchall(); con.close(); return rows
def revoke(sid):
    con=sqlite3.connect(DB); row=con.execute("SELECT ip FROM sessions WHERE id=? AND active=1",(sid,)).fetchone()
    if row:
        con.execute("UPDATE sessions SET active=0 WHERE id=?",(sid,)); con.commit()
        run(["iptables","-w","5","-D","QSPOT_FORWARD","-s",row[0],"-j","ACCEPT"])
        run(["iptables","-w","5","-t","nat","-D","PREROUTING","-s",row[0],"-p","tcp","--dport","80","-j","RETURN","-m","comment","--comment","qspot-client"])
        run(["conntrack","-D","-s",row[0]])
    con.close()
def clear():
    os.system("clear")
    print("\033[96m")
    print(" ██████                █████████                      █████")
    print("███▒▒▒▒███             ███▒▒▒▒▒███                    ▒▒███")
    print("███    ▒▒███           ▒███    ▒▒▒  ████████   ██████  ███████")
    print("▒███     ▒███ ██████████▒▒█████████ ▒▒███▒▒███ ███▒▒███▒▒▒███▒")
    print("▒███   ██▒███▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒███ ▒███ ▒███▒███ ▒███  ▒███")
    print("▒▒███ ▒▒████             ███    ▒███ ▒███ ▒███▒███ ▒███  ▒███ ███")
    print(" ▒▒▒██████▒██           ▒▒█████████  ▒███████ ▒▒██████   ▒▒█████")
    print("   ▒▒▒▒▒▒ ▒▒             ▒▒▒▒▒▒▒▒▒   ▒███▒▒▒   ▒▒▒▒▒▒     ▒▒▒▒▒")
    print("                                     ▒███")
    print("                                     █████")
    print("                                    ▒▒▒▒▒")
    print("\033[0m")
    print(" Q-SPOT  /  WIFI ACCESS MANAGER                         [j/k] move [enter] select [q] quit")
def key():
    fd=sys.stdin.fileno(); old=termios.tcgetattr(fd)
    try:
        tty.setraw(fd); c=sys.stdin.read(1)
        if c=="\x1b":
            c+=sys.stdin.read(2)
        return c
    finally: termios.tcsetattr(fd,termios.TCSADRAIN,old)
def pause(): input("\nPress Enter to return…")
def menu():
    items=["Create voucher","View active sessions","Revoke a session","Open admin URL","Quit manager"]
    selected=0
    while True:
        clear()
        print("\n  ┌─────────────────────────────────────────────────────────────────┐")
        for i,x in enumerate(items):
            marker="➤" if i==selected else " "
            print(f"  │ {marker} {x:<61}│")
        print("  └─────────────────────────────────────────────────────────────────┘")
        k=key()
        if k in ("j","\x1b[B"): selected=(selected+1)%len(items)
        elif k in ("k","\x1b[A"): selected=(selected-1)%len(items)
        elif k in ("\r","\n"):
            choice=items[selected]
            if choice=="Create voucher":
                try:
                    mins=int(input("  Duration in minutes [60]: ") or "60"); mins=max(1,min(mins,10080))
                    u,p,url,png=create(mins)
                    print(f"\n  VOUCHER CREATED\n  USERNAME : {u}\n  PASSWORD : {p}\n  DURATION : {mins} minutes\n  URL      : {url}\n  QR FILE  : {png}")
                except Exception as e: print("  Error:",e)
                pause()
            elif choice=="View active sessions":
                rows=active(); print("\n  ACTIVE SESSIONS")
                for r in rows: print(f"  ID {r[0]:<4} {r[1]:<6} {r[2]:<16} expires {time.strftime('%H:%M:%S',time.localtime(r[3]))}")
                if not rows: print("  No active sessions.")
                pause()
            elif choice=="Revoke a session":
                rows=active()
                for r in rows: print(f"  ID {r[0]}  {r[1]}  {r[2]}")
                if rows:
                    try: revoke(int(input("  Session ID to revoke: "))); print("  Revoked.")
                    except Exception as e: print("  Error:",e)
                else: print("  No active sessions.")
                pause()
            elif choice=="Open admin URL":
                url=f"http://127.0.0.1:{PORT}/admin.html"; print("  Admin:",url)
                subprocess.Popen(["xdg-open",url],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                pause()
            else: return
if __name__=="__main__":
    if not sys.stdin.isatty():
        print("Run this manager in an interactive terminal."); sys.exit(1)
    menu()
