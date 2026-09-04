# Yoru

AI agent yang mengeraskan konfigurasi keamanan server, lalu menjaganya tetap
begitu — untuk developer dan UMKM yang tidak punya tim IT.

*Server kamu tidur. Yoru nggak.*

---

## Masalah yang kami kejar

Kebanyakan server kecil di Indonesia dipasang sekali, lalu ditinggal. Bukan
karena pemiliknya malas, tapi karena tidak ada yang mengurus: tidak ada tim
IT, tidak ada waktu, dan istilahnya terlalu asing untuk dipelajari sambil
jalan.

Yoru mengambil pekerjaan itu. Dia memeriksa setelan keamanan server, minta
izin sebelum mengubah apa pun yang berisiko, memperbaikinya, lalu tiap hari
mengecek apakah masih seperti yang disepakati.

---

## Isi repo

```
katalog/        10 kontrol keamanan OS, satu file YAML per kontrol
kontrak/        bentuk data yang dipakai bersama tiga lane — baca ini dulu
contoh/         contoh laporan JSON, supaya bisa mulai tanpa server
cek-semua.sh    periksa 10 kontrol sekaligus (cikal bakal fungsi periksa())
```

---

## Empat kesepakatan kerja

Ini bukan aturan birokrasi. Semuanya lahir dari hal yang sudah pernah
menjebak kami sendiri.

**1. Baca `kontrak/laporan.md` sebelum menulis kode.**
Itu satu-satunya bentuk data yang menyambungkan tiga lane. Selama bentuknya
stabil, kita bertiga bisa kerja tanpa saling menunggu. Kalau ada yang perlu
diubah, bahas dulu di grup — jangan diubah sendiri, karena dua orang lain
sedang membangun di atasnya.

**2. Tidak perlu server bersama.**
Masing-masing jalankan VM lokal. Lane web bahkan tidak butuh VM sama sekali,
cukup bangun di atas `contoh/*.json`.

**3. Sebuah kontrol baru masuk katalog kalau sudah dijalankan manual dan
rollbacknya benar-benar diuji.**
Bukan dibaca dari blog, bukan disalin dari checklist. Kolom `rollback_teruji`
di tiap YAML itu janji, bukan hiasan.

**4. Verifikasi membaca keadaan yang benar-benar aktif, bukan file yang kita
tulis.**
`sshd -T`, bukan `cat file`. Ini pelajaran paling mahal yang kami dapat:
file bisa tertulis, layanan bisa reload tanpa error, dan setelannya tetap
tidak berubah sedikit pun. Tiga tanda hijau di atas server yang masih
terbuka.

---

## Pembagian lane

| Lane | Orang | Kerjaan |
|---|---|---|
| 1 — Sistem | julmukcur | dispatcher + sudoers, installer, katalog |
| 2 — Web | — | dashboard, API, bot Telegram, lalu kontrol web K11–K14 |
| 3 — Agent | — | wiring Hermes, eval set |

---

## Status sekarang

- 10 dari 10 kontrol OS selesai, rollback diuji satu per satu
- Lulus tes reboot: 18 pemeriksaan, semuanya lewat
- Satu konflik antar-kontrol ditemukan dan diperbaiki — ufw ternyata menimpa
  setelan kernel milik K10 setiap kali servicenya start. Ceritanya lengkap
  ada di `katalog/K05.yaml` dan `katalog/K10.yaml`

---

## Yang masih jadi utang

**Nomor CIS belum diverifikasi.** Field `kode_cis` di beberapa YAML masih
`BELUM_DIVERIFIKASI` atau ditulis kasar seperti `5.2.x`. Jangan dikutip di
laporan atau demo sebelum dicek ke dokumen CIS aslinya. Kalau juri bertanya
dan kita menyebut nomor yang salah, semua hal lain jadi ikut diragukan.

**`rp_filter` sengaja tidak diterapkan.** Alasannya ada di `katalog/K10.yaml`,
lengkap dengan penjelasan teknisnya. Ini keputusan, bukan kelalaian.
