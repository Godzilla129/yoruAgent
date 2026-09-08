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

Kedua folder itu dibuat oleh `install.sh` dan dimiliki `yoru-agent` dengan izin
`750`. Itu satu-satunya tempat yang boleh ditulis agent — laporan memang
keluarannya sendiri. Catatan tindakan di `/var/log/yoru/tindakan.log` tetap
milik root dan tidak bisa disentuh agent, karena alat keamanan tidak boleh
bisa menyunting jejaknya sendiri.

Kalau ada proses lain di server yang perlu membaca laporan langsung dari
disk, masukkan penggunanya ke grup `yoru-agent`. Jangan melonggarkan izin
foldernya.

Selama pengembangan, Lane 2 cukup pakai dua contoh ini di repo:

```
examples/report-fix.json      siklus perbaikan, server sakit, skor 10
examples/report-watch.json    siklus penjagaan, server sehat, ada satu drift
```

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

---

## Catatan tindakan dan pemetaan endpoint

### Satu perintah, dua argumen

Tidak ada 40 skrip terpisah. Ada satu dispatcher, dan pemetaannya sudah 1:1:

```
POST /kontrol/K01/periksa      →   yoructl K01 periksa
POST /kontrol/K01/terapkan     →   yoructl K01 terapkan
POST /kontrol/K01/kembalikan   →   yoructl K01 kembalikan
POST /kontrol/K01/verifikasi   →   yoructl K01 verifikasi
```

Kontrolnya `K01` sampai `K10`, tindakannya empat itu saja. Keluarannya satu
baris JSON, langsung bisa diteruskan sebagai isi respons.

Sengaja satu berkas, bukan empat puluh. Alasannya ada tiga: logika bersamanya
tidak perlu diduplikasi empat puluh kali, izin sudoers tetap satu baris yang
bisa dibaca siapa pun, dan pemeriksaan-diri dispatcher cukup dijalankan
sekali. Satu bug yang kami temukan minggu ini butuh satu perbaikan — kalau
sudah terpecah, butuh empat puluh, dan kemungkinan besar hanya ketemu di satu.

### Satu tindakan menulis pada satu waktu

Sejak yoructl 0.1.5, `terapkan` dan `kembalikan` **antre** — hanya satu yang
boleh jalan di seluruh server pada satu waktu. `periksa` dan `verifikasi`
tidak ikut antre, karena keduanya cuma membaca.

Kuncinya satu untuk semua kontrol, bukan satu per kontrol, karena kontrolnya
berbagi berkas: K01–K04 sama-sama menulis ke `/etc/ssh/sshd_config.d`, dan
K05 dengan K10 sama-sama menyunting `/etc/default/ufw`. Kunci per kontrol
akan terasa aman padahal dua `sed -i` masih bisa jalan bersamaan di berkas
yang sama.

**Yang perlu ditangani dashboard:** kalau ada tindakan menulis lain yang
sedang berjalan, panggilan baru akan menunggu sampai 120 detik. Kalau lewat
dari itu, jawabannya:

```json
{"id":"K06","tindakan":"terapkan","status":"DITOLAK","berhasil":false,
 "nilai":null,"pesan":"kontrol lain sedang diterapkan atau dikembalikan - sudah menunggu 120 detik, coba lagi nanti"}
```

Ini **bukan kegagalan kontrol** — servernya tidak disentuh sama sekali.
Tampilkan sebagai "sedang sibuk, coba lagi", bukan sebagai kontrol gagal, dan
jangan ubah skor karenanya. Tombolnya boleh dinyalakan lagi.

Kenapa ini ada: tanpa kunci, dua proses bisa mengerjakan hal yang
berlawanan sekaligus. Diuji 8 Sep 2026 di K06 dengan restart yang sengaja
dibuat lambat — tanpa kunci, dua `systemctl restart mariadb` berjalan
bertumpuk dan **dua-duanya melapor sukses**; dengan kunci, yang kedua
menunggu yang pertama selesai.

### Port terbuka: jawaban pemilik dipakai K05

`K05 periksa` mengisi field `pesan` dengan port TCP yang terbuka ke luar tapi
belum pernah dijawab pemilik, berikut nama prosesnya:

```json
{"id":"K05","tindakan":"periksa","status":"GAGAL","berhasil":true,
 "nilai":"inactive",
 "pesan":"port terbuka belum dijawab pemilik: 80(nginx) 443(nginx) 8888(python3)"}
```

Port SSH tidak pernah muncul di sini (dicari sendiri dari `sshd -T`), begitu
juga port yang cuma mendengar di `127.0.0.1` atau `[::1]`.

**Yang harus dikerjakan agent:** tanyakan tiap port ke pemilik — "port 8888
terbuka dipakai python3, itu panel kamu?" — lalu tulis yang dijawab "iya" ke:

```
/var/lib/yoru/port-disetujui      satu port per baris, boleh diberi "# keterangan"
```

Berkas ini milik agent, jadi agent boleh menulisnya. Isinya divalidasi
yoructl: hanya angka 1–65535 yang dipakai, sisanya dibuang.

Selama masih ada port yang belum dijawab, **`K05 terapkan` akan `DITOLAK`**
dan firewall tidak disentuh sama sekali. Itu bukan kegagalan — itu Yoru
menunggu jawaban. Dashboard sebaiknya menampilkannya sebagai pertanyaan yang
menunggu, bukan sebagai kontrol gagal.

Pemilik yang lebih suka menetapkannya sendiri bisa mengisi `PORT_DIIZINKAN`
di `/etc/yoru/yoru.conf`. Keduanya dibaca; yang di `yoru.conf` lebih kuat
karena agent tidak bisa menyuntingnya.

### Catatan tindakan

```
/var/log/yoru/tindakan.log   semua tindakan, urut waktu
/var/log/yoru/K01.log        salinan khusus K01, dan seterusnya sampai K10
```

Satu baris JSON per tindakan (JSON Lines), jadi dashboard tinggal parse per
baris tanpa perlu menebak format. Berkas per kontrol ada supaya "riwayat K05"
tidak perlu menyaring berkas gabungan.

```json
{"waktu":"2026-09-07T13:22:11+07:00","versi":"0.1.3","pemanggil":"yoru-agent",
 "id":"K05","tindakan":"terapkan","status":"LULUS","berhasil":true,
 "nilai":"active","pesan":null}
```

| Field | Isi |
|---|---|
| `waktu` | ISO 8601 berikut zona |
| `versi` | versi yoructl yang menjalankan |
| `pemanggil` | pengguna yang memanggil lewat sudo |
| `id` | `K01`–`K10` |
| `tindakan` | `periksa`, `terapkan`, `kembalikan`, `verifikasi` |
| `status` | `LULUS`, `GAGAL`, `DIKEMBALIKAN`, `DILEWATI`, `DITOLAK`, `ERROR`, `PERINGATAN` |
| `berhasil` | bool. `false` berarti perintahnya sendiri bermasalah |
| `nilai` | keadaan yang terbaca, atau `null` |
| `pesan` | keterangan, atau `null` |

Folder ini milik root dan agent tidak bisa menulis ke sini — alat keamanan
tidak boleh bisa menyunting jejaknya sendiri. Berkasnya `640`, jadi bacanya
lewat root.

### Rekaman keadaan asal

Sebelum sebuah kontrol diterapkan **pertama kali** di sebuah server, keadaan
sebelumnya direkam dulu:

```
/var/backups/yoru/K05/tercatat        stempel waktu perekaman
/var/backups/yoru/K05/keadaan.json    bacaan yang sedang berlaku saat itu
/var/backups/yoru/K05/berkas/...      salinan berkas yang akan disentuh
```

Direkam sekali, tidak pernah ditimpa — rekaman pertama itu yang benar-benar
"sebelum Yoru"; rekaman kedua cuma memotret hasil kerja Yoru sendiri.

Berkas, bukan database. Rollback justru paling dibutuhkan saat servernya
sedang bermasalah, dan database adalah satu lagi hal yang bisa ikut mati.
Salinannya boleh dikirim ke dashboard untuk disimpan, tapi yang dipakai
memulihkan tetap yang ada di server.

Milik root dengan izin `700`. Agent boleh mengubah server, tapi tidak boleh
mengubah catatan tentang bagaimana server itu sebelum dia datang.

**Yang belum:** `kembalikan` masih memulihkan ke nilai bawaan yang ditulis di
katalog, belum membaca rekaman ini. Perekamannya sudah jalan, pemulihannya
menyusul.
