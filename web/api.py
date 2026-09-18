#!/usr/bin/env python3
"""Dashboard API and storage.
Run: uvicorn api:app --host 127.0.0.1 --port 8000  (needs fastapi, uvicorn)

Data flows one way: the agent POSTs reports and GETs decisions; the dashboard
never contacts a guarded server, so that server opens no port for it.

Endpoints, JSON fields and SQLite columns are English; the four action verbs
and the catalog keys stay Indonesian. migrate_db carries older databases over.
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

# Shared with the agent via DASHBOARD_TOKEN in /etc/yoru/yoru.conf. Empty = no check (local use).
TOKEN = os.environ.get("YORU_TOKEN", "").strip()

YORUCTL = os.environ.get("YORUCTL", "/opt/yoru/bin/yoructl")

# K07/K08 run apt; on a slow link the download plus dpkg-lock wait exceeds the old 200s.
TIME_LIMIT = int(os.environ.get("YORU_BATAS_WAKTU", "600"))

LOG_DIR = Path(os.environ.get("YORU_LOG", "/var/log/yoru"))
CONFIG_FILE = Path(os.environ.get("YORU_KONF", "/etc/yoru/yoru.conf"))

CONTROL_RE = re.compile(r"^K(?:0[1-9]|10)$")
VALID_DECISIONS = {"setuju", "tolak", "sah", "kembalikan"}
ACTIONS = {"periksa": "periksa", "audit": "periksa",
           "terapkan": "terapkan", "hardening": "terapkan",
           "kembalikan": "kembalikan", "rollback": "kembalikan",
           "verifikasi": "verifikasi"}

# Mirrors yoructl's list (yoructl enforces it as root); this copy only avoids
# offering a key that would be refused.
SETTABLE_KEYS = ("TELEGRAM_TOKEN", "TELEGRAM_CHAT_ID", "HERMES_URL", "HERMES_TOKEN",
                 "AI_MODEL",
                 "NAMA_SERVER", "PORT_DIIZINKAN", "LEWATI_KONTROL",
                 "JAM_PENJAGAAN", "ZONA_WAKTU")
SECRET_KEYS = ("TELEGRAM_TOKEN", "HERMES_TOKEN")

# Same table as STATUS_MAP in bin/yoru-agent, so buttons and cycles agree.
STATUS_MAP = {"LULUS": "LULUS", "GAGAL": "GAGAL", "DILEWATI": "DILEWATI",
              "DIKEMBALIKAN": "DILEWATI", "DITOLAK": "ERROR",
              "ERROR": "ERROR", "PERINGATAN": "ERROR", "MENUNGGU": "ERROR"}

app = FastAPI(title="Yoru Dashboard", version="0.2.0")


def running_as_root() -> bool:
    """os.geteuid is POSIX-only, and demo.py also runs on Windows."""
    return getattr(os, "geteuid", lambda: -1)() == 0


# -------------------------------------------------------------------- storage
def db():
    conn = sqlite3.connect(DB_FILE, timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def migrate_db(conn):
    """Rename pre-rename tables/columns. Runs before CREATE TABLE, or the new
    empty tables would shadow the old data."""
    have = {r[0] for r in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table'").fetchall()}
    if "report" in have or "laporan" not in have:
        return
    for old, new in (("laporan", "report"), ("keputusan", "decision")):
        if old in have:
            conn.execute(f"ALTER TABLE {old} RENAME TO {new}")
    columns = {
        "report": [("waktu", "time"), ("siklus", "cycle"), ("skor", "score"),
                   ("isi", "body"), ("diterima", "received")],
        "decision": [("kontrol", "control"), ("nilai", "value"),
                     ("catatan", "note"), ("dibuat", "created"), ("diambil", "taken")],
        "port": [("keterangan", "note"), ("dibuat", "created"), ("diambil", "taken")],
    }
    for table, pairs in columns.items():
        present = {r[1] for r in conn.execute(f"PRAGMA table_info({table})").fetchall()}
        for old, new in pairs:
            if old in present:
                conn.execute(f"ALTER TABLE {table} RENAME COLUMN {old} TO {new}")
    conn.execute("DROP INDEX IF EXISTS i_laporan")


def init_db():
    with closing(db()) as conn, conn:
        migrate_db(conn)
        conn.execute("""CREATE TABLE IF NOT EXISTS report (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server TEXT NOT NULL,
            time TEXT NOT NULL,
            cycle TEXT NOT NULL,
            score INTEGER NOT NULL,
            body TEXT NOT NULL,
            received REAL NOT NULL)""")
        conn.execute("""CREATE TABLE IF NOT EXISTS decision (
            server TEXT NOT NULL,
            control TEXT NOT NULL,
            value TEXT NOT NULL,
            note TEXT,
            created REAL NOT NULL,
            taken INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, control))""")
        conn.execute("""CREATE TABLE IF NOT EXISTS port (
            server TEXT NOT NULL,
            port INTEGER NOT NULL,
            note TEXT,
            created REAL NOT NULL,
            taken INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, port))""")
        conn.execute("CREATE INDEX IF NOT EXISTS i_report ON report(server, received DESC)")


init_db()


# ------------------------------------------------------------------- identity
def check_token(given: Optional[str]):
    if not TOKEN:
        return
    expected = f"Bearer {TOKEN}"
    # Constant-time compare so timing cannot leak how much of the token matched.
    import hmac
    if not given or not hmac.compare_digest(given, expected):
        raise HTTPException(status_code=401, detail="token tidak sah")


def from_this_machine(req: Request) -> bool:
    return bool(req.client) and req.client.host in ("127.0.0.1", "::1")


def require_access(req: Request, given: Optional[str]):
    """The rule guarding every endpoint that carries data or causes change.

    From 127.0.0.1: open. From the network a token is required, and an empty
    token means refused, not exempt. Reads are guarded like writes: a report
    lists which controls FAIL and every open port, and the action log is
    root-owned.

    "/" and "/health" stay open: the page holds no data and must load before a
    token can be typed, and the health check must answer during setup.
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
    """Parsed as text, never sourced: a value with $(...) would otherwise run
    in a process that holds the tokens."""
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
    """This machine's name, worked out as the agent does; buttons touch only this machine."""
    return (read_config().get("NAMA_SERVER") or "").strip() or socket.gethostname()


# ------------------------------------------------------------------ endpoints
@app.post("/api/report")
async def receive_report(req: Request, report: Dict[str, Any] = Body(...),
                         authorization: Optional[str] = Header(None)):
    require_access(req, authorization)

    for field in ("contract_version", "server", "time", "cycle", "summary", "controls"):
        if field not in report:
            raise HTTPException(status_code=422, detail=f"field '{field}' tidak ada")

    name = str((report.get("server") or {}).get("name") or "tanpa-nama")[:100]
    with closing(db()) as conn, conn:
        conn.execute(
            "INSERT INTO report (server, time, cycle, score, body, received) VALUES (?,?,?,?,?,?)",
            (name, str(report["time"]), str(report["cycle"]),
             int((report.get("summary") or {}).get("score") or 0),
             json.dumps(report, ensure_ascii=False), time.time()),
        )
        # Drop already-collected decisions so they are not carried out twice.
        conn.execute("DELETE FROM decision WHERE server=? AND taken=1", (name,))
        conn.execute("DELETE FROM port WHERE server=? AND taken=1", (name,))
    return {"ok": True, "server": name}


@app.get("/api/report")
async def latest_report(req: Request, server: Optional[str] = None,
                        authorization: Optional[str] = Header(None)):
    require_access(req, authorization)
    with closing(db()) as conn:
        if server:
            row = conn.execute("SELECT body FROM report WHERE server=? ORDER BY received DESC LIMIT 1",
                               (server,)).fetchone()
        else:
            row = conn.execute("SELECT body FROM report ORDER BY received DESC LIMIT 1").fetchone()
    if not row:
        return JSONResponse({"kosong": True,
                             "message": "belum ada laporan masuk - jalankan agent dulu"},
                            status_code=404)
    return json.loads(row["body"])


@app.get("/api/servers")
async def server_list(req: Request, authorization: Optional[str] = Header(None)):
    """Reporting servers, with a "local" flag: the Audit/Hardening/Rollback
    buttons run yoructl on THIS machine, so they apply only to the local row."""
    require_access(req, authorization)
    local = local_server_name()
    with closing(db()) as conn:
        rows = conn.execute(
            "SELECT server, MAX(received) d, COUNT(*) n FROM report GROUP BY server ORDER BY d DESC"
        ).fetchall()
    return {"servers": [{"name": r["server"], "reports": r["n"], "last": r["d"],
                        "local": r["server"] == local} for r in rows],
            "local": local}


@app.get("/api/history")
async def history(req: Request, server: Optional[str] = None, limit: int = 30,
                  authorization: Optional[str] = Header(None)):
    require_access(req, authorization)
    limit = max(1, min(limit, 200))
    with closing(db()) as conn:
        if server:
            rows = conn.execute(
                "SELECT time, cycle, score FROM report WHERE server=? ORDER BY received DESC LIMIT ?",
                (server, limit)).fetchall()
        else:
            rows = conn.execute(
                "SELECT time, cycle, score FROM report ORDER BY received DESC LIMIT ?",
                (limit,)).fetchall()
    return {"history": [dict(r) for r in rows]}


@app.post("/api/decision")
async def store_decision(req: Request, payload: Dict[str, Any] = Body(...),
                         authorization: Optional[str] = Header(None)):
    """Stores the owner's answer; the agent carries it out via yoructl, not the dashboard."""
    require_access(req, authorization)
    server = str(payload.get("server") or "").strip()[:100]
    control = str(payload.get("control") or "").strip().upper()
    value = str(payload.get("value") or "").strip().lower()

    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")
    if not CONTROL_RE.match(control):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if value not in VALID_DECISIONS:
        raise HTTPException(status_code=422,
                            detail=f"nilai harus salah satu dari {sorted(VALID_DECISIONS)}")

    with closing(db()) as conn, conn:
        conn.execute("""INSERT INTO decision (server, control, value, note, created, taken)
                        VALUES (?,?,?,?,?,0)
                        ON CONFLICT(server, control) DO UPDATE SET
                          value=excluded.value, note=excluded.note,
                          created=excluded.created, taken=0""",
                     (server, control, value, str(payload.get("note") or "")[:500], time.time()))
    return {"ok": True, "server": server, "control": control, "value": value}


@app.post("/api/port")
async def store_ports(req: Request, payload: Dict[str, Any] = Body(...),
                      authorization: Optional[str] = Header(None)):
    """Marks ports as owner-approved."""
    require_access(req, authorization)
    server = str(payload.get("server") or "").strip()[:100]
    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")

    accepted = []
    with closing(db()) as conn, conn:
        for p in (payload.get("port") or []):
            try:
                n = int(p)
            except (TypeError, ValueError):
                continue
            if not 1 <= n <= 65535:
                continue
            conn.execute("""INSERT INTO port (server, port, note, created, taken)
                            VALUES (?,?,?,?,0)
                            ON CONFLICT(server, port) DO UPDATE SET taken=0""",
                         (server, n, str(payload.get("note") or "")[:200], time.time()))
            accepted.append(n)
    return {"ok": True, "port": accepted}


@app.get("/api/decision")
async def decisions_for_agent(req: Request, server: Optional[str] = None,
                              authorization: Optional[str] = Header(None)):
    """Collected by the agent each cycle; marks them taken but does not delete.
    Deletion waits for the next report, so a decision survives an agent that
    dies mid-run before carrying it out."""
    require_access(req, authorization)

    # ?server= is mandatory: without it this would return and mark-taken EVERY
    # server's decisions, so one agent would swallow the others' answers.
    server = (server or "").strip()
    if not server:
        raise HTTPException(status_code=422, detail="sebutkan ?server=<nama>")

    with closing(db()) as conn, conn:
        decisions = conn.execute("SELECT control, value FROM decision WHERE server=?",
                                 (server,)).fetchall()
        ports = conn.execute("SELECT port FROM port WHERE server=?", (server,)).fetchall()
        conn.execute("UPDATE decision SET taken=1 WHERE server=?", (server,))
        conn.execute("UPDATE port SET taken=1 WHERE server=?", (server,))
    return {"decisions": {r["control"]: r["value"] for r in decisions},
            "approved_ports": [r["port"] for r in ports]}


# -------------------------------------------------------- running via yoructl
async def run_yoructl(kid: str, action: str) -> Dict[str, Any]:
    """One call to yoructl. One program, fixed arguments - no shell."""
    cmd = ["sudo", "-n", YORUCTL, kid, action]
    if running_as_root():
        cmd = [YORUCTL, kid, action]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as e:
        return {"id": kid, "action": action, "status": "ERROR", "ok": False,
                "value": None, "message": f"tidak bisa menjalankan {YORUCTL}: {e}"}

    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=TIME_LIMIT)
    except asyncio.TimeoutError:
        # Process deliberately NOT killed: it may be apt (K07/K08), and killing it
        # mid-install leaves dpkg half-done. Message is set explicitly because
        # str(asyncio.TimeoutError()) is empty.
        return {"id": kid, "action": action, "status": "MENUNGGU", "ok": False,
                "value": None,
                "message": f"sudah {TIME_LIMIT} detik dan belum selesai - biasanya apt "
                         f"masih mengunduh. Tindakannya TETAP JALAN di server, tidak "
                         f"dibatalkan. Tunggu sebentar lalu tekan Audit untuk melihat "
                         f"hasilnya, atau lihat Audit Logs."}

    for line in reversed([b for b in out.decode("utf-8", "replace").splitlines() if b.strip()]):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return {"id": kid, "action": action, "status": "ERROR", "ok": False,
            "value": None,
            "message": (err.decode("utf-8", "replace").strip() or "yoructl tidak menjawab")[:300]}


@app.post("/api/run")
async def run_action(req: Request, payload: Dict[str, Any] = Body(...),
                     authorization: Optional[str] = Header(None)):
    require_access(req, authorization)
    kid = str(payload.get("control") or "").strip().upper()
    action = ACTIONS.get(str(payload.get("action") or "").strip().lower())
    if not CONTROL_RE.match(kid):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if not action:
        raise HTTPException(status_code=422, detail="tindakan tidak dikenal")

    result = await run_yoructl(kid, action)
    if result.get("ok") is True:
        if action in ("terapkan", "kembalikan"):
            # Read the status back rather than infer it from "apply succeeded", or a
            # just-rolled-back row would record as DILEWATI instead of GAGAL.
            check = await run_yoructl(kid, "periksa")
            refresh_stored_report(kid, check if check.get("ok") is True else result)
        else:
            refresh_stored_report(kid, result)
    return result


def refresh_stored_report(kid: str, result: Dict[str, Any]):
    """Update the stored report to match what was just measured, so the dashboard
    cards move now instead of only after the next agent cycle."""
    status = STATUS_MAP.get(str(result.get("status") or "ERROR"), "ERROR")
    value = result.get("value") or "tidak-terbaca"
    name = local_server_name()
    try:
        with closing(db()) as conn, conn:
            row = conn.execute("SELECT id, body FROM report WHERE server=? "
                               "ORDER BY received DESC LIMIT 1", (name,)).fetchone()
            if not row:
                return
            report = json.loads(row["body"])
            found = False
            for entry in report.get("controls", []):
                if entry.get("id") == kid:
                    entry["status"] = status
                    entry["observed"] = value
                    entry["result"] = {"action": result.get("action"),
                                      "status": result.get("status"),
                                      "message": result.get("message"),
                                      "time": time.strftime("%Y-%m-%dT%H:%M:%S")}
                    found = True
            if not found:
                return

            tally = {"LULUS": 0, "GAGAL": 0, "SEBAGIAN": 0, "DILEWATI": 0, "ERROR": 0}
            for entry in report["controls"]:
                tally[entry["status"]] = tally.get(entry["status"], 0) + 1
            total = len(report["controls"])
            report["summary"] = {
                "total": total, "passed": tally["LULUS"], "failed": tally["GAGAL"],
                "partial": tally["SEBAGIAN"], "skipped": tally["DILEWATI"] + tally["ERROR"],
                "score": round(tally["LULUS"] / total * 100) if total else 0,
            }
            report["pending_decisions"] = [
                e["id"] for e in report["controls"]
                if e["status"] == "GAGAL" and e.get("needs_approval") and not e.get("blockers")]
            conn.execute("UPDATE report SET score=?, body=? WHERE id=?",
                         (report["summary"]["score"],
                          json.dumps(report, ensure_ascii=False), row["id"]))
    except (OSError, sqlite3.Error, ValueError, KeyError):
        # A failed refresh must not fail an action that already succeeded.
        return


# ------------------------------------------------------------------- settings
@app.get("/api/config")
async def read_settings(req: Request, authorization: Optional[str] = Header(None)):
    require_access(req, authorization)
    config = read_config()
    out: Dict[str, Any] = {}
    for key in SETTABLE_KEYS:
        val = config.get(key, "")
        # Secrets are never sent to the browser; only whether one is set.
        out[key] = {"set": bool(val), "value": "" if key in SECRET_KEYS else val}
    out["_berkas"] = str(CONFIG_FILE)
    return out


@app.post("/api/config")
async def write_setting(req: Request, payload: Dict[str, Any] = Body(...),
                        authorization: Optional[str] = Header(None)):
    """Writes through yoructl, never the file directly: the dashboard runs as
    yoru-agent, which is not allowed to write /etc/yoru/yoru.conf."""
    require_access(req, authorization)
    key = str(payload.get("key") or "").strip()
    val = str(payload.get("value") or "").strip()
    if key not in SETTABLE_KEYS:
        raise HTTPException(status_code=422, detail=f"kunci '{key}' tidak bisa disetel dari sini")

    cmd = ["sudo", "-n", YORUCTL, "konfigurasi", key, val]
    if running_as_root():
        cmd = [YORUCTL, "konfigurasi", key, val]
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=30)
    except (OSError, asyncio.TimeoutError) as e:
        return {"status": "ERROR", "ok": False,
                "message": f"tidak bisa menjalankan yoructl: {e or 'kehabisan waktu'}"}

    for line in reversed([b for b in out.decode("utf-8", "replace").splitlines() if b.strip()]):
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            continue
    return {"status": "ERROR", "ok": False,
            "message": (err.decode("utf-8", "replace").strip() or "yoructl tidak menjawab")[:300]}


@app.get("/api/log")
async def read_log(req: Request, control: Optional[str] = None, limit: int = 60,
                   authorization: Optional[str] = Header(None)):
    """The action trail from /var/log/yoru. Root-owned; the agent cannot write it."""
    require_access(req, authorization)
    limit = max(1, min(limit, 500))
    name = "tindakan.log"
    if control and CONTROL_RE.match(control.upper()):
        name = f"{control.upper()}.log"
    try:
        lines = (LOG_DIR / name).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {"lines": [], "message": f"{LOG_DIR / name} belum ada atau tidak bisa dibaca"}
    out = []
    for line in lines[-limit:]:
        line = line.strip()
        if line:
            try:
                out.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return {"lines": list(reversed(out))}


@app.get("/", response_class=HTMLResponse)
async def page():
    try:
        return HTMLResponse(PAGE.read_text(encoding="utf-8"))
    except OSError:
        return HTMLResponse("<h1>dashboard.html tidak ditemukan</h1>", status_code=404)


@app.get("/health")
async def health(req: Request):
    """Open on purpose (the installer polls it before any token exists); the db
    path is returned only to local callers, the network gets just "alive"."""
    out = {"ok": True, "version": app.version, "token_active": bool(TOKEN)}
    if from_this_machine(req):
        out["db"] = str(DB_FILE)
    return out
