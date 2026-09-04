# Lane 1 — Dispatcher, Installer, Katalog

Lane ini yang memegang jalur ke hak root. Semua yang lain lewat sini.

---

## Yang sudah selesai

- Katalog 10 kontrol OS, rollback diuji satu per satu
- `cek-semua.sh` — 18 pemeriksaan, lulus setelah reboot
- Satu konflik antar-kontrol ditemukan dan diperbaiki (ufw menimpa sysctl K10)

---

## Yang dikerjakan

### 1. Dispatcher `/opt/yoru/bin/jalankan-kontrol`

Satu-satunya pintu agent ke hak root. Baris sudoersnya:

```
yoru ALL=(root) NOPASSWD: /opt/yoru/bin/jalankan-kontrol
```

Satu skrip. Itu saja. Agent tidak bisa memanggil `rm`, tidak bisa memanggil
`bash`, tidak bisa memanggil apa pun selain skrip ini.

Skripnya hanya menerima dua argumen: nomor kontrol (`K01`–`K10`) dan tindakan
(`periksa` / `terapkan` / `kembalikan` / `verifikasi`). Perintah aslinya ada
**di dalam** skrip, bukan dikirim agent.

Kalimat untuk presentasi: *agent kami tidak bisa menjalankan perintah
sembarangan — dia cuma bisa meminta salah satu dari 40 tindakan yang sudah
kami tulis dan uji sendiri.*

Dua hal yang membuat ini benar-benar bekerja:

**Skripnya tidak boleh bisa ditulis user `yoru`.** Kalau agent bisa mengedit
isinya, dia tinggal menulis ulang skrip itu lalu menjalankannya lewat sudo,
dan pembatasan sudoers jadi tidak ada gunanya. `/opt/yoru/bin/` milik root,
dan skripnya **memeriksa itu sendiri** setiap kali jalan sebelum melakukan
apa pun.

**Prasyarat yang bisa mengunci pemilik dicek dua kali** — di agent, dan lagi
di dispatcher. Agent bilang "sudah saya cek kuncinya ada" itu janji, bukan
jaminan keamanan. Dispatcher harus memastikan sendiri sebelum mematikan login
password.

### 2. Installer

Satu perintah, dijalankan di server pemilik. Sudah termasuk Hermes — jangan
mensyaratkan pemilik memasang Hermes duluan, karena target kita justru orang
yang tidak tahu Hermes itu apa.

Isi paketnya:

```
/opt/yoru/bin/jalankan-kontrol    dispatcher root
/usr/share/yoru/katalog/*.yaml    katalog, milik root, tidak bisa ditulis yoru
/opt/yoru/agent/                  Hermes dan prompt
/etc/yoru/config.yaml             milik pemilik: token telegram, jadwal
```

**Bukan `curl … | sudo bash`.** Kita produk keamanan; menyuruh orang
menyalurkan skrip dari internet langsung ke `sudo bash` persis kebiasaan yang
mau kita berantas. Diunduh dulu, dicek, baru dijalankan.

### 3. Utang katalog

Field `kode_cis` di beberapa YAML masih `BELUM_DIVERIFIKASI` atau ditulis
kasar seperti `5.2.x`. Harus dicek ke dokumen CIS Ubuntu 24.04 asli sebelum
dikutip di laporan atau demo. Kalau juri bertanya dan kita menyebut nomor
yang salah, semua hal lain jadi ikut diragukan.

---

## Dianggap selesai kalau

- `sudo -u yoru sudo /opt/yoru/bin/jalankan-kontrol K01 periksa` mengeluarkan
  JSON yang benar
- `sudo -u yoru sudo rm /etc/passwd` ditolak — sudoers benar-benar membatasi
- Dispatcher menolak jalan kalau file skripnya bisa ditulis selain root
- Installer jalan dari nol di VM bersih, sekali perintah
