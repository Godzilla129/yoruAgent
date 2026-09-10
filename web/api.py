#!/usr/bin/env python3
"""
Dashboard API and storage.

Run:
    pip install fastapi uvicorn
    uvicorn api:app --host 127.0.0.1 --port 8000

Data flows in ONE direction, deliberately:

    agent  --POST /api/laporan-->  dashboard      (agent sends state)
    agent  --GET  /api/keputusan-> dashboard      (agent collects answers)

The dashboard NEVER contacts a guarded server. So that server never has to
open a port for the dashboard, and if the dashboard is breached the worst an
attacker can do is approve a control that ALREADY EXISTS in the catalog - they
cannot make the server do anything new.

Never reverse this direction for convenience.

Note on names: the JSON fields, the four action verbs and the SQLite column
names stay in Indonesian on purpose. They are the product's shared vocabulary,
documented in contract/report.md and written into databases that already
exist. Renaming them would break upgrades for no gain.
"""

import asyncio
import json
import os
import re
import socket
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Any, Dict, Optional

from fastapi import Body, FastAPI, Header, HTTPException, Request
from fastapi.responses import HTMLResponse, JSONResponse

HERE = Path(__file__).resolve().parent
DB_FILE = Path(os.environ.get("YORU_DB", HERE / "yoru.db"))
PAGE = HERE / "dashboard.html"

# Shared with the agent through DASHBOARD_TOKEN in /etc/yoru/yoru.conf.
# Empty means no check at all; that is for trying it out on your own laptop.
TOKEN = os.environ.get("YORU_TOKEN", "").strip()

YORUCTL = os.environ.get("YORUCTL", "/opt/yoru/bin/yoructl")

# K07 and K08 install packages through apt. On a new server with a slow link
# the download alone can pass three minutes, before counting up to 60 seconds
# waiting for the dpkg lock. The old 200-second limit ran out far too often.
TIME_LIMIT = int(os.environ.get("YORU_BATAS_WAKTU", "600"))

LOG_DIR = Path(os.environ.get("YORU_LOG", "/var/log/yoru"))
CONFIG_FILE = Path(os.environ.get("YORU_KONF", "/etc/yoru/yoru.conf"))

CONTROL_RE = re.compile(r"^K(?:0[1-9]|10)$")
VALID_DECISIONS = {"setuju", "tolak", "sah", "kembalikan"}
ACTIONS = {"periksa": "periksa", "audit": "periksa",
           "terapkan": "terapkan", "hardening": "terapkan",
           "kembalikan": "kembalikan", "rollback": "kembalikan",
           "verifikasi": "verifikasi"}

# Keys the settings page may write. This list must match the one in yoructl -
# yoructl is what actually enforces it, because yoructl is what runs as root.
# The copy here only keeps the page from offering a key that would be refused.
SETTABLE_KEYS = ("TELEGRAM_TOKEN", "TELEGRAM_CHAT_ID", "HERMES_URL", "HERMES_TOKEN",
                 "AI_MODEL",
                 "NAMA_SERVER", "PORT_DIIZINKAN", "LEWATI_KONTROL",
                 "JAM_PENJAGAAN", "ZONA_WAKTU")
SECRET_KEYS = ("TELEGRAM_TOKEN", "HERMES_TOKEN")

# Same table as STATUS_MAP in bin/yoru-agent, so a button result and a cycle
# result speak the same vocabulary.
STATUS_MAP = {"LULUS": "LULUS", "GAGAL": "GAGAL", "DILEWATI": "DILEWATI",
              "DIKEMBALIKAN": "DILEWATI", "DITOLAK": "ERROR",
              "ERROR": "ERROR", "PERINGATAN": "ERROR", "MENUNGGU": "ERROR"}

app = FastAPI(title="Yoru Dashboard", version="0.2.0")


# -------------------------------------------------------------------- storage
def db():
    conn = sqlite3.connect(DB_FILE, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    with closing(db()) as conn, conn:
        conn.execute("""CREATE TABLE IF NOT EXISTS laporan (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server TEXT NOT NULL,
            waktu TEXT NOT NULL,
            siklus TEXT NOT NULL,
            skor INTEGER NOT NULL,
            isi TEXT NOT NULL,
            diterima REAL NOT NULL)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS keputusan (
            server TEXT NOT NULL,
            kontrol TEXT NOT NULL,
            nilai TEXT NOT NULL,
            catatan TEXT,
            dibuat REAL NOT NULL,
            diambil INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, kontrol))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS port (
            server TEXT NOT NULL,
            port INTEGER NOT NULL,
            keterangan TEXT,
            dibuat REAL NOT NULL,
            diambil INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, port))""")
        conn.execute("CREATE INDEX IF NOT EXISTS i_laporan ON laporan(server, diterima DESC)")


init_db()


# ------------------------------------------------------------------- identity
def check_token(given: Optional[str]):
    if not TOKEN:
        return
    expected = f"Bearer {TOKEN}"
    # Fixed-time comparison so how long the check takes cannot leak how many
    # leading characters of the token were already right.
    import hmac
    if not given or not hmac.compare_digest(given, expected):
        raise HTTPException(status_code=401, detail="token tidak sah")


def from_this_machine(req: Request) -> bool:
    return bool(req.client) and req.client.host in ("127.0.0.1", "::1")


def require_write_access(req: Request, given: Optional[str]):
    """Guards every endpoint that ends in a change on a real server.

    From the machine itself: open - anyone who can reach 127.0.0.1 already has
    access to that server. From the network: a token is required, and an empty
    token means refused, not exempt. Without this rule anyone who can reach the
    port could press Hardening on someone else's server.
    """
    if from_this_machine(req):
        return
    if not TOKEN:
        raise HTTPException(
            status_code=403,
            detail="dashboard dibuka ke jaringan tapi DASHBOARD_TOKEN kosong - "
                   "isi dulu di /etc/yoru/yoru.conf, atau buka lewat 127.0.0.1")
    check_token(given)


def read_config() -> Dict[str, str]:
    """Read as text, never sourced. A value containing $(...) would otherwise
    run in a process holding the tokens, and this file holds them."""
    config: Dict[str, str] = {}
    try:
        text = CONFIG_FILE.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return config
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, val = line.split("=", 1)
        config[key.strip()] = val.strip().strip('"')
    return config


def local_server_name() -> str:
    """The name the agent on this machine uses - worked out exactly the way the
    agent works it out. The buttons only touch this machine, so another
    server's report must never be edited by them."""
    return (read_config().get("NAMA_SERVER") or "").strip() or socket.gethostname()


# ------------------------------------------------------------------ endpoints
@app.post("/api/laporan")
async def receive_report(laporan: Dict[str, Any] = Body(...),
                         authorization: Optional[str] = Header(None)):
    check_token(authorization)

    for field in ("versi_kontrak", "server", "waktu", "siklus", "ringkasan", "kontrol"):
        if field not in laporan:
            raise HTTPException(status_code=422, detail=f"field '{field}' tidak ada")

    name = str((laporan.get("server") or {}).get("nama") or "tanpa-nama")[:100]
    with closing(db()) as conn, conn:
        conn.execute(
            "INSERT INTO laporan (server, waktu, siklus, skor, isi, diterima) VALUES (?,?,?,?,?,?)",
            (name, str(laporan["waktu"]), str(laporan["siklus"]),
             int((laporan.get("ringkasan") or {}).get("skor") or 0),
             json.dumps(laporan, ensure_ascii=False), time.time()),
        )
        # Decisions the agent already collected are dropped so they are not
        # carried out twice on the next cycle.
        conn.execute("DELETE FROM keputusan WHERE server=? AND diambil=1", (name,))
        conn.execute("DELETE FROM port WHERE server=? AND diambil=1", (name,))
    return {"ok": True, "server": name}


@app.get("/api/laporan")
async def latest_report(server: Optional[str] = None):
    with closing(db()) as conn:
        if server:
            row = conn.execute("SELECT isi FROM laporan WHERE server=? ORDER BY diterima DESC LIMIT 1",
                               (server,)).fetchone()
        else:
            row = conn.execute("SELECT isi FROM laporan ORDER BY diterima DESC LIMIT 1").fetchone()
    if not row:
        return JSONResponse({"kosong": True,
                             "pesan": "belum ada laporan masuk - jalankan agent dulu"},
                            status_code=404)
    return json.loads(row["isi"])


@app.get("/api/server")
async def server_list():
    with closing(db()) as conn:
        rows = conn.execute(
            "SELECT server, MAX(diterima) d, COUNT(*) n FROM laporan GROUP BY server ORDER BY d DESC"
        ).fetchall()
    return {"server": [{"nama": r["server"], "laporan": r["n"], "terakhir": r["d"]} for r in rows]}


@app.get("/api/riwayat")
async def history(server: Optional[str] = None, batas: int = 30):
    batas = max(1, min(batas, 200))
    with closing(db()) as conn:
        if server:
            rows = conn.execute(
                "SELECT waktu, siklus, skor FROM laporan WHERE server=? ORDER BY diterima DESC LIMIT ?",
                (server, batas)).fetchall()
        else:
            rows = conn.execute(
                "SELECT waktu, siklus, skor FROM laporan ORDER BY diterima DESC LIMIT ?",
                (batas,)).fetchall()
    return {"riwayat": [dict(r) for r in rows]}


@app.post("/api/keputusan")
async def store_decision(req: Request, badan: Dict[str, Any] = Body(...),
                         authorization: Optional[str] = Header(None)):
    """The owner's answer from the dashboard.

    Stored, not executed. The agent on the server is still what carries it out,
    through yoructl - the dashboard never touches anyone's server.
    """
    require_write_access(req, authorization)
    server = str(badan.get("server") or "").strip()[:100]
    control = str(badan.get("kontrol") or "").strip().upper()
    value = str(badan.get("nilai") or "").strip().lower()

    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")
    if not CONTROL_RE.match(control):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if value not in VALID_DECISIONS:
        raise HTTPException(status_code=422,
                            detail=f"nilai harus salah satu dari {sorted(VALID_DECISIONS)}")

    with closing(db()) as conn, conn:
        conn.execute("""INSERT INTO keputusan (server, kontrol, nilai, catatan, dibuat, diambil)
                        VALUES (?,?,?,?,?,0)
                        ON CONFLICT(server, kontrol) DO UPDATE SET
                          nilai=excluded.nilai, catatan=excluded.catatan,
                          dibuat=excluded.dibuat, diambil=0""",
                     (server, control, value, str(badan.get("catatan") or "")[:500], time.time()))
    return {"ok": True, "server": server, "kontrol": control, "nilai": value}


@app.post("/api/port")
async def store_ports(req: Request, badan: Dict[str, Any] = Body(...),
                      authorization: Optional[str] = Header(None)):
    """The owner answering "yes, that port is mine"."""
    require_write_access(req, authorization)
    server = str(badan.get("server") or "").strip()[:100]
    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")

    accepted = []
    with closing(db()) as conn, conn:
        for p in (badan.get("port") or []):
            try:
                n = int(p)
            except (TypeError, ValueError):
                continue
            if not 1 <= n <= 65535:
                continue
            conn.execute("""INSERT INTO port (server, port, keterangan, dibuat, diambil)
                            VALUES (?,?,?,?,0)
                            ON CONFLICT(server, port) DO UPDATE SET diambil=0""",
                         (server, n, str(badan.get("keterangan") or "")[:200], time.time()))
            accepted.append(n)
    return {"ok": True, "port": accepted}


@app.get("/api/keputusan")
async def decisions_for_agent(server: Optional[str] = None,
                              authorization: Optional[str] = Header(None)):
    """Collected by the agent each cycle. Marks them taken; does not delete.

    Deleting here would lose the decision whenever the agent dies mid-run
    before carrying it out - and the owner would never know their answer
    evaporated. Deletion happens when the next report arrives, which means the
    agent did finish.
    """
    check_token(authorization)
    with closing(db()) as conn, conn:
        if server:
            decisions = conn.execute("SELECT kontrol, nilai FROM keputusan WHERE server=?",
                                     (server,)).fetchall()
            ports = conn.execute("SELECT port FROM port WHERE server=?", (server,)).fetchall()
            conn.execute("UPDATE keputusan SET diambil=1 WHERE server=?", (server,))
            conn.execute("UPDATE port SET diambil=1 WHERE server=?", (server,))
        else:
            decisions = conn.execute("SELECT kontrol, nilai FROM keputusan").fetchall()
            ports = conn.execute("SELECT port FROM port").fetchall()
            conn.execute("UPDATE keputusan SET diambil=1")
            conn.execute("UPDATE port SET diambil=1")
    return {"keputusan": {r["kontrol"]: r["nilai"] for r in decisions},
            "port_disetujui": [r["port"] for r in ports]}


# -------------------------------------------------------- running via yoructl
async def run_yoructl(kid: str, action: str) -> Dict[str, Any]:
    """One call to yoructl. One program, fixed arguments - no shell."""
    cmd = ["sudo", "-n", YORUCTL, kid, action]
    if os.geteuid() == 0:
        cmd = [YORUCTL, kid, action]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as e:
        return {"id": kid, "tindakan": action, "status": "ERROR", "berhasil": False,
                "nilai": None, "pesan": f"tidak bisa menjalankan {YORUCTL}: {e}"}

    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIME_LIMIT)
    except asyncio.TimeoutError:
        # The process is deliberately NOT killed. If this is K07 or K08 what is
        # running is apt, and killing apt halfway leaves dpkg in a half state -
        # far more trouble than waiting.
        #
        # And the message must never be empty. An earlier version wrote f"{e}",
        # but str(asyncio.TimeoutError()) is the empty string - so the screen
        # showed the word "ERROR" and not one word of why.
        return {"id": kid, "tindakan": action, "status": "MENUNGGU", "berhasil": False,
                "nilai": None,
                "pesan": f"sudah {TIME_LIMIT} detik dan belum selesai - biasanya apt "
                         f"masih mengunduh. Tindakannya TETAP JALAN di server, tidak "
                         f"dibatalkan. Tunggu sebentar lalu tekan Audit untuk melihat "
                         f"hasilnya, atau lihat Audit Logs."}

    for line in reversed([b for b in out.decode("utf-8", "replace").splitlines() if b.strip()]):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return {"id": kid, "tindakan": action, "status": "ERROR", "berhasil": False,
            "nilai": None,
            "pesan": (err.decode("utf-8", "replace").strip() or "yoructl tidak menjawab")[:300]}


@app.post("/api/jalankan")
async def run_action(req: Request, badan: Dict[str, Any] = Body(...),
                     authorization: Optional[str] = Header(None)):
    require_write_access(req, authorization)
    kid = str(badan.get("kontrol") or "").strip().upper()
    action = ACTIONS.get(str(badan.get("aksi") or "").strip().lower())
    if not CONTROL_RE.match(kid):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if not action:
        raise HTTPException(status_code=422, detail="tindakan tidak dikenal")

    result = await run_yoructl(kid, action)
    if result.get("berhasil") is True:
        if action in ("terapkan", "kembalikan"):
            # The row's status is read back, not inferred from "apply
            # succeeded". Same rule verification uses: what we report has to be
            # the state actually in force now, not the intent we just had.
            # Without this a row that was just rolled back would be recorded as
            # DILEWATI instead of GAGAL.
            check = await run_yoructl(kid, "periksa")
            refresh_stored_report(kid, check if check.get("berhasil") is True else result)
        else:
            refresh_stored_report(kid, result)
    return result


def refresh_stored_report(kid: str, result: Dict[str, Any]):
    """Bring the stored report in line with what was just measured.

    Without this the cards at the top of the dashboard only move after the next
    agent cycle - so someone presses Hardening, the control really does change,
    and the "Lolos Audit" number sits still as if the button did nothing.
    """
    status = STATUS_MAP.get(str(result.get("status") or "ERROR"), "ERROR")
    value = result.get("nilai") or "tidak-terbaca"
    name = local_server_name()
    try:
        with closing(db()) as conn, conn:
            row = conn.execute("SELECT id, isi FROM laporan WHERE server=? "
                               "ORDER BY diterima DESC LIMIT 1", (name,)).fetchone()
            if not row:
                return
            report = json.loads(row["isi"])
            found = False
            for entry in report.get("kontrol", []):
                if entry.get("id") == kid:
                    entry["status"] = status
                    entry["nilai_terbaca"] = value
                    entry["hasil"] = {"tindakan": result.get("tindakan"),
                                      "status": result.get("status"),
                                      "pesan": result.get("pesan"),
                                      "waktu": time.strftime("%Y-%m-%dT%H:%M:%S")}
                    found = True
            if not found:
                return

            tally = {"LULUS": 0, "GAGAL": 0, "SEBAGIAN": 0, "DILEWATI": 0, "ERROR": 0}
            for entry in report["kontrol"]:
                tally[entry["status"]] = tally.get(entry["status"], 0) + 1
            total = len(report["kontrol"])
            report["ringkasan"] = {
                "total": total, "lulus": tally["LULUS"], "gagal": tally["GAGAL"],
                "sebagian": tally["SEBAGIAN"], "dilewati": tally["DILEWATI"] + tally["ERROR"],
                "skor": round(tally["LULUS"] / total * 100) if total else 0,
            }
            report["butuh_keputusan"] = [
                e["id"] for e in report["kontrol"]
                if e["status"] == "GAGAL" and e.get("butuh_izin") and not e.get("prasyarat_gagal")]
            conn.execute("UPDATE laporan SET skor=?, isi=? WHERE id=?",
                         (report["ringkasan"]["skor"],
                          json.dumps(report, ensure_ascii=False), row["id"]))
    except (OSError, sqlite3.Error, ValueError, KeyError):
        # Failing to refresh the report is no reason to fail an action that has
        # already succeeded on the server.
        return


# ------------------------------------------------------------------- settings
@app.get("/api/konfigurasi")
async def read_settings(req: Request, authorization: Optional[str] = Header(None)):
    require_write_access(req, authorization)
    config = read_config()
    out: Dict[str, Any] = {}
    for key in SETTABLE_KEYS:
        val = config.get(key, "")
        # A token is never sent to the browser in full. All the owner needs to
        # know is whether one is set.
        out[key] = {"terisi": bool(val), "nilai": "" if key in SECRET_KEYS else val}
    out["_berkas"] = str(CONFIG_FILE)
    return out


@app.post("/api/konfigurasi")
async def write_setting(req: Request, badan: Dict[str, Any] = Body(...),
                        authorization: Optional[str] = Header(None)):
    """Writes through yoructl instead of writing the file itself.

    The dashboard runs as yoru-agent and is deliberately not allowed to write
    /etc/yoru/yoru.conf. The only way in is yoructl - the same program the
    agent uses, with the key list and value checks inside it.
    """
    require_write_access(req, authorization)
    key = str(badan.get("kunci") or "").strip()
    val = str(badan.get("nilai") or "").strip()
    if key not in SETTABLE_KEYS:
        raise HTTPException(status_code=422, detail=f"kunci '{key}' tidak bisa disetel dari sini")

    cmd = ["sudo", "-n", YORUCTL, "konfigurasi", key, val]
    if os.geteuid() == 0:
        cmd = [YORUCTL, "konfigurasi", key, val]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=30)
    except (OSError, asyncio.TimeoutError) as e:
        return {"status": "ERROR", "berhasil": False,
                "pesan": f"tidak bisa menjalankan yoructl: {e or 'kehabisan waktu'}"}

    for line in reversed([b for b in out.decode("utf-8", "replace").splitlines() if b.strip()]):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return {"status": "ERROR", "berhasil": False,
            "pesan": (err.decode("utf-8", "replace").strip() or "yoructl tidak menjawab")[:300]}


@app.get("/api/log")
async def read_log(kontrol: Optional[str] = None, batas: int = 60):
    """The action trail from /var/log/yoru. Root-owned; the agent cannot write it."""
    batas = max(1, min(batas, 500))
    name = "tindakan.log"
    if kontrol and CONTROL_RE.match(kontrol.upper()):
        name = f"{kontrol.upper()}.log"
    try:
        lines = (LOG_DIR / name).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {"baris": [], "pesan": f"{LOG_DIR / name} belum ada atau tidak bisa dibaca"}
    out = []
    for line in lines[-batas:]:
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return {"baris": list(reversed(out))}


@app.get("/", response_class=HTMLResponse)
async def page():
    try:
        return HTMLResponse(PAGE.read_text(encoding="utf-8"))
    except OSError:
        return HTMLResponse("<h1>dashboard.html tidak ditemukan</h1>", status_code=404)


@app.get("/sehat")
async def health():
    return {"ok": True, "versi": app.version, "db": str(DB_FILE), "token_aktif": bool(TOKEN)}
