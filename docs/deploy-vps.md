# Pasang Yoru di VPS

Catatan buat waktu deploy. Dibaca **sebelum** ngetik apa-apa di server, bukan
sambil jalan.

Bedanya sama VM uji kita ada tiga, dan ketiganya bisa bikin kekunci di luar
server kalau kelewat:

1. SSH-nya **bukan di port 22**. CloudBaik pakai **4422**.
2. Masuknya sebagai **root**, padahal Yoru **nolak root jadi pemilik**.
3. K02 matiin login password. Kalau kunci SSH belum kepakai beneran, itu
   nutup satu-satunya jalan masuk.

---

## 0. Sebelum apa pun — ganti password root

Password root VPS pernah kekirim lewat WhatsApp dan ke-screenshot. Anggap
udah bocor.

```bash
ssh -p 4422 root@<ip-vps>
passwd
```

Kalau nanti kunci SSH udah jalan, password root nggak dipakai lagi sama
sekali — tapi tetap ganti sekarang, jangan nunggu.

---

## 1. Bikin akun manusia

Yoru **nolak** kalau pemiliknya root:

```
pemilik tidak boleh root - Yoru butuh akun manusia biasa
```

Itu disengaja. Pemilik itu akun yang dipakai buat masuk setelah K01 dan K02
nyala. Kalau root, dua kontrol itu langsung nutup jalan masuknya sendiri.

Jalanin sebagai root di VPS:

```bash
adduser --gecos "" yoru-owner
usermod -aG sudo yoru-owner
```

Nama `yoru-owner` bebas diganti. Yang penting **bukan root** dan **ada di
grup sudo**.

---

## 2. Pasang kunci SSH ke akun itu, terus BUKTIIN jalan

Ini langkah yang paling sering dianggap remeh dan paling fatal kalau
dilewatin.

Dari **laptop**, bukan dari server:

```bash
ssh-keygen -t ed25519 -C "yoru-deploy"          # kalau belum punya
ssh-copy-id -p 4422 yoru-owner@<ip-vps>
```

Terus **beneran login pakai kunci itu**, minimal sekali:

```bash
ssh -p 4422 yoru-owner@<ip-vps>
```

Kenapa harus beneran login: K02 `terapkan` nggak percaya sama file
`authorized_keys` doang. Dia nyari **bukti** di jejak sistem:

```bash
sudo journalctl -t sshd --since "-30 days" | grep "Accepted publickey for yoru-owner"
```

Kalau baris itu nggak ada, K02 bakal nolak:

```
belum ada bukti login SSH key berhasil - menerapkan ini menutup satu-satunya jalan masuk
```

Itu penjaganya lagi kerja dengan benar. Jangan diakalin — login beneran aja.

**Jangan tutup sesi SSH root yang sekarang** sampai sesi `yoru-owner` kebukti
bisa masuk. Buka terminal kedua, jangan gantiin yang pertama.

---

## 3. Pastiin ufw ada

Ubuntu 24.04 bawaannya udah ada. Cek aja:

```bash
which ufw || sudo apt-get install -y ufw
```

Kalau nggak ada, K05 `terapkan` nolak dengan `ufw tidak terpasang`. Nggak
merusak apa-apa, cuma nggak jalan.

---

## 4. Ambil repo dan pasang

Sebagai `yoru-owner`:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/Godzilla129/yoruAgent.git
cd yoruAgent
sudo bash install.sh --pemilik yoru-owner
```

Installernya nanya dua hal: token bot Telegram dan URL dashboard. Boleh
dikosongin dulu, tinggal Enter — nanti tinggal edit `/etc/yoru/yoru.conf`.

Di akhir dia bakal ngasih peringatan kuning kalau `/opt/yoru/bin/yoru-agent`
belum ada. Itu **wajar** — itu bagiannya Hermes (Lane 3), belum kepasang.
Dispatcher, katalog, sama timernya sendiri udah siap.

---

## 5. Periksa dulu, jangan langsung terapkan

`periksa` nggak nyentuh apa pun. Aman dijalanin kapan aja:

```bash
sudo bash check-all.sh
```

Atau satu-satu lewat jalur yang beneran dipakai agent:

```bash
for k in K01 K02 K03 K04 K05 K06 K07 K08 K09 K10; do
  sudo -u yoru-agent sudo -n /opt/yoru/bin/yoructl $k periksa
done
```

Baca hasilnya dulu. Baru terapkan.

---

## 6. Urutan terapkan

Yang **AMAN** dulu — ini nggak bisa mutus akses:

```bash
for k in K03 K07 K08 K09 K10; do
  sudo -u yoru-agent sudo -n /opt/yoru/bin/yoructl $k terapkan
  sudo -u yoru-agent sudo -n /opt/yoru/bin/yoructl $k verifikasi
done
```

Terus yang **BERISIKO**, satu-satu, jangan diloop:

| Urutan | Kontrol | Yang perlu diperhatiin |
|---|---|---|
| 1 | K05 firewall | Cek dulu `ufw show added` ada port 4422. Habis nyala, **buka sesi SSH baru dari terminal lain** buat mastiin masih bisa masuk. |
| 2 | K04 kripto | Kalau klien SSH-nya baru, aman. |
| 3 | K01 root SSH | Setelah ini root nggak bisa SSH lagi. Pastiin `yoru-owner` udah kepake. |
| 4 | K02 password off | **Paling akhir.** Setelah ini cuma kunci SSH yang bisa masuk. |
| 5 | K06 database | Cuma kalau ada MariaDB. |

Aturan yang nggak boleh dilanggar: **abis tiap kontrol berisiko, buka sesi
SSH baru dari terminal lain.** Sesi yang lagi jalan nggak keputus sama
perubahan setelan — jadi sesi lama bukan bukti apa-apa. Yang bukti itu sesi
baru.

Kalau sesi baru gagal masuk, sesi lama masih kebuka, dan tinggal:

```bash
sudo -u yoru-agent sudo -n /opt/yoru/bin/yoructl <kontrol> kembalikan
```

---

## 7. Kalau kekunci beneran

CloudBaik punya konsol web (VNC). Itu nggak lewat SSH, jadi tetap bisa masuk
walau SSH-nya mati total. Login pakai root + password baru dari langkah 0,
terus:

```bash
ufw disable
rm -f /etc/ssh/sshd_config.d/01-yoru-*.conf
systemctl restart ssh
```

Cari letak konsolnya di panel CloudBaik **sekarang**, sebelum deploy — bukan
pas panik.

---

## 8. Sesudah deploy

```bash
systemctl list-timers yoru-watch.timer          # jadwal penjagaan
sudo tail -f /var/log/yoru/tindakan.log         # jejak audit
ls /var/backups/yoru/                           # rekaman keadaan asal
```

Rekaman di `/var/backups/yoru/` kerekam otomatis pas `terapkan` pertama tiap
kontrol. Kalau folder itu kosong padahal udah terapkan, ada yang salah —
laporin, jangan lanjut.

---

## Yang perlu dicatat, biar nggak lupa

- Port SSH: **4422**, bukan 22
- Pemilik: akun biasa di grup sudo, **bukan root**
- K02 butuh bukti login kunci SSH di journald, bukan cuma file
- `kembalikan` di K05 ngehapus **semua** aturan firewall, termasuk yang bukan
  bikinan Yoru (arsipnya ada di `/etc/ufw/user.rules.<tanggal>`)
- Sesi SSH lama bukan bukti. Sesi baru yang bukti.
