"""
Jembatan FastAPI -> yoructl.

Ini pengganti run_taskfile_action() di api/main.py punya Rahardian. Bentuk
request dan responsnya sengaja dibikin sama persis, jadi prompt Hermes yang
sudah ditulis tidak perlu diubah - yang ganti cuma lapisan eksekusinya.

Yang didapat dengan menukar itu:
  - 10 kontrol, bukan 2
  - semua penjaga yoructl ikut (bukti kunci SSH, port yang belum dijawab,
    user yang bakal terkunci, deteksi firewall lain, kunci antar-proses)
  - jejak audit di /var/log/yoru, milik root, tidak bisa disunting agent
  - satu baris sudoers, bukan NOPASSWD: ALL
  - rekaman keadaan asal di /var/backups/yoru

Pasang:
  sudo bash install.sh --pemilik <user>
  uvicorn api_yoructl:app --host 127.0.0.1 --port 8000

Yang menjalankan uvicorn harus boleh memanggil yoructl lewat sudo tanpa
password. Untuk agent, itu sudah diatur install.sh.
"""

import asyncio
import json
import re
import secrets
import time
from typing import Any, Dict, List, Literal, Optional

from fastapi import FastAPI
from pydantic import BaseModel, Field

app = FastAPI(
    title="Yoru - API kontrol keamanan server",
    version="0.1.6",
    description="Satu pintu ke yoructl, dengan konfirmasi pemilik untuk kontrol berisiko.",
)

YORUCTL = "/opt/yoru/bin/yoructl"
LOG_DIR = "/var/log/yoru"

# Dua daftar ini HARUS sama dengan isi katalog. Kalau katalog berubah, ubah
# juga di sini - kalau tidak, kontrol berisiko bisa jalan tanpa persetujuan.
AMAN = {"K03", "K07", "K08", "K09", "K10"}
BERISIKO = {"K01", "K02", "K04", "K05", "K06"}
SEMUA = AMAN | BERISIKO

AKSI_SAH = {"periksa", "terapkan", "kembalikan", "verifikasi"}
AKSI_MENULIS = {"terapkan", "kembalikan"}

POLA_KID = re.compile(r"^K(?:0[1-9]|10)$")


class Permintaan(BaseModel):
    aksi: Literal["periksa", "terapkan", "kembalikan", "verifikasi"]
    jawaban: Optional[str] = Field(
        default=None, description="Jawaban pemilik atas konfirmasi: 'ya' atau 'tidak'."
    )
    tiket: Optional[str] = Field(
        default=None, description="Tiket konfirmasi dari respons sebelumnya."
    )


class Jawaban(BaseModel):
    status: Literal["selesai", "menunggu_konfirmasi", "dibatalkan", "ditolak", "error"]
    id: str
    aksi: str
    butuh_konfirmasi: bool
    tiket: Optional[str] = None
    pesan_konfirmasi: Optional[str] = None
    hasil: Optional[Dict[str, Any]] = None
    kode_keluar: Optional[int] = None


# ---------------------------------------------------------------- konfirmasi
#
# Tiketnya disimpan DI SERVER, bukan dikirim balik oleh klien.
#
# Kalau "aksi yang menunggu" cuma dikirim klien di badan request, konfirmasinya
# bisa dilewati dalam satu permintaan: cukup kirim jawaban "ya" berbarengan
# dengan aksinya, dan server tidak punya cara tahu bahwa pertanyaannya tidak
# pernah benar-benar ditanyakan. Padahal klien di sini adalah model AI - persis
# komponen yang tidak kita percaya sepenuhnya.
#
# Dengan tiket yang lahir di server: tanpa langkah bertanya, tidak ada tiket;
# tanpa tiket, tidak ada eksekusi.
_TIKET: Dict[str, Dict[str, Any]] = {}
UMUR_TIKET = 300  # detik


def _buat_tiket(kid: str, aksi: str) -> str:
    _bersihkan_tiket()
    t = secrets.token_urlsafe(16)
    _TIKET[t] = {"id": kid, "aksi": aksi, "kedaluwarsa": time.time() + UMUR_TIKET}
    return t


def _pakai_tiket(t: str, kid: str, aksi: str) -> bool:
    _bersihkan_tiket()
    data = _TIKET.pop(t, None)  # sekali pakai
    return bool(data and data["id"] == kid and data["aksi"] == aksi)


def _bersihkan_tiket() -> None:
    sekarang = time.time()
    for t in [k for k, v in _TIKET.items() if v["kedaluwarsa"] < sekarang]:
        _TIKET.pop(t, None)


# ----------------------------------------------------------------- eksekusi
async def panggil_yoructl(kid: str, aksi: str) -> tuple[int, Dict[str, Any]]:
    """Satu program, dua argumen. Tidak ada string yang dirakit dari input."""
    if not POLA_KID.match(kid) or aksi not in AKSI_SAH:
        return 2, {"status": "ERROR", "pesan": "kontrol atau tindakan tidak dikenal"}

    proses = await asyncio.create_subprocess_exec(
        "sudo", "-n", YORUCTL, kid, aksi,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    keluar, galat = await proses.communicate()

    # yoructl selalu mencetak satu baris JSON di baris terakhir stdout.
    baris = [b for b in keluar.decode("utf-8", "replace").splitlines() if b.strip()]
    if baris:
        try:
            return proses.returncode, json.loads(baris[-1])
        except json.JSONDecodeError:
            pass

    return proses.returncode, {
        "status": "ERROR",
        "berhasil": False,
        "pesan": (galat.decode("utf-8", "replace").strip() or "yoructl tidak mengeluarkan JSON"),
    }


def riwayat(kid: str, batas: int = 20) -> List[Dict[str, Any]]:
    """Baris terakhir saja, bukan seluruh sejarah.

    Log tumbuh terus. Membaca seluruh berkas tiap panggilan berarti respons
    API ikut membesar selamanya, dan suatu hari dashboard-nya berhenti muat
    tanpa ada yang tahu kenapa.
    """
    try:
        with open(f"{LOG_DIR}/{kid}.log", encoding="utf-8") as f:
            baris = f.readlines()[-batas:]
    except OSError:
        return []

    keluar = []
    for b in baris:
        b = b.strip()
        if b:
            try:
                keluar.append(json.loads(b))
            except json.JSONDecodeError:
                continue
    return keluar


# ----------------------------------------------------------------- endpoint
@app.get("/kontrol")
async def daftar_kontrol():
    return {
        "kontrol": sorted(SEMUA),
        "aman": sorted(AMAN),
        "berisiko": sorted(BERISIKO),
        "aksi": sorted(AKSI_SAH),
    }


@app.get("/kontrol/{kid}/riwayat")
async def lihat_riwayat(kid: str, batas: int = 20):
    kid = kid.upper()
    if kid not in SEMUA:
        return {"error": "kontrol tidak dikenal"}
    return {"id": kid, "riwayat": riwayat(kid, min(batas, 200))}


@app.post("/kontrol/{kid}", response_model=Jawaban)
async def jalankan(kid: str, p: Permintaan):
    kid = kid.upper()
    if kid not in SEMUA:
        return Jawaban(status="error", id=kid, aksi=p.aksi, butuh_konfirmasi=False,
                       pesan_konfirmasi="kontrol tidak dikenal")

    # periksa dan verifikasi cuma membaca - tidak pernah minta konfirmasi.
    if p.aksi not in AKSI_MENULIS:
        kode, hasil = await panggil_yoructl(kid, p.aksi)
        return Jawaban(status="selesai", id=kid, aksi=p.aksi, butuh_konfirmasi=False,
                       hasil=hasil, kode_keluar=kode)

    # Kontrol AMAN dikerjakan tanpa bertanya. Kalau semuanya butuh
    # persetujuan, pemilik dihujani sepuluh pertanyaan di hari pertama lalu
    # menyetujui semuanya tanpa membaca - dan persetujuan yang diminta untuk
    # segalanya sama saja dengan tidak meminta persetujuan.
    if kid in AMAN:
        kode, hasil = await panggil_yoructl(kid, p.aksi)
        return Jawaban(status="selesai", id=kid, aksi=p.aksi, butuh_konfirmasi=False,
                       hasil=hasil, kode_keluar=kode)

    # Sisanya BERISIKO: harus lewat tiket.
    if p.tiket:
        if (p.jawaban or "").strip().lower() in {"ya", "yes", "setuju", "y"}:
            if not _pakai_tiket(p.tiket, kid, p.aksi):
                return Jawaban(status="ditolak", id=kid, aksi=p.aksi, butuh_konfirmasi=True,
                               pesan_konfirmasi="tiket tidak sah atau sudah kedaluwarsa - ulangi dari awal")
            kode, hasil = await panggil_yoructl(kid, p.aksi)
            return Jawaban(status="selesai", id=kid, aksi=p.aksi, butuh_konfirmasi=False,
                           hasil=hasil, kode_keluar=kode)

        _TIKET.pop(p.tiket, None)
        return Jawaban(status="dibatalkan", id=kid, aksi=p.aksi, butuh_konfirmasi=False,
                       pesan_konfirmasi=f"{p.aksi} pada {kid} dibatalkan pemilik")

    # Belum ada tiket -> tanyakan dulu.
    #
    # Yang ditampilkan di sebelah tombol setuju WAJIB berisi akibatnya, diambil
    # dari 'yang_rusak_kalau_diterapkan' di katalog. Lihat aturan nomor 4 di
    # contract/report.md - orang yang menekan tombol harus sudah membaca
    # akibatnya, dan itu alasan Yoru boleh dipercaya menyentuh server orang.
    _, keadaan = await panggil_yoructl(kid, "periksa")
    tiket = _buat_tiket(kid, p.aksi)
    return Jawaban(
        status="menunggu_konfirmasi", id=kid, aksi=p.aksi, butuh_konfirmasi=True,
        tiket=tiket,
        pesan_konfirmasi=(
            f"{kid} {p.aksi} berisiko dan butuh persetujuan pemilik. "
            f"Keadaan sekarang: {keadaan.get('nilai')}. "
            f"Tampilkan 'yang_rusak_kalau_diterapkan' dari katalog {kid} "
            f"di sebelah tombol setuju sebelum meminta jawaban."
        ),
        hasil=keadaan,
    )
