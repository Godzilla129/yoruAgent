#!/usr/bin/env python3
"""
demo.py - start the dashboard with sample data.

Runs on Windows, Linux and macOS - all it needs is Python. No bash, no curl,
no command that behaves differently per system.

    cd web
    python -m pip install fastapi uvicorn
    python demo.py

Then open http://127.0.0.1:8000

The data comes from examples/ in this repo. No server is touched - this is
purely for looking at the interface and rehearsing a presentation.

    python demo.py 9000        change the port
    python demo.py --bersih    wipe the demo database and start over
    python demo.py --luar      allow other machines on the network to open it
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

# The dashboard asks the config file which server it is standing on, so that it
# can tell its own reports (where the buttons mean something) from another
# server's (where they must not fire). With no config file it falls back to this
# machine's hostname, which never matches the samples - so in the demo every
# button came out disabled and there was nothing to rehearse with.
#
# YORU_KONF is an env hook api.py already honours, so this needs no special
# case anywhere in the real code.
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
    """Written straight into SQLite instead of over HTTP.

    Going through HTTP would mean waiting for the server to be ready and then
    calling curl - and curl in PowerShell is an alias for something else whose
    arguments have a different shape. Writing directly removes that whole class
    of problem.
    """
    import api  # noqa: F401  - importing this is what creates the tables

    conn = sqlite3.connect(DB_FILE)
    try:
        existing = conn.execute("SELECT COUNT(*) FROM laporan").fetchone()[0]
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
                "INSERT INTO laporan (server, waktu, siklus, skor, isi, diterima) VALUES (?,?,?,?,?,?)",
                (str((report.get("server") or {}).get("nama") or "contoh"),
                 str(report.get("waktu")), str(report.get("siklus")),
                 int((report.get("ringkasan") or {}).get("skor") or 0),
                 json.dumps(report, ensure_ascii=False), time.time()),
            )
            print(f"  ok   {label}")
        seed_history(conn)
        conn.commit()
    finally:
        conn.close()


def seed_history(conn):
    """Older reports, so the score chart has a line instead of one bar.

    A server that has been running Yoru for a fortnight is the normal case, and
    the shape of that fortnight is the point: the score climbs as controls get
    approved, then dips the day something drifts. With a single report the chart
    is technically correct and tells nobody anything.

    Marked "contoh" in the stored JSON so nothing mistakes these for a real run.
    """
    base = json.loads((REPO / "examples" / "report-watch.json").read_text(encoding="utf-8"))
    # Two weeks of a server slowly being put right, with one bad day near the end.
    curve = [30, 30, 40, 50, 50, 60, 70, 70, 80, 80, 90, 90, 60, 90]
    now = time.time()
    for days_ago, skor in enumerate(reversed(curve), start=1):
        stamp = now - days_ago * 86400
        report = dict(base)
        report["waktu"] = time.strftime("%Y-%m-%dT%H:%M:%S+07:00", time.localtime(stamp))
        report["siklus"] = "penjagaan"
        report["contoh"] = True
        report["ringkasan"] = dict(base["ringkasan"],
                                   skor=skor, lulus=round(skor / 10), gagal=10 - round(skor / 10))
        conn.execute(
            "INSERT INTO laporan (server, waktu, siklus, skor, isi, diterima) VALUES (?,?,?,?,?,?)",
            (base["server"]["nama"], report["waktu"], "penjagaan", skor,
             json.dumps(report, ensure_ascii=False), stamp))
    print("  ok   riwayat contoh %d hari untuk %s" % (len(curve), base["server"]["nama"]))


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

    # Opened to the network, the dashboard needs a token - reading a report is
    # guarded there exactly like pressing a button, because a report names every
    # control that fails on the machine it came from. One is made up here and
    # printed, so the demo still works from another laptop without anyone having
    # to find out why every panel came back empty.
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
