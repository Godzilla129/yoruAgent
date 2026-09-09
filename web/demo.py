#!/usr/bin/env python3
"""
demo.py - nyalakan dashboard Yoru dengan data contoh.

Jalan di Windows, Linux, dan macOS - cuma butuh Python. Tidak ada bash, tidak
ada curl, tidak ada perintah yang beda antar sistem.

    cd web
    python -m pip install fastapi uvicorn
    python demo.py

Lalu buka http://127.0.0.1:8000

Datanya dari examples/ di repo ini. Tidak ada server yang disentuh - ini murni
buat melihat tampilan dan latihan presentasi.

    python demo.py 9000        ganti port
    python demo.py --bersih    hapus database demo, mulai dari nol
    python demo.py --luar      biar bisa dibuka dari komputer lain
"""

import json
import os
import sqlite3
import sys
import time
import webbrowser
from pathlib import Path

DIR = Path(__file__).resolve().parent
REPO = DIR.parent
DB = DIR / "yoru.db"

CONTOH = [
    ("report-fix.json", "siklus perbaikan (server sakit, skor 10)"),
    ("report-watch.json", "siklus penjagaan (server sehat, ada satu perubahan)"),
]


def mati(pesan):
    print(f"\n  GAGAL: {pesan}\n")
    sys.exit(1)


def isi_contoh():
    """Ditulis langsung ke SQLite, bukan lewat HTTP.

    Lewat HTTP berarti harus menunggu server siap dulu lalu memanggil curl -
    dan curl di PowerShell itu alias ke perintah lain yang bentuk argumennya
    beda. Menulis langsung menghapus seluruh kelas masalah itu.
    """
    import api  # noqa: F401  - impor ini yang membuat tabelnya

    k = sqlite3.connect(DB)
    try:
        sudah = k.execute("SELECT COUNT(*) FROM laporan").fetchone()[0]
        if sudah:
            print(f"  --   database sudah berisi {sudah} laporan, tidak diisi ulang")
            return
        for berkas, keterangan in CONTOH:
            jalur = REPO / "examples" / berkas
            if not jalur.exists():
                print(f"  --   {berkas} tidak ada, dilewati")
                continue
            d = json.loads(jalur.read_text(encoding="utf-8"))
            k.execute(
                "INSERT INTO laporan (server, waktu, siklus, skor, isi, diterima) VALUES (?,?,?,?,?,?)",
                (str((d.get("server") or {}).get("nama") or "contoh"),
                 str(d.get("waktu")), str(d.get("siklus")),
                 int((d.get("ringkasan") or {}).get("skor") or 0),
                 json.dumps(d, ensure_ascii=False), time.time()),
            )
            print(f"  ok   {keterangan}")
        k.commit()
    finally:
        k.close()


def main():
    port, bersih, luar = 8000, False, False
    for a in sys.argv[1:]:
        if a == "--bersih":
            bersih = True
        elif a == "--luar":
            luar = True
        elif a in ("-h", "--help"):
            print(__doc__)
            return 0
        elif a.isdigit():
            port = int(a)
        else:
            mati(f"argumen tidak dikenal: {a}")

    print("\n  Yoru - demo dashboard\n")

    try:
        import fastapi  # noqa: F401
        import uvicorn
    except ImportError:
        mati("fastapi/uvicorn belum ada. Jalankan dulu:\n"
             "         python -m pip install fastapi uvicorn")

    if bersih:
        for s in ("", "-wal", "-shm"):
            Path(str(DB) + s).unlink(missing_ok=True)
        print("  ok   database demo dihapus")

    os.chdir(DIR)   # supaya api.py menemukan dashboard.html di sebelahnya
    isi_contoh()

    host = "0.0.0.0" if luar else "127.0.0.1"
    alamat = f"http://127.0.0.1:{port}"
    print(f"\n  Buka: {alamat}")
    if luar:
        print("  (--luar aktif: bisa dibuka dari komputer lain di jaringan yang sama)")
    print("\n  Tekan Ctrl-C untuk berhenti.\n")

    try:
        webbrowser.open(alamat)
    except Exception:  # noqa: BLE001 - browser tidak wajib, ini cuma kemudahan
        pass

    uvicorn.run("api:app", host=host, port=port, log_level="warning")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\n  berhenti.\n")
        sys.exit(0)
