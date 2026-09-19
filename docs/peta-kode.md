# Peta kode Yoru

Buat dibaca pelan pelan, ga usah sekali duduk. Tujuannya satu: biar lu tau
file mana yang ngapain, dan file mana yang boleh lu lewatin.

---

## Satu aturan yang bikin semuanya masuk akal

> **Yoru boleh mikir sebebas bebasnya. Tapi yang boleh nyentuh server cuma
> satu file, dan file itu ga bisa ngarang.**

Kalau lu pegang kalimat itu, tugas tiap file jadi kebaca sendiri. Semua
pemisahan yang keliatan ribet di kode itu asalnya dari sini.

Kenapa harus gitu? Customer kita orang yang ga punya tim IT. Kalau AI boleh
ngarang perintah shell, satu halusinasi di config SSH bisa bikin dia kekunci
dari servernya sendiri, dan ga ada siapa siapa yang bisa nolongin.

---

## Kalau cuma mau baca SATU file

Baca `bin/yoru.sudoers`. Isinya 13 baris, dan yang penting cuma satu:

```
yoru-agent ALL=(root) NOPASSWD: /opt/yoru/bin/yoructl
```

Artinya: user `yoru-agent` boleh manggil **satu berkas** sebagai root. Bukan
bash, bukan rm, bukan apt. Satu berkas.

Itu seluruh model keamanan Yoru. Sisa kodenya cuma cara hidup di dalam batas
itu.

---

## File apa ngapain

Diurut dari yang paling penting buat dipahami.

| File | Baris | Tugasnya |
|---|---|---|
| `bin/yoru.sudoers` | 13 | Batas izin. Baca ini duluan. |
| `catalog/K01..K10.yaml` | kecil | **Faktanya.** Tiap kontrol: namanya apa, kenapa penting, nilai targetnya berapa, apa yang rusak kalau diterapin. Ditulis manusia, bukan AI. |
| `bin/yoructl` | 930 | **Satu satunya yang nyentuh server.** 10 kontrol x 4 tindakan (`periksa` `terapkan` `kembalikan` `verifikasi`). Jalan sebagai root. |
| `bin/yoru-agent` | 867 | Otaknya. Baca semua kontrol, urutin, minta model AI bikin kalimatnya, kirim laporan ke dashboard dan Telegram. **Ga pernah jalanin perintah sendiri** — selalu lewat yoructl. |
| `web/api.py` | 774 | Server dashboard + bot Telegram. Nerima laporan, simpen ke SQLite, layanin tombol. |
| `web/dashboard.html` | 1329 | Halamannya. Satu file, HTML + CSS + JS jadi satu. |
| `install.sh` | 1559 | Installer. Paling panjang tapi paling ga perlu dipahami. |
| `bin/yoru-model-proxy` | 298 | Jembatan ke Gemini. Nyimpen API key, biar agent ga pernah liat kuncinya. |
| `bin/yoru-watch` | 81 | Bungkus kecil yang dipanggil systemd tiap hari jam 03:17. |

---

## Jalan datanya, satu arah

```
   systemd timer (tiap hari 03:17)
        |
        v
   bin/yoru-watch  ->  bin/yoru-agent
                            |
              baca katalog  |  panggil yoructl (lewat sudo)
                            |
                            v
                       laporan JSON
                            |
              POST ke dashboard (127.0.0.1)
                            |
                            v
                       web/api.py  ->  SQLite
                            |
                  +---------+---------+
                  |                   |
             dashboard            Telegram
```

Yang penting: **dashboard ga pernah nelpon server yang dijaga.** Agent yang
setor laporan, dan agent juga yang ngambil keputusan lu di siklus berikutnya.
Jadi ga ada pintu masuk baru ke server.

---

## Kalau mau ngerti hal tertentu

| Pertanyaan lu | Buka file ini |
|---|---|
| "Kontrol K05 itu ngapain sih?" | `catalog/K05.yaml` — bahasa manusia, bukan kode |
| "Perintah apa yang beneran dijalanin?" | `bin/yoructl`, cari `k05()` — tiap kontrol satu fungsi, isinya `case` buat empat tindakannya |
| "Kenapa skornya 80?" | `bin/yoru-agent`, cari `"summary"` |
| "Urutan kerjanya gimana?" | `bin/yoru-agent`, cari `ORDER =` |
| "Tombol di dashboard manggil apa?" | `web/dashboard.html`, cari `async function run(` (baris 1262) |
| "Telegram jawabnya dari mana?" | `web/api.py`, cari `handle_message` |
| "Tombol setuju di Telegram?" | `web/api.py`, cari `handle_callback` |
| "Installer ngecek apa aja?" | `install.sh`, cari `check_all()` |

Tips: di tiap file, fungsi yang penting punya komentar di atasnya yang
njelasin **kenapa**, bukan cuma apa. Yang ga ada komentarnya biasanya emang
ga penting.

---

## Yang ga usah dibaca

- `install.sh` — 1559 baris, dan isinya 90% penanganan hal yang jarang
  kejadian. Cukup tau: dia ngecek dulu, nanya di depan, baru kerja.
- `web/dashboard.html` bagian CSS — 340 baris warna dan jarak.
- `web/test_api.py`, `web/demo.py`, `demo.sh`, `check-all.sh` — alat uji.
- `contract/report.md` — bentuk JSON laporan. Berguna kalau nanti ada yang
  bikin klien lain, ga berguna buat ngerti cara kerjanya.

---

## Ngerti tanpa baca kode

Ini yang paling cepet. Semua perintah di bawah aman, ga ngubah apa apa.

**Liat satu kontrol diperiksa, apa adanya:**

```
sudo -u yoru-agent sudo -n /opt/yoru/bin/yoructl K05 periksa
```

Keluarnya satu baris JSON. Itu bahasa yang dipakai seluruh sistem.

**Liat agent kerja satu siklus penuh tanpa ngubah apa apa:**

```
sudo -u yoru-agent /opt/yoru/bin/yoru-agent --siklus penjagaan --kering
```

**Liat installer mikir tanpa masang apa apa:**

```
sudo bash install.sh --check-only
```

**Buktiin sendiri kalau agent emang dikurung:**

```
sudo -u yoru-agent sudo -n id
```

Harus ditolak. Kalau ini jalan, model keamanannya bocor.

**Liat jejak semua tindakan:**

```
sudo tail -20 /var/log/yoru/tindakan.log
```

---

## Kalau lagi bingung, urutan ini biasanya kejawab

1. Buka `catalog/` — di situ semuanya bahasa manusia, ga ada kode sama sekali
2. Jalanin `yoructl K05 periksa` — liat outputnya
3. Baru buka `bin/yoructl` dan cari fungsi K05-nya

Dari bawah ke atas gitu lebih gampang daripada baca dari baris pertama.
