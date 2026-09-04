# Lane 2 — Dashboard, API, dan Bot Telegram

Kamu **tidak butuh server sama sekali** untuk mulai. Semua data yang kamu
perlukan sudah ada di repo ini sebagai file contoh.

Baca `kontrak/laporan.md` dulu sebelum menulis kode. Itu satu-satunya bentuk
data yang menghubungkan kita bertiga, dan sudah final.

---

## Yang dikerjakan, berurutan

### 1. Dashboard baca file JSON (prioritas utama)

Bikin halaman yang membaca `contoh/laporan-perbaikan.json` dan
`contoh/laporan-penjagaan.json`, lalu menampilkannya.

Dua file itu bentuknya **persis sama** dengan yang nanti dikeluarkan agent.
Kalau dashboard jalan di dua file itu, dia akan jalan di server sungguhan
tanpa diubah.

Yang harus ada di layar:

- **Skor besar** dari `ringkasan.skor` — angka pertama yang dilihat orang
- **Daftar 10 kontrol**, warna mengikuti `status`:
  `LULUS` hijau, `GAGAL` merah, `SEBAGIAN` kuning, `DILEWATI` abu, `ERROR` merah tua
- Tiap kontrol menampilkan `nama`, `nilai_terbaca`, `nilai_target`, dan `kenapa`
- Kalau `drift` tidak kosong, tampilkan paling atas — lengkap dengan `siapa`,
  `kapan_diubah`, dan `perintah`. Ini bagian yang paling mengesankan waktu demo
- Tombol **Setuju** dan **Tolak** untuk kontrol yang `butuh_izin` bernilai true

### Aturan yang tidak boleh dilanggar

Kalau `butuh_izin` bernilai `true`, teks `yang_rusak_kalau_diterapkan`
**harus terlihat di sebelah tombol Setuju** — bukan di tooltip, bukan di
halaman lain, bukan setelah diklik.

Orang yang menekan tombol itu sedang mengizinkan perubahan di servernya
sendiri. Dia harus sudah membaca konsekuensinya. Ini bukan soal tata letak,
ini alasan Yoru boleh dipercaya menyentuh server orang.

### 2. Bot Telegram

BotFather, sekitar 10 menit. Jangan pakai WhatsApp Business API — itu proses
berhari-hari dan kita tidak punya waktunya.

Yang dikirim bot:
- ringkasan setelah Siklus Perbaikan selesai
- notifikasi kalau ada isi `drift`
- tombol setuju/tolak untuk tiap `id` di `butuh_keputusan`

Dashboard untuk **melihat**, Telegram untuk **bertindak cepat**. Sumber
datanya sama, cuma tampilannya beda.

### 3. Kontrol web K11–K14 — hanya kalau waktunya cukup

Kalau dashboard dan bot sudah jalan dan masih ada waktu. Bentuk file YAML-nya
ikut pola `katalog/K01.yaml`. Aturannya sama: **satu kontrol baru masuk
katalog kalau kamu sudah menjalankannya manual dan rollbacknya benar-benar
diuji.** Bukan disalin dari artikel.

---

## Dianggap selesai kalau

- Dashboard menampilkan kedua file contoh dengan benar, tanpa error di konsol
- Ganti file JSON-nya, tampilan ikut berubah — tidak ada nilai yang dihardcode
- Tombol setuju tidak bisa diklik sebelum teks konsekuensi terlihat
- Bot Telegram mengirim satu pesan uji ke grup kita

---

## Yang tidak dikerjakan

Baca `RUANG-LINGKUP.md`. Ringkasnya:

- **Jangan bikin grafik CPU, RAM, atau jaringan.** Bukan itu produknya, dan
  itu bikin kita kelihatan seperti Netdata versi kurang matang
- **Dashboard nempel di `127.0.0.1` saja.** Jangan buka port ke jaringan.
  Pemilik mengaksesnya lewat `ssh -L 8080:127.0.0.1:8080 user@server`.
  Yoru tidak boleh membuka port di server yang katanya sedang dia amankan
- **Jangan menambah field ke JSON sendiri.** Kalau ada yang kurang, bahas di
  grup dulu — dua orang lain sedang membangun di atas bentuk yang sama

---

## Tiga langkah pertama

1. Clone repo, baca `kontrak/laporan.md` sampai habis
2. Buka `contoh/laporan-perbaikan.json`, cocokkan tiap field dengan
   penjelasannya di kontrak
3. Bikin halaman paling sederhana: skor besar + 10 baris berwarna. Itu saja
   dulu. Sisanya menyusul
