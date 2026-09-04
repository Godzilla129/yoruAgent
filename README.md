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
catalog/        10 kontrol keamanan OS, satu file YAML per kontrol
contract/        bentuk data yang dipakai bersama tiga lane — baca ini dulu
examples/         contoh laporan JSON, supaya bisa mulai tanpa server
check-all.sh    periksa 10 kontrol sekaligus (cikal bakal fungsi periksa())
```

---

## Empat kesepakatan kerja

Ini bukan aturan birokrasi. Semuanya lahir dari hal yang sudah pernah
menjebak kami sendiri.

**1. Baca `contract/report.md` sebelum menulis kode.**
Itu satu-satunya bentuk data yang menyambungkan tiga lane. Selama bentuknya
stabil, kita bertiga bisa kerja tanpa saling menunggu. Kalau ada yang perlu
diubah, bahas dulu di grup — jangan diubah sendiri, karena dua orang lain
sedang membangun di atasnya.

**2. Tidak perlu server bersama.**
Masing-masing jalankan VM lokal. Lane web bahkan tidak butuh VM sama sekali,
cukup bangun di atas `examples/*.json`.

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

Rincian tiap lane ada di folder `tasks/`. Baca punyamu sampai habis sebelum
mulai — di situ ada juga daftar hal yang **tidak** dikerjakan, supaya kita
tidak berjalan ke arah yang berbeda-beda.

| Lane | Orang | Kerjaan | Rincian |
|---|---|---|---|
| 1 — Sistem | julmukcur | dispatcher + sudoers, installer, katalog | `tasks/lane-1-system.md` |
| 2 — Web | — | dashboard, API, bot Telegram | `tasks/lane-2-web.md` |
| 3 — Agent | — | wiring Hermes, eval set | `tasks/lane-3-agent.md` |

Batas ruang lingkup proyek ada di **`SCOPE.md`** dan sudah dikunci
tanggal 4 September. Ide baru ditulis di bagian bawah dokumen itu, tidak
langsung dikerjakan.

---

## Status sekarang

- 10 dari 10 kontrol OS selesai, rollback diuji satu per satu
- Lulus tes reboot: 18 pemeriksaan, semuanya lewat
- Satu konflik antar-kontrol ditemukan dan diperbaiki — ufw ternyata menimpa
  setelan kernel milik K10 setiap kali servicenya start. Ceritanya lengkap
  ada di `catalog/K05.yaml` dan `catalog/K10.yaml`

---

## Yang masih jadi utang

**Nomor CIS belum diverifikasi.** Field `kode_cis` di beberapa YAML masih
`BELUM_DIVERIFIKASI` atau ditulis kasar seperti `5.2.x`. Jangan dikutip di
laporan atau demo sebelum dicek ke dokumen CIS aslinya. Kalau juri bertanya
dan kita menyebut nomor yang salah, semua hal lain jadi ikut diragukan.

**`rp_filter` sengaja tidak diterapkan.** Alasannya ada di `catalog/K10.yaml`,
lengkap dengan penjelasan teknisnya. Ini keputusan, bukan kelalaian.
