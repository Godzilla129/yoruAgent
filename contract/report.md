# Kontrak Laporan Yoru — versi 1

Dokumen ini menjelaskan satu-satunya bentuk data yang dipakai bersama oleh
tiga lane. Selama bentuknya stabil, kita bertiga bisa kerja sendiri-sendiri
tanpa server bersama dan tanpa saling menunggu jawaban.

- **Lane 3 (agent)** yang menghasilkan file ini
- **Lane 2 (dashboard + bot)** yang membacanya
- **Lane 1 (dispatcher)** yang mengisi `nilai_terbaca` dan `hasil`

Kalau ada field yang kurang atau artinya membingungkan, bahas di grup dulu.
Mengubahnya sendiri berarti memecahkan kode dua orang lain tanpa mereka tahu.

---

## Di mana filenya

```
/var/lib/yoru/laporan-terakhir.json     selalu ditimpa — ini yang dibaca dashboard
/var/lib/yoru/riwayat/<ISO8601>.json    arsip, tidak dihapus otomatis
```

Selama pengembangan, Lane 2 cukup pakai `examples/laporan-*.json` di repo ini.
Jangan menunggu server nyata untuk mulai membangun tampilan — bentuknya sudah
sama persis.

---

## Bentuknya

### Tingkat atas

| Field | Tipe | Arti |
|---|---|---|
| `versi_kontrak` | string | `"1"` untuk sekarang. Naik kalau bentuknya berubah |
| `versi_yoru` | string | Versi paket, misal `"0.1.0"` |
| `server` | objek | Identitas mesin |
| `waktu` | string | ISO 8601 **berikut zona waktunya** |
| `siklus` | string | `"perbaikan"` atau `"penjagaan"` |
| `ringkasan` | objek | Angka-angka untuk kartu di dashboard |
| `kontrol` | array | Satu entri per kontrol yang diperiksa |
| `drift` | array | Hanya terisi saat siklus penjagaan. Kosong saat perbaikan |
| `butuh_keputusan` | array | Daftar `id` yang menunggu jawaban pemilik — ini yang dikirim bot |

### `server`

```json
{
  "nama": "yoru-a",
  "os": "Ubuntu 24.04.4 LTS",
  "kernel": "6.8.0-138-generic",
  "ip_utama": "192.168.206.132",
  "panel_terdeteksi": null
}
```

`panel_terdeteksi` isinya `null`, `"aapanel"`, `"cpanel"`, atau `"cyberpanel"`.
Dashboard memakainya untuk menampilkan peringatan khusus panel yang sudah
dicatat di katalog — misalnya aaPanel yang butuh port 8888 tetap terbuka.

### `ringkasan`

```json
{ "total": 10, "lulus": 6, "gagal": 3, "sebagian": 1, "dilewati": 0, "skor": 60 }
```

`skor` dihitung dari `lulus / total × 100`, dibulatkan. Ini angka besar yang
pertama kali dilihat orang saat membuka dashboard.

### `kontrol[]`

| Field | Tipe | Arti |
|---|---|---|
| `id` | string | `"K01"` sampai `"K10"` |
| `nama` | string | Nama kontrol, apa adanya dari katalog |
| `kategori` | string | `ssh`, `firewall`, `jaringan`, `log`, `audit`, `pembaruan` |
| `risiko` | string | `AMAN`, `BERISIKO`, `BERBAHAYA` |
| `status` | string | `LULUS`, `GAGAL`, `SEBAGIAN`, `DILEWATI`, `ERROR` |
| `nilai_terbaca` | string | Yang benar-benar ada di server sekarang |
| `nilai_target` | string | Yang seharusnya |
| `kenapa` | string | Penjelasan untuk pemilik server, bukan untuk teknisi |
| `yang_rusak_kalau_diterapkan` | string | Konsekuensinya. Harus terlihat sebelum tombol setuju |
| `butuh_izin` | bool | `true` untuk BERISIKO dan BERBAHAYA |
| `prasyarat_gagal` | array | Kosong kalau aman. Kalau terisi, kontrol ini tidak boleh ditawarkan |
| `hasil` | objek / `null` | Baru terisi setelah kontrolnya dijalankan |

Contoh satu entri:

```json
{
  "id": "K01",
  "nama": "Root tidak bisa login lewat SSH",
  "kategori": "ssh",
  "risiko": "BERISIKO",
  "status": "SEBAGIAN",
  "nilai_terbaca": "without-password",
  "nilai_target": "no",
  "kenapa": "Kalau akun root bisa login langsung dari internet, penyerang cuma perlu menebak satu password untuk menguasai seluruh server.",
  "yang_rusak_kalau_diterapkan": "Script otomatis yang selama ini login sebagai root akan berhenti jalan — misalnya tool backup atau deploy.",
  "butuh_izin": true,
  "prasyarat_gagal": [],
  "hasil": null
}
```

### `kontrol[].hasil` — terisi setelah dijalankan

```json
{
  "tindakan": "terapkan",
  "berhasil": true,
  "nilai_sesudah": "no",
  "diverifikasi": true,
  "snapshot_id": "yoru-K01-20260904T113000",
  "dirollback": false,
  "pesan_error": null,
  "durasi_detik": 2.4
}
```

`tindakan` isinya `"terapkan"`, `"kembalikan"`, atau `"lewati"`.

Satu hal yang tidak bisa ditawar: **`berhasil: true` hanya boleh diisi kalau
`diverifikasi: true`.** Kalau verifikasinya tidak dijalankan atau gagal,
`berhasil` wajib `false`.

Kami menaruh aturan ini di sini karena sudah pernah kena. Waktu mengerjakan
K02, file drop-in berhasil ditulis, `sshd -t` bilang valid, `systemctl reload`
tidak mengeluarkan error apa pun — dan setelan servernya sama sekali tidak
berubah, karena kalah urutan dengan file bawaan cloud-init. Tiga tanda hijau
di atas server yang masih terbuka. "Perintahnya jalan" bukan bukti berhasil;
yang jadi bukti cuma pembacaan ulang keadaan efektif.

### `drift[]` — hanya saat siklus penjagaan

```json
{
  "id": "K06",
  "nama": "Cuma port yang dipakai yang boleh terbuka",
  "berubah_dari": "127.0.0.1:3306",
  "berubah_jadi": "0.0.0.0:3306",
  "terdeteksi": "2026-09-08T03:00:12+07:00",
  "siapa": "budi",
  "kapan_diubah": "2026-09-07T22:14:08+07:00",
  "perintah": "vim /etc/mysql/mariadb.conf.d/zz-yoru-k06.cnf",
  "sumber_bukti": "auditd",
  "keputusan_pemilik": null
}
```

`siapa`, `kapan_diubah`, dan `perintah` datang dari auditd (K08). Boleh `null`
kalau memang tidak ada jejaknya.

`keputusan_pemilik` isinya `null` (belum dijawab), `"sah"` (berarti ini
perubahan yang disengaja, jadikan patokan baru), atau `"kembalikan"`.

Jawaban di field inilah yang memperbarui baseline. Ini engsel yang
menyambungkan Siklus Perbaikan dengan Siklus Penjagaan — tanpa itu, Yoru
cuma jadi alarm yang bunyi terus dan lama-lama diabaikan.

---

## Empat hal yang tidak boleh dilanggar

**1. Status dan angka selalu string atau bool, jangan kalimat bebas.**
Dashboard menentukan warna dari field `status`, bukan menebak dari kata-kata.

**2. Field tidak boleh hilang.**
Kalau nilainya belum ada, isi `null`. Jangan hapus fieldnya — kode yang
membaca field yang tidak ada akan error, dan errornya muncul di layar orang
lain, bukan di layar yang menghapus.

**3. `waktu` selalu ikut zona.**
Jam server itu UTC, pemiliknya membaca WIB. Selisihnya 7 jam, dan itu sudah
pernah bikin kami salah paham sendiri.

**4. Kalau `butuh_izin` bernilai `true`, dashboard harus menampilkan
`yang_rusak_kalau_diterapkan` di sebelah tombol setuju.**
Bukan di tooltip, bukan di halaman lain. Orang yang menekan tombol harus
sudah membaca konsekuensinya. Ini bukan soal tata letak — ini alasan Yoru
boleh dipercaya menyentuh server orang.

---

## Kalau kontrak ini perlu berubah

Naikkan `versi_kontrak`, kabari dua lane lain, dan simpan contoh JSON versi
lama di `examples/`. Jangan mengganti arti sebuah field tanpa menaikkan versi.
