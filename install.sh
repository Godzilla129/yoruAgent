#!/bin/bash
# install.sh - pemasang Yoru
#
# Pakai:
#   sudo bash install.sh                 pasang
#   sudo bash install.sh --pemilik budi  pasang, tentukan pemilik server
#   sudo bash install.sh --tanpa-tanya   pasang tanpa tanya jawab
#   sudo bash install.sh --copot         copot
#
# Skrip ini SENGAJA tidak dirancang untuk dijalankan lewat
# "curl ... | sudo bash". Kami produk keamanan; menyuruh orang menyalurkan
# skrip dari internet langsung ke sudo bash persis kebiasaan yang mau kami
# berantas. Unduh dulu, baca, baru jalankan.
#
# Aman dijalankan berulang kali - setiap langkah memeriksa keadaan dulu.

set -uo pipefail
umask 022
export LC_ALL=C
PATH=/usr/sbin:/usr/bin:/sbin:/bin

ASAL="$(dirname "$(readlink -f "$0")")"

# Versi dibaca dari dispatcher, bukan ditulis ulang di sini. Dulu dua angka
# ini terpisah dan langsung melenceng - installer masang 0.1.1 tapi nyetak
# "Yoru 0.1.0" di judul, dan orang ngira pemasangannya gagal.
VERSI="$(awk -F'"' '/^VERSI=/ {print $2; exit}' "$ASAL/bin/yoructl" 2>/dev/null)"
[ -n "$VERSI" ] || VERSI="tidak-terbaca"

AGEN=yoru-agent
DIR_BIN=/opt/yoru/bin
DIR_CATALOG=/usr/share/yoru/catalog
DIR_ETC=/etc/yoru
DIR_LOG=/var/log/yoru
DIR_DATA=/var/lib/yoru
DIR_SYSTEMD=/etc/systemd/system
KONF="$DIR_ETC/yoru.conf"
SUDOERS=/etc/sudoers.d/yoru

H=$'\033[0m'; HIJAU=$'\033[32m'; MERAH=$'\033[31m'; KUNING=$'\033[33m'; TEBAL=$'\033[1m'
langkah() { printf '\n%s==> %s%s\n' "$TEBAL" "$1" "$H"; }
ok()      { printf '    %sok%s   %s\n' "$HIJAU" "$H" "$1"; }
lewat()   { printf '    %s--%s   %s\n' "$KUNING" "$H" "$1"; }
mati()    { printf '\n    %sberhenti%s  %s\n\n' "$MERAH" "$H" "$1"; exit 1; }

# --------------------------------------------------- baca/tulis konfigurasi
# Sama dengan ambil() di bin/yoru-watch, dan sama-sama tidak pakai "source" -
# isinya kunci API, dan nilai yang mengandung $(...) bakal dijalankan.
#
# Jangan pakai -F= lalu menyunting $1. Menyentuh $1 bikin awk menyusun ulang
# $0 pakai spasi, dan semua "=" di baris itu hilang.
ambil_konf() {  # ambil_konf <berkas> <kunci>
  [ -r "$1" ] || return 0
  awk -v k="$2" '
    {
      baris = $0
      sub(/^[[:space:]]+/, "", baris)
      if (baris ~ /^#/ || baris == "") next
      p = index(baris, "=")
      if (p == 0) next
      nama  = substr(baris, 1, p - 1)
      nilai = substr(baris, p + 1)
      sub(/[[:space:]]+$/, "", nama)
      sub(/^[[:space:]]+/, "", nilai); sub(/[[:space:]]+$/, "", nilai)
      gsub(/^"|"$/, "", nilai)
      if (nama == k) { print nilai; exit }
    }' "$1"
}

# Ganti satu nilai di tempat tanpa merusak komentar di sekitarnya - komentar
# itu yang dibaca orang pas bingung. Kunci yang belum ada ditambah di akhir.
set_konf() {  # set_konf <berkas> <kunci> <nilai>
  local berkas="$1" kunci="$2" nilai="$3" tmp
  tmp=$(mktemp) || return 1
  awk -v k="$kunci" -v v="$nilai" '
    BEGIN { sudah = 0 }
    {
      salinan = $0
      sub(/^[[:space:]]+/, "", salinan)
      if (salinan ~ /^#/ || salinan == "") { print; next }
      p = index(salinan, "=")
      if (p == 0) { print; next }
      nama = substr(salinan, 1, p - 1)
      sub(/[[:space:]]+$/, "", nama)
      if (nama == k) { print k "=\"" v "\""; sudah = 1; next }
      print
    }
    END { if (!sudah) print k "=\"" v "\"" }
  ' "$berkas" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Disalin isinya, bukan dipindah berkasnya - biar pemilik dan izin berkas
  # aslinya tidak ikut berganti.
  cat "$tmp" > "$berkas"
  rm -f "$tmp"
}

# Baca dari /dev/tty, bukan stdin. Kalau dari stdin, pemasangan yang
# masukannya dialihkan bakal menelan jawabannya sendiri tanpa pernah nanya.
tanya() {  # tanya <label> <nama-variabel> [rahasia]
  local label="$1" __wadah="$2" mode="${3-}" jawab=""
  if [ "$mode" = "rahasia" ]; then
    read -r -s -p "    $label: " jawab < /dev/tty; printf '\n'
  else
    read -r -p "    $label: " jawab < /dev/tty
  fi
  printf -v "$__wadah" '%s' "$jawab"
}

# ------------------------------------------------------------ pemeriksaan
periksa_lingkungan() {
  langkah "Memeriksa lingkungan"
  [ "$(id -u)" -eq 0 ] || mati "jalankan dengan sudo"

  local os="tidak dikenal"
  [ -r /etc/os-release ] && os=$(. /etc/os-release; printf '%s %s' "$NAME" "$VERSION_ID")
  case "$os" in
    Ubuntu\ 24.04*) ok "sistem operasi: $os" ;;
    Ubuntu*|Debian*) lewat "sistem operasi: $os - diuji di Ubuntu 24.04, lanjut dengan hati-hati" ;;
    *) mati "sistem operasi $os belum didukung. Yoru diuji di Ubuntu 24.04." ;;
  esac

  local kurang=()
  for p in sshd systemctl sudo visudo install stat; do
    command -v "$p" >/dev/null 2>&1 || kurang+=("$p")
  done
  [ ${#kurang[@]} -eq 0 ] || mati "perintah yang dibutuhkan tidak ada: ${kurang[*]}"
  ok "semua perintah yang dibutuhkan tersedia"

  for b in bin/yoructl bin/yoru.sudoers bin/yoru-watch \
           systemd/yoru-watch.service systemd/yoru-watch.timer \
           examples/yoru.conf.example; do
    [ -f "$ASAL/$b" ] || mati "berkas $b tidak ada - jalankan skrip ini dari dalam folder repo"
  done
  [ -d "$ASAL/catalog" ] || mati "folder katalog tidak ada - jalankan skrip ini dari dalam folder repo"
  ok "berkas sumber lengkap"
}

tentukan_pemilik() {
  langkah "Menentukan pemilik server"
  [ -n "$PEMILIK" ] || PEMILIK="${SUDO_USER:-}"
  [ -n "$PEMILIK" ] || mati "tidak bisa menebak pemilik server - pakai: --pemilik <nama-user>"
  getent passwd "$PEMILIK" >/dev/null || mati "pengguna '$PEMILIK' tidak ada di server ini"
  [ "$PEMILIK" != "root" ] || mati "pemilik tidak boleh root - Yoru butuh akun manusia biasa"
  ok "pemilik server: $PEMILIK"

  local rumah; rumah=$(getent passwd "$PEMILIK" | cut -d: -f6)
  if [ -s "$rumah/.ssh/authorized_keys" ]
    then ok "kunci SSH $PEMILIK ditemukan"
    else lewat "kunci SSH $PEMILIK belum ada - K02 akan menolak berjalan sampai kunci terpasang"
  fi
}

# --------------------------------------------------------------- pasang
buat_pengguna() {
  langkah "Menyiapkan pengguna agent"
  if id "$AGEN" >/dev/null 2>&1; then
    lewat "pengguna $AGEN sudah ada"
  else
    useradd --system --shell /usr/sbin/nologin --no-create-home "$AGEN" \
      || mati "gagal membuat pengguna $AGEN"
    ok "pengguna $AGEN dibuat"
  fi
  # Tidak boleh masuk grup sudo. Kalau masuk, dia mewarisi izin penuh grup itu
  # dan pembatasan di sudoers jadi tidak ada artinya.
  #
  # Tanpa pipa, sengaja. Versi lama pakai "id -nG | tr | grep -qx sudo", dan
  # di bawah pipefail itu berbahaya: kalau grep ketemu lalu menutup pipa, tr
  # mati kena SIGPIPE dan seluruh pipa terbaca gagal - artinya pemeriksaan
  # ini akan LOLOS justru saat agent memang ada di grup sudo.
  local grup=" $(id -nG "$AGEN" 2>/dev/null) "
  case "$grup" in
    *" sudo "*) mati "$AGEN ada di grup sudo - itu membatalkan seluruh pembatasan. Keluarkan dulu: gpasswd -d $AGEN sudo" ;;
  esac
  ok "$AGEN bukan anggota grup sudo"
}

buat_folder() {
  langkah "Menyiapkan folder"
  install -d -o root -g root -m 755 "$DIR_BIN" "$DIR_CATALOG" "$DIR_ETC" "$DIR_LOG" \
    || mati "gagal membuat folder"
  ok "$DIR_BIN"
  ok "$DIR_CATALOG"
  ok "$DIR_ETC"
  ok "$DIR_LOG (root:root - agent tidak bisa menulis, ini jejak audit)"

  # Tempat laporan, sesuai contract/report.md. Satu-satunya folder yang boleh
  # ditulis agent - laporan memang keluarannya sendiri. $DIR_LOG tetap milik
  # root: alat keamanan tidak boleh bisa menyunting jejaknya sendiri.
  install -d -o "$AGEN" -g "$AGEN" -m 750 "$DIR_DATA" "$DIR_DATA/riwayat" \
    || mati "gagal membuat $DIR_DATA"
  ok "$DIR_DATA dan $DIR_DATA/riwayat ($AGEN:$AGEN 750)"
}

pasang_dispatcher() {
  langkah "Memasang dispatcher"
  install -o root -g root -m 755 "$ASAL/bin/yoructl" "$DIR_BIN/yoructl" \
    || mati "gagal menyalin dispatcher"
  ok "$DIR_BIN/yoructl (root:root 755)"

  printf '%s\n' "$PEMILIK" > "$DIR_ETC/pemilik"
  chown root:root "$DIR_ETC/pemilik"; chmod 644 "$DIR_ETC/pemilik"
  ok "$DIR_ETC/pemilik berisi '$PEMILIK'"
}

pasang_catalog() {
  langkah "Memasang katalog"
  local n=0
  for f in "$ASAL"/catalog/*.yaml; do
    [ -f "$f" ] || continue
    install -o root -g root -m 644 "$f" "$DIR_CATALOG/" || mati "gagal menyalin $(basename "$f")"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || mati "tidak ada berkas katalog yang tersalin"
  # Milik root. Agent baca katalog buat menimbang - katalog yang bisa dia ubah
  # sendiri sama saja membiarkan dia menulis ulang aturannya sendiri.
  ok "$n berkas katalog terpasang, hanya bisa dibaca agent"
}

pasang_sudoers() {
  langkah "Memasang aturan sudoers"
  local sementara=/tmp/yoru-sudoers.$$
  cp "$ASAL/bin/yoru.sudoers" "$sementara" || mati "gagal menyiapkan berkas sudoers"
  # Diperiksa sebelum dipasang. Sudoers yang rusak bisa mematikan sudo buat
  # semua orang, dan benerinnya butuh recovery mode.
  if ! visudo -c -f "$sementara" >/dev/null 2>&1; then
    rm -f "$sementara"; mati "berkas sudoers tidak lolos pemeriksaan - tidak ada yang dipasang"
  fi
  ok "berkas sudoers lolos pemeriksaan visudo"
  install -o root -g root -m 0440 "$sementara" "$SUDOERS" || { rm -f "$sementara"; mati "gagal memasang sudoers"; }
  rm -f "$sementara"
  sudo -n -l >/dev/null 2>&1 || true
  visudo -c >/dev/null 2>&1 || mati "sudoers keseluruhan jadi tidak valid - hapus $SUDOERS sekarang juga"
  ok "$SUDOERS terpasang (root:root 0440)"
}

tulis_konfigurasi() {
  langkah "Menyiapkan konfigurasi"

  # Jalanin ulang installer itu wajar. Kehilangan kunci API gara-gara itu
  # tidak. Berkas yang sudah ada tidak pernah ditimpa.
  if [ -f "$KONF" ]; then
    chown root:"$AGEN" "$KONF"; chmod 640 "$KONF"
    lewat "$KONF sudah ada - tidak ditimpa, isinya dibiarkan"
    ok "izin dipastikan (root:$AGEN 640)"
    return 0
  fi

  install -o root -g "$AGEN" -m 640 "$ASAL/examples/yoru.conf.example" "$KONF" \
    || mati "gagal membuat $KONF"
  ok "$KONF dibuat (root:$AGEN 640 - agent boleh baca, pengguna lain tidak)"

  if [ "$TANYA" != "ya" ] || [ ! -r /dev/tty ]; then
    lewat "tanpa tanya jawab - isi $KONF sendiri sebelum Yoru dipakai"
    return 0
  fi

  printf '\n    Empat pertanyaan. Semuanya boleh dikosongkan sekarang dan diisi\n'
  printf '    belakangan dengan menyunting %s\n\n' "$KONF"

  local api model token url
  tanya "Kunci API model AI (ketikannya tidak ditampilkan)" api rahasia
  tanya "Nama model                                       " model
  tanya "Token bot Telegram (kosongkan kalau tidak pakai) " token rahasia
  tanya "Alamat dashboard   (kosongkan kalau belum ada)   " url

  [ -n "$api"   ] && set_konf "$KONF" AI_API_KEY     "$api"
  [ -n "$model" ] && set_konf "$KONF" AI_MODEL       "$model"
  [ -n "$token" ] && set_konf "$KONF" TELEGRAM_TOKEN "$token"
  [ -n "$url"   ] && set_konf "$KONF" DASHBOARD_URL  "$url"

  chown root:"$AGEN" "$KONF"; chmod 640 "$KONF"
  printf '\n'

  if [ -n "$api" ]; then ok "kunci API tersimpan"
  else lewat "kunci API kosong - agent belum bisa menimbang apa pun"; fi
  if [ -n "$token" ]; then ok "bot Telegram disetel"
  else lewat "Telegram tidak dipakai"; fi
  if [ -n "$url" ]; then ok "dashboard: $url"
  else lewat "dashboard tidak dipakai - laporan hanya ditulis ke $DIR_DATA"; fi
}

pasang_penjagaan() {
  langkah "Memasang siklus penjagaan harian"

  install -o root -g root -m 755 "$ASAL/bin/yoru-watch" "$DIR_BIN/yoru-watch" \
    || mati "gagal menyalin yoru-watch"
  ok "$DIR_BIN/yoru-watch (root:root 755)"

  local jam zona
  jam="$(ambil_konf "$KONF" JAM_PENJAGAAN)"
  zona="$(ambil_konf "$KONF" ZONA_WAKTU)"
  [ -n "$jam" ]  || jam="03:17"
  [ -n "$zona" ] || zona="$(timedatectl show -p Timezone --value 2>/dev/null)"
  [ -n "$zona" ] || zona="UTC"

  # Diperiksa di sini, bukan dibiarkan systemd mengeluh nanti. Timer yang
  # gagal dimuat tidak teriak - dia cuma tidak pernah jalan.
  case "$jam" in
    [0-2][0-9]:[0-5][0-9]) : ;;
    *) mati "JAM_PENJAGAAN di $KONF harus berbentuk HH:MM, isinya sekarang '$jam'" ;;
  esac

  install -o root -g root -m 644 "$ASAL/systemd/yoru-watch.service" \
    "$DIR_SYSTEMD/yoru-watch.service" || mati "gagal memasang unit service"

  sed -e "s|@JAM@|$jam|" -e "s|@ZONA@|$zona|" \
      "$ASAL/systemd/yoru-watch.timer" > "$DIR_SYSTEMD/yoru-watch.timer" \
    || mati "gagal memasang unit timer"
  chown root:root "$DIR_SYSTEMD/yoru-watch.timer"
  chmod 644 "$DIR_SYSTEMD/yoru-watch.timer"

  # Diuji sebelum timer dinyalakan. Salah ketik satu huruf di "Asia/Jakarta"
  # bikin timer ditolak, dan penjagaan tidak pernah jalan.
  if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze calendar "*-*-* $jam:00 $zona" >/dev/null 2>&1 \
      || mati "jadwal '*-*-* $jam:00 $zona' ditolak systemd - periksa ZONA_WAKTU di $KONF"
    ok "jadwal diterima systemd: setiap hari $jam $zona"
  else
    lewat "systemd-analyze tidak ada - jadwal '$jam $zona' dipasang tanpa diperiksa dulu"
  fi

  systemctl daemon-reload || mati "systemctl daemon-reload gagal"
  systemctl enable --now yoru-watch.timer >/dev/null 2>&1 \
    || mati "gagal menyalakan timer penjagaan"

  systemctl is-active yoru-watch.timer >/dev/null 2>&1 \
    || mati "timer terpasang tapi tidak aktif - periksa: systemctl status yoru-watch.timer"
  ok "timer aktif"
}

# ----------------------------------------------------------------- uji
uji_sendiri() {
  langkah "Menguji hasil pemasangan"
  local keluaran

  keluaran=$(sudo -u "$AGEN" sudo -n "$DIR_BIN/yoructl" K01 periksa 2>&1)
  case "$keluaran" in
    *'"id":"K01"'*) ok "agent bisa meminta tindakan yang sah" ;;
    *) mati "agent tidak bisa memanggil dispatcher. Keluaran: $keluaran" ;;
  esac

  if sudo -u "$AGEN" sudo -n id >/dev/null 2>&1
    then mati "BAHAYA: agent bisa menjalankan perintah lain. Pembatasan sudoers tidak bekerja."
    else ok "agent ditolak saat mencoba perintah lain"
  fi

  chmod 777 "$DIR_BIN/yoructl"
  keluaran=$(sudo -u "$AGEN" sudo -n "$DIR_BIN/yoructl" K01 periksa 2>&1)
  chmod 755 "$DIR_BIN/yoructl"
  case "$keluaran" in
    *DITOLAK*) ok "dispatcher menolak jalan saat dirinya sendiri bisa ditulis" ;;
    *) mati "dispatcher tetap jalan padahal izinnya longgar - pemeriksaan diri tidak bekerja" ;;
  esac

  keluaran=$(sudo -u "$AGEN" sudo -n "$DIR_BIN/yoructl" K01 periksa 2>&1)
  case "$keluaran" in
    *'"id":"K01"'*) ok "dispatcher kembali normal setelah izin dipulihkan" ;;
    *) mati "dispatcher tidak pulih setelah chmod 755" ;;
  esac

  # yoru-watch harus menolak jalan sebagai root. Kalau mau, pembatasan
  # sudoers jadi hiasan - tinggal lewat jalur itu dan langsung punya hak penuh.
  keluaran=$("$DIR_BIN/yoru-watch" 2>&1)
  case "$keluaran" in
    *"harus berjalan sebagai yoru-agent"*) ok "penjagaan menolak berjalan sebagai root" ;;
    *) mati "penjagaan tidak menolak saat dijalankan root. Keluaran: $keluaran" ;;
  esac

  local daftar; daftar=$(systemctl list-timers --all --no-pager 2>/dev/null)
  case "$daftar" in
    *yoru-watch*) ok "timer penjagaan terdaftar di systemd" ;;
    *) mati "timer tidak muncul di daftar systemd" ;;
  esac
}

# ---------------------------------------------------------------- copot
copot() {
  langkah "Mencopot Yoru"

  systemctl disable --now yoru-watch.timer >/dev/null 2>&1
  rm -f "$DIR_SYSTEMD/yoru-watch.timer" "$DIR_SYSTEMD/yoru-watch.service"
  systemctl daemon-reload >/dev/null 2>&1
  ok "timer dan unit penjagaan dihapus"

  rm -f "$SUDOERS"          && ok "aturan sudoers dihapus"
  rm -rf /opt/yoru          && ok "/opt/yoru dihapus"
  rm -rf /usr/share/yoru    && ok "/usr/share/yoru dihapus"
  if id "$AGEN" >/dev/null 2>&1; then userdel "$AGEN" 2>/dev/null && ok "pengguna $AGEN dihapus"; fi
  lewat "$DIR_LOG, $DIR_ETC dan $DIR_DATA sengaja DIBIARKAN - itu catatan tindakan dan laporan, jejak tidak dihapus otomatis"

  # Menghapus berkas orang tanpa diminta bukan hak kami. Tapi diam soal kunci
  # API yang tergeletak di server yang mau dilepas juga tidak benar.
  if [ -f "$KONF" ]; then
    printf '\n    %sPERHATIAN%s  %s masih ada, dan di dalamnya ada kunci API\n' "$KUNING" "$H" "$KONF"
    printf '              serta token bot. Sengaja tidak dihapus - itu berkas Anda.\n'
    printf '              Kalau server ini mau dilepas, dijual, atau dikembalikan ke\n'
    printf '              penyedia, hapus sendiri:  sudo rm %s\n' "$KONF"
  fi

  printf '\n    Kontrol yang sudah diterapkan TIDAK dikembalikan.\n'
  printf '    Untuk mengembalikan, jalankan "kembalikan" per kontrol sebelum mencopot.\n\n'
  exit 0
}

# ---------------------------------------------------------------- jalan
PEMILIK=""
TANYA="ya"
while [ $# -gt 0 ]; do
  case "$1" in
    --pemilik)     PEMILIK="${2-}"; shift 2 ;;
    --tanpa-tanya) TANYA="tidak"; shift ;;
    --copot)       [ "$(id -u)" -eq 0 ] || mati "jalankan dengan sudo"; copot ;;
    -h|--help)     sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) mati "argumen tidak dikenal: $1" ;;
  esac
done

printf '\n%sYoru %s%s  -  pemasangan\n' "$TEBAL" "$VERSI" "$H"

periksa_lingkungan
tentukan_pemilik
buat_pengguna
buat_folder
pasang_dispatcher
pasang_catalog
pasang_sudoers
tulis_konfigurasi
pasang_penjagaan
uji_sendiri

JAM_TERPASANG="$(ambil_konf "$KONF" JAM_PENJAGAAN)"; [ -n "$JAM_TERPASANG" ] || JAM_TERPASANG="03:17"
ZONA_TERPASANG="$(ambil_konf "$KONF" ZONA_WAKTU)";   [ -n "$ZONA_TERPASANG" ] || ZONA_TERPASANG="UTC"
PUNYA_KUNCI="$(ambil_konf "$KONF" AI_API_KEY)"

cat <<SELESAI

${TEBAL}Selesai.${H}

  Dispatcher   $DIR_BIN/yoructl
  Katalog      $DIR_CATALOG
  Konfigurasi  $KONF   (root:$AGEN 640)
  Pemilik      $PEMILIK
  Penjagaan    setiap hari $JAM_TERPASANG $ZONA_TERPASANG
  Catatan      $DIR_LOG/tindakan.log   (root, agent tidak bisa menulis)
  Laporan      $DIR_DATA/laporan-terakhir.json   (ditulis agent)

  Coba sendiri:
    sudo -u $AGEN sudo -n $DIR_BIN/yoructl K05 periksa

  Lihat jadwal berikutnya:
    systemctl list-timers yoru-watch.timer

  Mencopot:
    sudo bash install.sh --copot

SELESAI

if [ -z "$PUNYA_KUNCI" ]; then
  printf '  %sBelum selesai betul.%s AI_API_KEY di %s masih kosong.\n' "$KUNING" "$H" "$KONF"
  printf '  Dispatcher dan katalog sudah siap, tapi belum ada yang memakainya:\n'
  printf '  siklus penjagaan akan berhenti tiap hari sampai kuncinya diisi.\n\n'
fi
