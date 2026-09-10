#!/usr/bin/env python3
"""
API + penyimpanan dashboard Yoru.

Jalankan:
    pip install fastapi uvicorn
    uvicorn api:app --host 0.0.0.0 --port 8000

Dua arah data, dan arahnya sengaja SATU JALUR:

    agent  --POST /api/laporan-->  dashboard      (agent mengirim keadaan)
    agent  --GET  /api/keputusan-> dashboard      (agent mengambil jawaban)

Dashboard TIDAK PERNAH menghubungi server yang dijaga. Akibatnya server itu
tidak perlu membuka satu port pun untuk dashboard, dan kalau dashboardnya
jebol, yang paling jauh bisa dilakukan penyerang cuma menyetujui kontrol yang
SUDAH ADA di katalog - dia tidak bisa menyuruh server melakukan hal baru.

Jangan pernah membalik arahnya demi kepraktisan.
"""

import asyncio
import json
import os
import re
import sqlite3
import time
from contextlib import closing
from pathlib import Path
from typing import Any, Dict, List, Optional

from fastapi import Body, FastAPI, Header, HTTPException, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

DIR = Path(__file__).resolve().parent
DB = Path(os.environ.get("YORU_DB", DIR / "yoru.db"))
HALAMAN = DIR / "dashboard.html"

# Token dibagi ke agent lewat DASHBOARD_TOKEN di /etc/yoru/yoru.conf.
# Kosong = tanpa pemeriksaan; itu hanya untuk mencoba di laptop sendiri.
TOKEN = os.environ.get("YORU_TOKEN", "").strip()

KONTROL_SAH = re.compile(r"^K(?:0[1-9]|10)$")
KEPUTUSAN_SAH = {"setuju", "tolak", "sah", "kembalikan"}

app = FastAPI(title="Yoru Dashboard", version="0.1.8")


# ------------------------------------------------------------------ simpanan
def db():
    k = sqlite3.connect(DB, timeout=10)
    k.row_factory = sqlite3.Row
    k.execute("PRAGMA journal_mode=WAL")
    return k


def siapkan():
    with closing(db()) as k, k:
        k.execute("""CREATE TABLE IF NOT EXISTS laporan (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            server TEXT NOT NULL,
            waktu TEXT NOT NULL,
            siklus TEXT NOT NULL,
            skor INTEGER NOT NULL,
            isi TEXT NOT NULL,
            diterima REAL NOT NULL)""")
        k.execute("""CREATE TABLE IF NOT EXISTS keputusan (
            server TEXT NOT NULL,
            kontrol TEXT NOT NULL,
            nilai TEXT NOT NULL,
            catatan TEXT,
            dibuat REAL NOT NULL,
            diambil INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, kontrol))""")
        k.execute("""CREATE TABLE IF NOT EXISTS port (
            server TEXT NOT NULL,
            port INTEGER NOT NULL,
            keterangan TEXT,
            dibuat REAL NOT NULL,
            diambil INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (server, port))""")
        k.execute("CREATE INDEX IF NOT EXISTS i_laporan ON laporan(server, diterima DESC)")


siapkan()


def periksa_token(diberikan: Optional[str]):
    if not TOKEN:
        return
    diharapkan = f"Bearer {TOKEN}"
    # Dibandingkan dengan panjang tetap supaya lama pembandingan tidak
    # membocorkan berapa karakter awal token yang sudah benar.
    import hmac
    if not diberikan or not hmac.compare_digest(diberikan, diharapkan):
        raise HTTPException(status_code=401, detail="token tidak sah")


def dari_mesin_ini(minta: Request) -> bool:
    return bool(minta.client) and minta.client.host in ("127.0.0.1", "::1")


def boleh_mengubah(minta: Request, diberikan: Optional[str]):
    """Endpoint yang berujung pada perubahan di server sungguhan.

    Dari mesin itu sendiri: bebas - yang bisa membuka 127.0.0.1 sudah punya
    akses ke servernya. Dari jaringan: wajib token, dan token kosong berarti
    ditolak, bukan dibebaskan. Tanpa aturan ini siapa pun yang bisa menjangkau
    portnya bisa menekan tombol Hardening di server orang.
    """
    if dari_mesin_ini(minta):
        return
    if not TOKEN:
        raise HTTPException(
            status_code=403,
            detail="dashboard dibuka ke jaringan tapi DASHBOARD_TOKEN kosong - "
                   "isi dulu di /etc/yoru/yoru.conf, atau buka lewat 127.0.0.1")
    periksa_token(diberikan)


# ------------------------------------------------------------------ endpoint
@app.post("/api/laporan")
async def terima_laporan(laporan: Dict[str, Any] = Body(...),
                         authorization: Optional[str] = Header(None)):
    periksa_token(authorization)

    for wajib in ("versi_kontrak", "server", "waktu", "siklus", "ringkasan", "kontrol"):
        if wajib not in laporan:
            raise HTTPException(status_code=422, detail=f"field '{wajib}' tidak ada")

    nama = str((laporan.get("server") or {}).get("nama") or "tanpa-nama")[:100]
    with closing(db()) as k, k:
        k.execute(
            "INSERT INTO laporan (server, waktu, siklus, skor, isi, diterima) VALUES (?,?,?,?,?,?)",
            (nama, str(laporan["waktu"]), str(laporan["siklus"]),
             int((laporan.get("ringkasan") or {}).get("skor") or 0),
             json.dumps(laporan, ensure_ascii=False), time.time()),
        )
        # Keputusan yang sudah dipakai agent dihapus supaya tidak dikerjakan
        # dua kali di siklus berikutnya.
        k.execute("DELETE FROM keputusan WHERE server=? AND diambil=1", (nama,))
        k.execute("DELETE FROM port WHERE server=? AND diambil=1", (nama,))
    return {"ok": True, "server": nama}


@app.get("/api/laporan")
async def laporan_terakhir(server: Optional[str] = None):
    with closing(db()) as k:
        if server:
            b = k.execute("SELECT isi FROM laporan WHERE server=? ORDER BY diterima DESC LIMIT 1",
                          (server,)).fetchone()
        else:
            b = k.execute("SELECT isi FROM laporan ORDER BY diterima DESC LIMIT 1").fetchone()
    if not b:
        return JSONResponse({"kosong": True,
                             "pesan": "belum ada laporan masuk - jalankan agent dulu"},
                            status_code=404)
    return json.loads(b["isi"])


@app.get("/api/server")
async def daftar_server():
    with closing(db()) as k:
        baris = k.execute(
            "SELECT server, MAX(diterima) d, COUNT(*) n FROM laporan GROUP BY server ORDER BY d DESC"
        ).fetchall()
    return {"server": [{"nama": b["server"], "laporan": b["n"], "terakhir": b["d"]} for b in baris]}


@app.get("/api/riwayat")
async def riwayat(server: Optional[str] = None, batas: int = 30):
    batas = max(1, min(batas, 200))
    with closing(db()) as k:
        if server:
            baris = k.execute(
                "SELECT waktu, siklus, skor FROM laporan WHERE server=? ORDER BY diterima DESC LIMIT ?",
                (server, batas)).fetchall()
        else:
            baris = k.execute(
                "SELECT waktu, siklus, skor FROM laporan ORDER BY diterima DESC LIMIT ?",
                (batas,)).fetchall()
    return {"riwayat": [dict(b) for b in baris]}


@app.post("/api/keputusan")
async def simpan_keputusan(minta: Request, badan: Dict[str, Any] = Body(...),
                           authorization: Optional[str] = Header(None)):
    """Jawaban pemilik dari dashboard.

    Disimpan dulu, tidak langsung dijalankan. Yang menjalankan tetap agent di
    server, lewat yoructl - dashboard tidak pernah menyentuh server siapa pun.
    """
    boleh_mengubah(minta, authorization)
    server = str(badan.get("server") or "").strip()[:100]
    kontrol = str(badan.get("kontrol") or "").strip().upper()
    nilai = str(badan.get("nilai") or "").strip().lower()

    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")
    if not KONTROL_SAH.match(kontrol):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if nilai not in KEPUTUSAN_SAH:
        raise HTTPException(status_code=422, detail=f"nilai harus salah satu dari {sorted(KEPUTUSAN_SAH)}")

    with closing(db()) as k, k:
        k.execute("""INSERT INTO keputusan (server, kontrol, nilai, catatan, dibuat, diambil)
                     VALUES (?,?,?,?,?,0)
                     ON CONFLICT(server, kontrol) DO UPDATE SET
                       nilai=excluded.nilai, catatan=excluded.catatan,
                       dibuat=excluded.dibuat, diambil=0""",
                  (server, kontrol, nilai, str(badan.get("catatan") or "")[:500], time.time()))
    return {"ok": True, "server": server, "kontrol": kontrol, "nilai": nilai}


@app.post("/api/port")
async def simpan_port(minta: Request, badan: Dict[str, Any] = Body(...),
                      authorization: Optional[str] = Header(None)):
    """Pemilik menjawab "iya, port itu memang punya saya"."""
    boleh_mengubah(minta, authorization)
    server = str(badan.get("server") or "").strip()[:100]
    if not server:
        raise HTTPException(status_code=422, detail="server tidak disebut")

    diterima = []
    with closing(db()) as k, k:
        for p in (badan.get("port") or []):
            try:
                n = int(p)
            except (TypeError, ValueError):
                continue
            if not 1 <= n <= 65535:
                continue
            k.execute("""INSERT INTO port (server, port, keterangan, dibuat, diambil)
                         VALUES (?,?,?,?,0)
                         ON CONFLICT(server, port) DO UPDATE SET diambil=0""",
                      (server, n, str(badan.get("keterangan") or "")[:200], time.time()))
            diterima.append(n)
    return {"ok": True, "port": diterima}


@app.get("/api/keputusan")
async def keputusan_untuk_agent(server: Optional[str] = None,
                                authorization: Optional[str] = Header(None)):
    """Diambil agent tiap siklus. Menandai yang sudah diambil, bukan menghapus.

    Kalau langsung dihapus di sini, keputusan hilang saat agent mati di tengah
    jalan sebelum sempat mengerjakannya - dan pemilik tidak pernah tahu
    jawabannya menguap. Penghapusan baru dilakukan saat laporan berikutnya
    masuk, yang artinya agent memang sudah selesai.
    """
    periksa_token(authorization)
    with closing(db()) as k, k:
        if server:
            kb = k.execute("SELECT kontrol, nilai FROM keputusan WHERE server=?", (server,)).fetchall()
            pb = k.execute("SELECT port FROM port WHERE server=?", (server,)).fetchall()
            k.execute("UPDATE keputusan SET diambil=1 WHERE server=?", (server,))
            k.execute("UPDATE port SET diambil=1 WHERE server=?", (server,))
        else:
            kb = k.execute("SELECT kontrol, nilai FROM keputusan").fetchall()
            pb = k.execute("SELECT port FROM port").fetchall()
            k.execute("UPDATE keputusan SET diambil=1")
            k.execute("UPDATE port SET diambil=1")
    return {"keputusan": {b["kontrol"]: b["nilai"] for b in kb},
            "port_disetujui": [b["port"] for b in pb]}


# ---------------------------------------------------- jalankan lewat yoructl
YORUCTL = os.environ.get("YORUCTL", "/opt/yoru/bin/yoructl")

# K07 dan K08 memasang paket lewat apt. Di server baru dengan jaringan pelan,
# unduhannya sendiri bisa lewat tiga menit, belum termasuk menunggu kunci dpkg
# sampai 60 detik. Batas 200 detik yang lama kelewat sering habis duluan.
BATAS_WAKTU = int(os.environ.get("YORU_BATAS_WAKTU", "600"))
LOG_YORU = Path(os.environ.get("YORU_LOG", "/var/log/yoru"))
AKSI = {"periksa": "periksa", "audit": "periksa",
        "terapkan": "terapkan", "hardening": "terapkan",
        "kembalikan": "kembalikan", "rollback": "kembalikan",
        "verifikasi": "verifikasi"}


@app.post("/api/jalankan")
async def jalankan(minta: Request, badan: Dict[str, Any] = Body(...),
                   authorization: Optional[str] = Header(None)):
    """Panggil yoructl. Satu program, dua argumen - tidak ada shell."""
    boleh_mengubah(minta, authorization)
    kid = str(badan.get("kontrol") or "").strip().upper()
    aksi = AKSI.get(str(badan.get("aksi") or "").strip().lower())
    if not KONTROL_SAH.match(kid):
        raise HTTPException(status_code=422, detail="kontrol tidak dikenal")
    if not aksi:
        raise HTTPException(status_code=422, detail="tindakan tidak dikenal")

    perintah = ["sudo", "-n", YORUCTL, kid, aksi]
    if os.geteuid() == 0:
        perintah = [YORUCTL, kid, aksi]
    try:
        p = await asyncio.create_subprocess_exec(
            *perintah, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    except OSError as e:
        return {"id": kid, "tindakan": aksi, "status": "ERROR", "berhasil": False,
                "nilai": None, "pesan": f"tidak bisa menjalankan {YORUCTL}: {e}"}

    try:
        keluar, galat = await asyncio.wait_for(p.communicate(), timeout=BATAS_WAKTU)
    except asyncio.TimeoutError:
        # Prosesnya SENGAJA tidak dibunuh. Kalau yang lagi jalan itu K07 atau
        # K08, isinya apt - dan membunuh apt di tengah jalan meninggalkan dpkg
        # setengah jadi, yang jauh lebih repot daripada menunggu.
        #
        # Dan pesannya jangan pernah kosong. Versi sebelumnya menulis f"{e}",
        # padahal str(asyncio.TimeoutError()) itu string kosong - jadi yang
        # muncul di layar cuma tulisan "ERROR" tanpa satu kata pun alasan.
        return {"id": kid, "tindakan": aksi, "status": "MENUNGGU", "berhasil": False,
                "nilai": None,
                "pesan": f"sudah {BATAS_WAKTU} detik dan belum selesai - biasanya apt "
                         f"masih mengunduh. Tindakannya TETAP JALAN di server, tidak "
                         f"dibatalkan. Tunggu sebentar lalu tekan Audit untuk melihat "
                         f"hasilnya, atau lihat Audit Logs."}

    for baris in reversed([b for b in keluar.decode("utf-8", "replace").splitlines() if b.strip()]):
        try:
            return json.loads(baris)
        except json.JSONDecodeError:
            continue
    return {"id": kid, "tindakan": aksi, "status": "ERROR", "berhasil": False,
            "nilai": None,
            "pesan": (galat.decode("utf-8", "replace").strip() or "yoructl tidak menjawab")[:300]}


@app.get("/api/log")
async def log(kontrol: Optional[str] = None, batas: int = 60):
    """Jejak tindakan dari /var/log/yoru. Milik root, agent tidak bisa menulis."""
    batas = max(1, min(batas, 500))
    nama = "tindakan.log"
    if kontrol and KONTROL_SAH.match(kontrol.upper()):
        nama = f"{kontrol.upper()}.log"
    try:
        baris = (LOG_YORU / nama).read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return {"baris": [], "pesan": f"{LOG_YORU / nama} belum ada atau tidak bisa dibaca"}
    keluar = []
    for b in baris[-batas:]:
        b = b.strip()
        if b:
            try:
                keluar.append(json.loads(b))
            except json.JSONDecodeError:
                continue
    return {"baris": list(reversed(keluar))}


@app.get("/", response_class=HTMLResponse)
async def halaman():
    try:
        return HTMLResponse(HALAMAN.read_text(encoding="utf-8"))
    except OSError:
        return HTMLResponse("<h1>dashboard.html tidak ditemukan</h1>", status_code=404)


@app.get("/sehat")
async def sehat():
    return {"ok": True, "versi": app.version, "db": str(DB), "token_aktif": bool(TOKEN)}
