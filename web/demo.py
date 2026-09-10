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
import sqlite3
import sys
import time
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
DB_FILE = HERE / "yoru.db"

SAMPLES = [
    ("report-fix.json", "siklus perbaikan (server sakit, skor 10)"),
    ("report-watch.json", "siklus penjagaan (server sehat, ada satu perubahan)"),
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
        conn.commit()
    finally:
        conn.close()


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
