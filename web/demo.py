#!/usr/bin/env python3
"""
demo.py - dashboard with sample data at http://127.0.0.1:8000. Windows, Linux
or macOS: only Python, no bash and no curl. Data from examples/, no server
touched.

    cd web; python -m pip install fastapi uvicorn; python demo.py
    python demo.py 9000  port   --bersih  wipe the db   --luar  open to the network
"""

import json
import os
import secrets
import sqlite3
import sys
import time
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DB_FILE = HERE / "yoru.db"

# YORU_KONF is an env hook api.py already honours. With no config file the
# dashboard falls back to this machine's hostname, and every button is disabled.
DEMO_CONF = HERE / "yoru-demo.conf"
DEMO_CONF_BODY = """# Dibuat demo.py. Bukan konfigurasi sungguhan - yang asli ada di
# /etc/yoru/yoru.conf pada server yang dijaga.
NAMA_SERVER="yoru-a"
PORT_DIIZINKAN="80 443"
LEWATI_KONTROL=""
JAM_PENJAGAAN="03:17"
ZONA_WAKTU="Asia/Jakarta"
HERMES_URL=""
AI_MODEL=""
TELEGRAM_TOKEN=""
TELEGRAM_CHAT_ID=""
"""

SAMPLES = [
    ("report-fix.json", "yoru-b - siklus perbaikan (sakit, skor 10, ada port belum dijawab)"),
    ("report-watch.json", "yoru-a - siklus penjagaan (sehat, skor 90, ada satu perubahan)"),
]


def die(message):
    print(f"\n  GAGAL: {message}\n")
    sys.exit(1)


def load_samples():
    """Straight into SQLite: in PowerShell curl is an alias with other arguments."""
    import api  # noqa: F401  - importing this is what creates the tables

    conn = sqlite3.connect(DB_FILE)
    try:
        existing = conn.execute("SELECT COUNT(*) FROM report").fetchone()[0]
        if existing:
            print(f"  --   database sudah berisi {existing} laporan, tidak diisi ulang")
            return
        for filename, label in SAMPLES:
            path = REPO / "examples" / filename
            if not path.exists():
                print(f"  --   {filename} tidak ada, dilewati")
                continue
            report = json.loads(path.read_text(encoding="utf-8"))
            conn.execute(
                "INSERT INTO report (server, time, cycle, score, body, received) VALUES (?,?,?,?,?,?)",
                (str((report.get("server") or {}).get("name") or "contoh"),
                 str(report.get("time")), str(report.get("cycle")),
                 int((report.get("summary") or {}).get("score") or 0),
                 json.dumps(report, ensure_ascii=False), time.time()),
            )
            print(f"  ok   {label}")
        seed_history(conn)
        conn.commit()
    finally:
        conn.close()


def seed_history(conn):
    """Older reports so the chart has a line, not one bar; marked contoh in the JSON."""
    base = json.loads((REPO / "examples" / "report-watch.json").read_text(encoding="utf-8"))
    curve = [30, 30, 40, 50, 50, 60, 70, 70, 80, 80, 90, 90, 60, 90]
    now = time.time()
    for days_ago, score in enumerate(reversed(curve), start=1):
        stamp = now - days_ago * 86400
        report = dict(base)
        report["time"] = time.strftime("%Y-%m-%dT%H:%M:%S+07:00", time.localtime(stamp))
        report["cycle"] = "penjagaan"
        report["contoh"] = True
        report["summary"] = dict(base["summary"], score=score,
                                 passed=round(score / 10), failed=10 - round(score / 10))
        conn.execute(
            "INSERT INTO report (server, time, cycle, score, body, received) VALUES (?,?,?,?,?,?)",
            (base["server"]["name"], report["time"], "penjagaan", score,
             json.dumps(report, ensure_ascii=False), stamp))
    print("  ok   riwayat contoh %d hari untuk %s" % (len(curve), base["server"]["name"]))


def main():
    port, wipe, external = 8000, False, False
    for arg in sys.argv[1:]:
        if arg == "--bersih":
            wipe = True
        elif arg == "--luar":
            external = True
        elif arg in ("-h", "--help"):
            print(__doc__)
            return 0
        elif arg.isdigit():
            port = int(arg)
        else:
            die(f"argumen tidak dikenal: {arg}")

    print("\n  Yoru - demo dashboard\n")

    try:
        import fastapi  # noqa: F401
        import uvicorn
    except ImportError:
        die("fastapi/uvicorn belum ada. Jalankan dulu:\n"
            "         python -m pip install fastapi uvicorn")

    if external:
        os.environ.setdefault("YORU_TOKEN", secrets.token_hex(12))

    DEMO_CONF.write_text(DEMO_CONF_BODY, encoding="utf-8")
    os.environ.setdefault("YORU_KONF", str(DEMO_CONF))

    if wipe:
        for suffix in ("", "-wal", "-shm"):
            Path(str(DB_FILE) + suffix).unlink(missing_ok=True)
        print("  ok   database demo dihapus")

    os.chdir(HERE)   # so api.py finds dashboard.html next to it
    load_samples()

    host = "0.0.0.0" if external else "127.0.0.1"
    url = f"http://127.0.0.1:{port}"
    print(f"\n  Buka: {url}")
    if external:
        print("  (--luar aktif: bisa dibuka dari komputer lain di jaringan yang sama)")
        print("\n  Dari komputer lain halaman ini minta token sekali. Tempel yang ini:\n")
        print(f"      {os.environ['YORU_TOKEN']}\n")
        print("  Dari 127.0.0.1 tidak pernah diminta.")
    print("\n  Tekan Ctrl-C untuk berhenti.\n")

    try:
        webbrowser.open(url)
    except Exception:  # noqa: BLE001 - opening a browser is a convenience, not a requirement
        pass

    uvicorn.run("api:app", host=host, port=port, log_level="warning")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n  berhenti.\n")
        sys.exit(0)
