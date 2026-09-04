# Ruang Lingkup — dikunci 4 September 2026

Dokumen ini ada supaya proyek tidak melebar. Deploy tanggal 6, kita bertiga,
dan dua lane baru mulai. Risiko terbesar kita bukan "fiturnya kurang" — tapi
"tidak ada satu pun yang jalan utuh sampai selesai".

Kalau ada ide baru di tengah jalan, tulis di bagian paling bawah dokumen ini.
Jangan langsung dikerjakan.

---

## Yang dikerjakan

| | Isi | Lane |
|---|---|---|
| Katalog OS | 10 kontrol, K01–K10 — **sudah selesai** | 1 |
| Dispatcher | `/opt/yoru/bin/yoructl` + sudoers | 1 |
| Installer | satu perintah, sudah termasuk Hermes | 1 |
| Agent | Siklus Perbaikan dan Siklus Penjagaan | 3 |
| Eval | minimal 5 kasus + kunci jawaban | 3 |
| Dashboard | baca laporan JSON, **nempel di 127.0.0.1** | 2 |
| Bot Telegram | notifikasi + tombol setuju/tolak | 2 |
| Katalog web | K11–K14 — **hanya kalau waktunya cukup** | 2 |

---

## Yang TIDAK dikerjakan

Bukan karena jelek. Karena bukan ini produknya, atau tidak muat waktunya.

**Monitoring sistem — grafik CPU, RAM, jaringan, ala htop.**
Ini mengubah Yoru dari "agent keamanan" jadi "panel monitoring yang ada
fitur keamanannya". Di kategori itu kita melawan Netdata, Cockpit, dan
aaPanel yang sudah matang bertahun-tahun, dan pertanyaan "bedanya apa dengan
Netdata?" tidak punya jawaban bagus. Kalau dashboard terasa kosong, isinya
diganti dengan **sinyal keamanan**, bukan metrik sistem:

- percobaan login gagal 24 jam terakhir
- login berhasil terakhir: siapa, dari IP mana, jam berapa
- jumlah tambalan keamanan yang belum dipasang
- berapa hari kontrol bertahan tanpa berubah
- pemakaian log dibanding pagunya

Datanya sudah ada semua dari auditd, journald, dan unattended-upgrades.
Satu-satunya angka sistem yang boleh masuk: **sisa disk** — karena disk penuh
membuat log tidak bisa ditulis dan K09 mati diam-diam.

**Dashboard yang membuka port ke jaringan.**
Kalau Yoru memasang nginx dan membuka dashboard di port 80, artinya Yoru
membuka port baru di server yang katanya sedang dia amankan — langsung
menabrak K06 buatan kita sendiri. Dashboard nempel di `127.0.0.1`, pemilik
mengaksesnya lewat terowongan SSH:

```
ssh -L 8080:127.0.0.1:8080 user@server
```

Tidak ada port baru, tidak perlu TLS, tidak perlu bikin sistem login sendiri
yang justru jadi lubang baru. Untuk sehari-hari pemilik pakai Telegram.
Kalau nanti ada yang tetap mau dibuka ke jaringan, itu jadi pilihan yang
harus diminta eksplisit, dan Yoru sekalian membuatkan aturan ufw yang
membatasi ke IP pemilik.

**Deteksi judi online.** Sudah dibuang sejak awal. Jangan ditarik lagi.

**Agent terpusat yang menyambung ke banyak server.**
Kita pilih model "agent di tiap server". Kalimat jualannya kuat: *kami tidak
menyimpan kunci SSH kamu*. Model terpusat berarti satu kotak memegang akses
ke semua server pelanggan — bobol satu, dapat semua.

**Paket .deb.** Untuk lomba cukup skrip installer. `.deb` masuk roadmap,
diceritakan di presentasi, tidak dikerjakan sekarang.

**Menerapkan kontrol BERISIKO atau BERBAHAYA tanpa izin.** Tidak akan pernah,
bukan cuma sekarang. Ini bukan soal waktu, ini alasan Yoru boleh dipercaya.

**`curl … | sudo bash` sebagai cara install.** Kita produk keamanan. Menyuruh
orang menyalurkan skrip dari internet langsung ke `sudo bash` persis kebiasaan
yang mau kita berantas. Installer diunduh dulu, dicek, baru dijalankan.

---

## Kalau ada ide baru

Tulis di sini. Jangan dikerjakan sebelum lomba selesai.

- (kosong)

---

## Batas waktu yang disepakati

| Kapan | Apa |
|---|---|
| Sabtu 5 Sep sore | Tiap lane punya sesuatu yang **jalan**, sejelek apa pun |
| Sabtu 5 Sep sore | Kalau Lane 3 belum bisa memanggil Hermes sama sekali, Lane 1 mengambil alih wiring dan Lane 3 pindah ke eval set |
| Minggu 6 Sep | Deploy, digabung |

Batas hari Sabtu itu disepakati sekarang, waktu semua masih santai — bukan
nanti waktu sudah mepet dan tinggal saling menyalahkan.
