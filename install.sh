#!/bin/bash
# install.sh - pemasang Yoru
#
# Pakai:
#   sudo bash install.sh                     pasang semuanya
#   sudo bash install.sh --pemilik budi      pasang, tentukan pemilik server
#   sudo bash install.sh --tanpa-tanya       pasang tanpa tanya jawab
#   sudo bash install.sh --tanpa-dashboard   pasang tanpa dashboard web
#   sudo bash install.sh --host 0.0.0.0      dashboard bisa dibuka dari luar
#   sudo bash install.sh --port 8080         ganti port dashboard
#   sudo bash install.sh --copot             copot
#
# Sekali jalan, semuanya terpasang: dispatcher, katalog, agent, siklus
# penjagaan harian, dan dashboard.
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
DIR_ASAL=/var/backups/yoru
DIR_WEB=/opt/yoru/web
KONF="$DIR_ETC/yoru.conf"
KONF_WEB="$DIR_ETC/web.env"
SUDOERS=/etc/sudoers.d/yoru
DB_WEB="$DIR_DATA/dashboard.db"

H=$'\033[0m'; HIJAU=$'\033[32m'; MERAH=$'\033[31m'; KUNING=$'\033[33m'; TEBAL=$'\033[1m'
langkah() { printf '\n%s==> %s%s\n' "$TEBAL" "$1" "$H"; }
ok()      { printf '    %sok%s   %s\n' "$HIJAU" "$H" "$1"; }
lewat()   { printf '    %s--%s   %s\n' "$KUNING" "$H" "$1"; }
mati()    { printf '\n    %sberhenti%s  %s\n\n' "$MERAH" "$H" "$1"; exit 1; }

# --------------------------------------------------- baca/tulis konfigurasi
# Sama dengan ambil() di bin/yoru-watch, dan sama-sama tidak pakai "source" -
# nilai yang mengandung $(...) bakal dijalankan kalau di-source.
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
  # flock dipakai yoructl buat mencegah terapkan dan kembalikan jalan
  # bersamaan. Tanpa dia yoructl tetap jalan tapi tanpa kunci, dan itu
  # lebih baik ketahuan sekarang daripada pas dua tindakan tabrakan.
  for p in sshd systemctl sudo visudo install stat flock python3; do
    command -v "$p" >/dev/null 2>&1 || kurang+=("$p")
  done
  [ ${#kurang[@]} -eq 0 ] || mati "perintah yang dibutuhkan tidak ada: ${kurang[*]}"
  ok "semua perintah yang dibutuhkan tersedia"

  # "sshd ada" belum berarti "sshd -T bisa dibaca", dan K01 sampai K05 semuanya
  # bertumpu pada sshd -T. Diperiksa di sini supaya ketahuan sekarang, bukan
  # nanti berupa empat baris ERROR di dashboard tanpa sebab yang kelihatan.
  #
  # /run/sshd sering belum ada di Ubuntu 24.04 yang baru boot: yang membuatnya
  # itu ssh.service, dan ssh.service baru jalan setelah ada yang menyambung
  # lewat ssh.socket. yoructl membuatnya sendiri kalau tidak ada.
  [ -d /run/sshd ] || { mkdir -p /run/sshd 2>/dev/null && chmod 0755 /run/sshd 2>/dev/null; }
  if sshd -T >/dev/null 2>&1; then
    ok "sshd -T bisa dibaca - K01 sampai K05 punya sumber data"
  else
    lewat "sshd -T tidak bisa dibaca: $(sshd -T 2>&1 >/dev/null | head -1)"
    lewat "K01 sampai K05 akan berstatus ERROR sampai ini beres"
  fi

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
  pasang_kunci_ssh "$rumah"
}

# Kunci SSH pemilik.
#
# Installer ini MENERIMA kunci publik, dan sengaja TIDAK MEMBUATKAN kunci
# privat. Kunci privat yang dibuat di server berarti kunci privat yang pernah
# ada di server, dan buat sampai ke laptop pemiliknya dia harus lewat terminal
# atau salinan berkas - persis kebiasaan yang bikin server orang jebol duluan.
# Kunci privat lahir di mesin pemiliknya, tidak di mesin yang dia jaga.
#
# Kunci publik lain ceritanya: dia memang dibuat untuk disebar.
pasang_kunci_ssh() {  # pasang_kunci_ssh <folder-rumah>
  local rumah="$1" berkas="$1/.ssh/authorized_keys"

  if [ -s "$berkas" ]; then
    ok "kunci SSH $PEMILIK ditemukan"
    return 0
  fi

  lewat "kunci SSH $PEMILIK belum ada"
  if [ "$TANYA" != "ya" ] || [ ! -r /dev/tty ]; then
    lewat "K02 akan menolak berjalan sampai kuncinya terpasang"
    return 0
  fi

  cat <<PETUNJUK

    K02 mematikan login pakai password. Tanpa kunci SSH yang bekerja, itu
    sama saja menutup satu-satunya pintu masuk Anda sendiri - jadi K02 akan
    menolak berjalan sampai kuncinya ada.

    Kalau belum punya, buat di KOMPUTER ANDA - bukan di server ini:

        ssh-keygen -t ed25519

    Lalu tampilkan bagian publiknya, dan tempel barisnya di bawah:

        Windows  type %USERPROFILE%\\.ssh\\id_ed25519.pub
        Linux    cat ~/.ssh/id_ed25519.pub
        macOS    cat ~/.ssh/id_ed25519.pub

    Yang ditempel harus yang berakhiran .pub. Isinya satu baris, diawali
    "ssh-ed25519" atau "ssh-rsa". Kami tidak pernah minta kunci privat.

PETUNJUK

  local kunci
  tanya "Tempel kunci publik (kosongkan buat lewati)" kunci
  printf '\n'

  if [ -z "$kunci" ]; then
    lewat "dilewati - K02 akan menolak berjalan sampai kuncinya terpasang"
    return 0
  fi

  # Yang salah tempel kunci privat harus tahu sekarang juga, bukan nanti.
  # Kunci yang sudah lewat layar dan riwayat shell tidak bisa dianggap rahasia
  # lagi, dan diam soal itu jauh lebih berbahaya daripada gagal memasang.
  case "$kunci" in
    *PRIVATE\ KEY*|*BEGIN\ OPENSSH*|*BEGIN\ RSA*)
      printf '    %sBERHENTI%s  itu kunci PRIVAT, bukan publik.\n\n' "$MERAH" "$H"
      printf '              Kunci itu sekarang sudah lewat layar dan riwayat shell,\n'
      printf '              jadi sudah tidak bisa dianggap rahasia. Buat yang baru di\n'
      printf '              komputer Anda, dan tempel yang berakhiran .pub saja.\n\n'
      mati "tidak ada yang ditulis" ;;
  esac

  local tmp; tmp=$(mktemp) || { lewat "gagal menyiapkan berkas sementara"; return 0; }
  printf '%s\n' "$kunci" > "$tmp"

  # Diperiksa pakai ssh-keygen, bukan dicocokkan sendiri pakai pola. Kunci yang
  # kelihatan benar tapi ada satu huruf hilang tetap tertulis rapi ke berkas,
  # dan gagalnya baru ketahuan pas login berikutnya - saat password sudah mati.
  local sidik=""
  if command -v ssh-keygen >/dev/null 2>&1; then
    sidik=$(ssh-keygen -l -f "$tmp" 2>/dev/null) || {
      rm -f "$tmp"
      lewat "itu bukan kunci publik yang sah - tidak ada yang ditulis"
      lewat "pastikan yang ditempel isi berkas .pub, utuh satu baris"
      return 0
    }
  else
    case "$kunci" in
      ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-*\ *) : ;;
      *) rm -f "$tmp"; lewat "itu bukan kunci publik yang sah - tidak ada yang ditulis"; return 0 ;;
    esac
  fi
  rm -f "$tmp"

  local grup; grup=$(id -gn "$PEMILIK")
  install -d -o "$PEMILIK" -g "$grup" -m 700 "$rumah/.ssh" \
    || { lewat "gagal membuat $rumah/.ssh"; return 0; }

  # Ditambah, bukan ditimpa. Berkas ini bisa saja sudah berisi kunci orang lain
  # yang juga butuh masuk - dan menimpanya berarti mengunci mereka di luar.
  printf '%s\n' "$kunci" >> "$berkas" || { lewat "gagal menulis $berkas"; return 0; }
  chown "$PEMILIK":"$grup" "$berkas"; chmod 600 "$berkas"

  ok "kunci ditulis ke $berkas ($PEMILIK:$grup 600)"
  [ -n "$sidik" ] && ok "sidik jari: $sidik"

  local alamat; alamat=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$alamat" ] || alamat="<alamat-server>"

  printf '\n    %sTES DULU SEBELUM LANJUT.%s Buka terminal BARU - jangan tutup yang ini -\n' "$KUNING" "$H"
  printf '    lalu coba masuk pakai kunci itu:\n\n'
  printf '        ssh %s@%s\n\n' "$PEMILIK" "$alamat"
  printf '    Kalau masuk tanpa ditanya password, kuncinya bekerja. Kalau masih\n'
  printf '    ditanya, sesi ini masih hidup untuk membetulkannya.\n\n'

  # Sengaja berhenti di sini. Kalimat di atas akan tergulung hilang oleh sisa
  # pemasangan kalau tidak ada yang menahannya, dan ini kalimat yang paling
  # tidak boleh terlewat di seluruh pemasangan.
  local lanjut
  tanya "Tekan Enter kalau sudah dites" lanjut
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
  install -d -o root -g root -m 755 "$DIR_BIN" "$DIR_CATALOG" "$DIR_ETC" \
    || mati "gagal membuat folder"
  ok "$DIR_BIN"
  ok "$DIR_CATALOG"
  ok "$DIR_ETC"

  # 2750, bukan 755. Angka 2 di depan itu setgid: berkas log yang dibuat root
  # di dalamnya ikut bergrup yoru-agent, jadi dashboard yang jalan sebagai
  # agent bisa MEMBACA jejaknya. Grup tetap tanpa izin tulis dan foldernya
  # milik root, jadi agent tetap tidak bisa menyunting atau menghapus
  # catatannya sendiri - itu bagian yang penting.
  install -d -o root -g "$AGEN" -m 2750 "$DIR_LOG" || mati "gagal membuat $DIR_LOG"
  # Pemasangan lama menulis log sebagai root:root, dan setgid tidak berlaku
  # surut untuk berkas yang sudah ada.
  chgrp "$AGEN" "$DIR_LOG"/*.log 2>/dev/null
  ok "$DIR_LOG (root:$AGEN 2750 - agent boleh baca, tidak boleh menulis)"

  # Tempat laporan, sesuai contract/report.md. Satu-satunya folder yang boleh
  # ditulis agent - laporan memang keluarannya sendiri. $DIR_LOG tetap milik
  # root: alat keamanan tidak boleh bisa menyunting jejaknya sendiri.
  install -d -o "$AGEN" -g "$AGEN" -m 750 "$DIR_DATA" "$DIR_DATA/riwayat" \
    || mati "gagal membuat $DIR_DATA"
  # Isinya ikut dibetulkan pemiliknya. Kalau ada yang pernah menjalankan agent
  # pakai sudo, laporan-terakhir.json jadi milik root - dan sejak itu siklus
  # harian tidak bisa menimpanya lagi, diam-diam, tanpa ada yang tahu.
  chown -R "$AGEN":"$AGEN" "$DIR_DATA" 2>/dev/null
  ok "$DIR_DATA dan $DIR_DATA/riwayat ($AGEN:$AGEN 750)"

  # Rekaman keadaan asal server, sebelum Yoru menyentuh apa pun. Milik root
  # dan 700: agent boleh mengubah server, tapi tidak boleh mengubah catatan
  # tentang bagaimana server itu SEBELUM dia datang.
  install -d -o root -g root -m 700 "$DIR_ASAL" || mati "gagal membuat $DIR_ASAL"
  ok "$DIR_ASAL (root:root 700 - agent tidak bisa menyentuh)"
}

# Versi sebelum 0.1.3 menulis catatan tindakan sebagai teks bebas; sekarang
# JSON per baris. Kalau dua bentuk tercampur di satu berkas, parser dashboard
# patah di baris lama pertama - dan patahnya di layar orang lain, bukan di
# layar yang meng-upgrade. Jadi yang lama dipindah, bukan dihapus.
pindah_log_lama() {
  local f="$DIR_LOG/tindakan.log" tujuan tmp n_teks n_json
  [ -s "$f" ] || return 0

  # Dipilah per baris, bukan dipindah seluruh berkas. Versi pertama fungsi ini
  # memindahkan semuanya - dan ikut membawa baris JSON yang sudah sempat
  # ditulis, sehingga log gabungan jadi lebih pendek daripada log per kontrol.
  # Datanya tidak hilang, tapi dua berkas yang seharusnya sejalan jadi tidak
  # cocok, dan itu ketahuannya belakangan di layar orang lain.
  n_teks=$(grep -cv '^{' "$f" 2>/dev/null) || n_teks=0
  [ "${n_teks:-0}" -gt 0 ] || return 0

  tujuan="$f.teks-lama.$(date +%Y%m%d%H%M%S)"
  tmp=$(mktemp) || return 0

  grep -v '^{' "$f" > "$tujuan" 2>/dev/null
  grep    '^{' "$f" > "$tmp"    2>/dev/null
  n_json=$(wc -l < "$tmp" 2>/dev/null) || n_json=0

  # Isinya disalin, bukan berkasnya dipindah - supaya pemilik dan izin
  # berkas aslinya tidak ikut berganti.
  cat "$tmp" > "$f"
  rm -f "$tmp"
  chmod 640 "$f" "$tujuan" 2>/dev/null

  lewat "$n_teks baris format teks lama dipindah ke $(basename "$tujuan")"
  lewat "$n_json baris JSON tetap di tindakan.log"
}

pasang_dispatcher() {
  langkah "Memasang dispatcher"
  pindah_log_lama
  install -o root -g root -m 755 "$ASAL/bin/yoructl" "$DIR_BIN/yoructl" \
    || mati "gagal menyalin dispatcher"

  # Agent (Lane 3). Dipanggil timer harian lewat yoru-watch.
  if [ -f "$ASAL/bin/yoru-agent" ]; then
    python3 -c 'import yaml' 2>/dev/null || {
      lewat "python3-yaml belum ada, memasang (dipakai agent buat baca katalog)"
      DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=60 \
        install python3-yaml >/dev/null 2>&1 \
        || lewat "gagal memasang python3-yaml - agent tidak akan bisa baca katalog"
    }
    install -o root -g root -m 755 "$ASAL/bin/yoru-agent" "$DIR_BIN/yoru-agent" \
      || mati "gagal menyalin agent"
    ok "$DIR_BIN/yoru-agent (root:root 755)"
  fi
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

  # Kunci API model TIDAK ditanyakan di sini. Yang memanggil model itu Hermes,
  # dan kuncinya sudah ada di konfigurasi Hermes. Menanyakannya lagi berarti
  # menyimpan rahasia yang sama di dua tempat.
  printf '\n    Dua pertanyaan, dua-duanya boleh dikosongkan dan diisi belakangan\n'
  printf '    dengan menyunting %s\n\n' "$KONF"

  local token url
  tanya "Token bot Telegram (kosongkan kalau tidak pakai) " token rahasia
  tanya "Alamat dashboard   (kosongkan kalau belum ada)   " url

  [ -n "$token" ] && set_konf "$KONF" TELEGRAM_TOKEN "$token"
  [ -n "$url"   ] && set_konf "$KONF" DASHBOARD_URL  "$url"

  chown root:"$AGEN" "$KONF"; chmod 640 "$KONF"
  printf '\n'

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

# ------------------------------------------------------------ dashboard
# Dashboard berjalan sebagai yoru-agent, bukan root. Tombolnya memanggil
# yoructl lewat sudo persis seperti agent - lewat satu pintu yang sama, dengan
# batasan yang sama. Tidak ada jalur istimewa buat yang datang dari browser.
pasang_dashboard() {
  langkah "Memasang dashboard"

  if [ "$DASHBOARD" != "ya" ]; then
    lewat "dilewati atas permintaan (--tanpa-dashboard)"
    return 0
  fi
  for b in web/api.py web/dashboard.html systemd/yoru-web.service; do
    [ -f "$ASAL/$b" ] || { lewat "$b tidak ada - dashboard dilewati"; return 0; }
  done

  install -d -o root -g root -m 755 "$DIR_WEB" || mati "gagal membuat $DIR_WEB"
  install -o root -g root -m 644 "$ASAL/web/api.py" "$DIR_WEB/api.py" \
    || mati "gagal menyalin api.py"
  install -o root -g root -m 644 "$ASAL/web/dashboard.html" "$DIR_WEB/dashboard.html" \
    || mati "gagal menyalin dashboard.html"
  ok "$DIR_WEB (root:root - agent menjalankannya, tapi tidak bisa mengubahnya)"

  # venv, bukan pip ke sistem. Dashboard butuh fastapi versi tertentu; menimpa
  # paket python milik sistem demi itu bisa merusak alat lain di server orang.
  if [ ! -x "$DIR_WEB/venv/bin/python" ]; then
    python3 -m venv "$DIR_WEB/venv" >/dev/null 2>&1 || {
      lewat "python3-venv belum ada, memasang"
      DEBIAN_FRONTEND=noninteractive apt-get -y -o DPkg::Lock::Timeout=60 \
        install python3-venv >/dev/null 2>&1
      python3 -m venv "$DIR_WEB/venv" >/dev/null 2>&1
    }
  fi
  if [ ! -x "$DIR_WEB/venv/bin/python" ]; then
    lewat "gagal membuat venv - dashboard tidak dipasang, sisanya tetap jalan"
    return 0
  fi

  if ! "$DIR_WEB/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    printf '    ..   mengunduh fastapi dan uvicorn, ini yang paling lama\n'
    "$DIR_WEB/venv/bin/pip" install --quiet --disable-pip-version-check \
      fastapi uvicorn >/dev/null 2>&1
  fi
  if ! "$DIR_WEB/venv/bin/python" -c 'import fastapi, uvicorn' 2>/dev/null; then
    lewat "fastapi/uvicorn gagal dipasang - periksa koneksi internet server ini"
    lewat "sisanya tetap terpasang. Ulangi installer setelah internet jalan."
    return 0
  fi
  ok "fastapi dan uvicorn siap di $DIR_WEB/venv"

  # Token. Dari 127.0.0.1 tidak diperlukan - yang bisa membuka 127.0.0.1 sudah
  # punya akses ke server itu. Begitu dashboard dibuka ke jaringan, tombolnya
  # jadi tombol yang bisa ditekan siapa saja, jadi tokennya dibuatkan di sini
  # supaya tidak ada yang lupa mengisinya.
  local token; token="$(ambil_konf "$KONF" DASHBOARD_TOKEN)"
  case "$HOST_WEB" in
    127.0.0.1|localhost|::1) : ;;
    *) if [ -z "$token" ]; then
         token="$(python3 -c 'import secrets; print(secrets.token_hex(24))')"
         set_konf "$KONF" DASHBOARD_TOKEN "$token"
         lewat "dashboard dibuka ke $HOST_WEB - token dibuatkan otomatis"
       fi ;;
  esac

  if [ -n "$token" ]; then
    printf 'YORU_TOKEN=%s\n' "$token" > "$KONF_WEB"
    chown root:"$AGEN" "$KONF_WEB"; chmod 640 "$KONF_WEB"
    ok "$KONF_WEB (root:$AGEN 640 - token tidak ikut muncul di 'ps')"
  else
    rm -f "$KONF_WEB"
  fi

  sed -e "s|@HOST@|$HOST_WEB|" -e "s|@PORT@|$PORT_WEB|" \
      "$ASAL/systemd/yoru-web.service" > "$DIR_SYSTEMD/yoru-web.service" \
    || mati "gagal memasang unit dashboard"
  chown root:root "$DIR_SYSTEMD/yoru-web.service"
  chmod 644 "$DIR_SYSTEMD/yoru-web.service"

  systemctl daemon-reload || mati "systemctl daemon-reload gagal"
  systemctl enable yoru-web.service >/dev/null 2>&1
  systemctl restart yoru-web.service >/dev/null 2>&1 \
    || mati "dashboard gagal dinyalakan - lihat: journalctl -u yoru-web -n 30"

  # Ditunggu sampai benar-benar menjawab, bukan cuma sampai systemd bilang
  # "active". Proses yang mati satu detik setelah start tetap terhitung aktif
  # sesaat, dan kegagalannya baru ketahuan pas orang membuka browsernya.
  if python3 - "$PORT_WEB" <<'PY'
import sys, time, urllib.request, urllib.error
alamat = "http://127.0.0.1:%s/sehat" % sys.argv[1]
for _ in range(30):
    try:
        if urllib.request.urlopen(alamat, timeout=2).status == 200:
            sys.exit(0)
    except Exception:
        time.sleep(1)
sys.exit(1)
PY
  then :
  else mati "dashboard tidak menjawab dalam 30 detik - lihat: journalctl -u yoru-web -n 30"
  fi

  # Ada yang menjawab di port itu belum tentu KITA yang menjawab. Kalau port
  # sudah dipakai program lain, unit kita mati sendiri sementara program itu
  # tetap membalas - dan pemasangan akan bilang "berhasil" untuk sesuatu yang
  # sama sekali bukan Yoru.
  systemctl is-active yoru-web.service >/dev/null 2>&1 \
    || mati "port $PORT_WEB sudah dipakai program lain, bukan Yoru. Pilih port lain: --port <angka>"
  ok "dashboard menjawab di http://$HOST_WEB:$PORT_WEB"

  # Agent bicara ke 127.0.0.1 walau dashboardnya dibuka ke jaringan - dia satu
  # mesin dengan dashboardnya, tidak perlu lewat luar.
  local url_lama; url_lama="$(ambil_konf "$KONF" DASHBOARD_URL)"
  if [ -z "$url_lama" ]; then
    set_konf "$KONF" DASHBOARD_URL "http://127.0.0.1:$PORT_WEB"
    ok "agent diarahkan ke http://127.0.0.1:$PORT_WEB"
  elif [ "${url_lama%/}" = "http://127.0.0.1:$PORT_WEB" ]; then
    ok "agent sudah diarahkan ke http://127.0.0.1:$PORT_WEB"
  else
    # Sengaja tidak ditimpa - itu berkas pemiliknya, dan bisa saja memang
    # sengaja diarahkan ke dashboard lain. Tapi diam soal ini berarti
    # dashboard yang baru dipasang tidak akan pernah menerima satu laporan pun.
    lewat "DASHBOARD_URL di $KONF masih '$url_lama', bukan port yang baru dipasang"
    lewat "laporan tidak akan masuk ke dashboard ini sampai barisnya diganti jadi"
    lewat "  DASHBOARD_URL=\"http://127.0.0.1:$PORT_WEB\""
  fi
  chown root:"$AGEN" "$KONF"; chmod 640 "$KONF"
}

hitung_laporan() {
  python3 - "$PORT_WEB" <<'PY' 2>/dev/null || printf '0\n'
import sys, json, urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:%s/api/server" % sys.argv[1], timeout=5) as j:
        print(sum(int(s.get("laporan") or 0) for s in json.load(j).get("server", [])))
except Exception:
    print(0)
PY
}

# Dashboard yang kosong pas pertama dibuka bikin orang mengira pemasangannya
# gagal. Dijalankan dengan --kering: kontrolnya diperiksa dan laporannya
# dikirim, tapi tidak ada satu pun setelan server yang disentuh. Pemasangan
# tidak berhak mengubah server; yang boleh memutuskan itu pemiliknya.
isi_dashboard_pertama() {
  [ "$DASHBOARD" = "ya" ] || return 0
  [ -x "$DIR_BIN/yoru-agent" ] || return 0
  systemctl is-active yoru-web.service >/dev/null 2>&1 || return 0

  langkah "Memeriksa server sekali, biar dashboard tidak kosong"
  printf '    ..   memeriksa 10 kontrol, tidak ada yang diubah\n'

  local sebelum; sebelum="$(hitung_laporan)"
  timeout 300 sudo -u "$AGEN" env HOME="$DIR_DATA" "$DIR_BIN/yoru-agent" \
    --siklus penjagaan --kering --konfigurasi "$KONF" >/dev/null 2>&1

  # Dihitung sebelum dan sesudah, bukan sekadar "ada isinya". Pemasangan ulang
  # selalu menemukan laporan lama di database, dan itu bukan bukti bahwa yang
  # barusan sampai. Kode keluar agent juga bukan bukti: dia memang sengaja
  # tetap keluar 0 walau dashboardnya tidak bisa dihubungi, karena laporan ke
  # disk lebih penting daripada laporan ke layar.
  if [ "$(hitung_laporan)" -gt "$sebelum" ]
    then ok "laporan pertama sudah masuk ke dashboard"
  else lewat "dashboard masih kosong - laporannya belum sampai"
       lewat "jalankan manual dan baca pesannya:"
       lewat "  sudo -u $AGEN $DIR_BIN/yoru-agent --siklus penjagaan --kering"
  fi
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
  systemctl disable --now yoru-web.service >/dev/null 2>&1
  rm -f "$DIR_SYSTEMD/yoru-watch.timer" "$DIR_SYSTEMD/yoru-watch.service" \
        "$DIR_SYSTEMD/yoru-web.service"
  systemctl daemon-reload >/dev/null 2>&1
  ok "timer penjagaan dan dashboard dihentikan, unitnya dihapus"

  rm -f "$KONF_WEB"         && ok "$KONF_WEB dihapus"
  rm -f "$SUDOERS"          && ok "aturan sudoers dihapus"
  rm -rf /opt/yoru          && ok "/opt/yoru dihapus"
  rm -rf /usr/share/yoru    && ok "/usr/share/yoru dihapus"
  if id "$AGEN" >/dev/null 2>&1; then
    if userdel "$AGEN" 2>/dev/null
      then ok "pengguna $AGEN dihapus"
      else lewat "pengguna $AGEN tidak bisa dihapus - biasanya masih ada prosesnya"
           lewat "lihat dulu: pgrep -u $AGEN -a   lalu: sudo userdel $AGEN"
    fi
  fi
  lewat "$DIR_LOG, $DIR_ETC, $DIR_DATA dan $DIR_ASAL sengaja DIBIARKAN - itu catatan, laporan, dan rekaman keadaan asal"

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
DASHBOARD="ya"
HOST_WEB="127.0.0.1"
PORT_WEB="8000"
while [ $# -gt 0 ]; do
  case "$1" in
    --pemilik)         PEMILIK="${2-}"; shift 2 ;;
    --tanpa-tanya)     TANYA="tidak"; shift ;;
    --tanpa-dashboard) DASHBOARD="tidak"; shift ;;
    --host)            HOST_WEB="${2-}"; shift 2 ;;
    --port)            PORT_WEB="${2-}"; shift 2 ;;
    --copot)           [ "$(id -u)" -eq 0 ] || mati "jalankan dengan sudo"; copot ;;
    -h|--help)         sed -n '2,23p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) mati "argumen tidak dikenal: $1" ;;
  esac
done

[ -n "$HOST_WEB" ] || mati "--host tidak boleh kosong"
case "$PORT_WEB" in
  ''|*[!0-9]*) mati "--port harus angka, isinya '$PORT_WEB'" ;;
esac
[ "$PORT_WEB" -ge 1 ] && [ "$PORT_WEB" -le 65535 ] || mati "--port di luar jangkauan: $PORT_WEB"

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
pasang_dashboard
uji_sendiri
isi_dashboard_pertama

JAM_TERPASANG="$(ambil_konf "$KONF" JAM_PENJAGAAN)"; [ -n "$JAM_TERPASANG" ] || JAM_TERPASANG="03:17"
ZONA_TERPASANG="$(ambil_konf "$KONF" ZONA_WAKTU)";   [ -n "$ZONA_TERPASANG" ] || ZONA_TERPASANG="UTC"

if systemctl is-active yoru-web.service >/dev/null 2>&1
  then ALAMAT_WEB="http://$HOST_WEB:$PORT_WEB"
  else ALAMAT_WEB="tidak dipasang"
fi

cat <<SELESAI

${TEBAL}Selesai.${H}

  Dispatcher   $DIR_BIN/yoructl
  Agent        $DIR_BIN/yoru-agent
  Katalog      $DIR_CATALOG
  Konfigurasi  $KONF   (root:$AGEN 640)
  Pemilik      $PEMILIK
  Penjagaan    setiap hari $JAM_TERPASANG $ZONA_TERPASANG
  Dashboard    $ALAMAT_WEB
  Catatan      $DIR_LOG/tindakan.log   (root, agent tidak bisa menulis)
  Laporan      $DIR_DATA/laporan-terakhir.json   (ditulis agent)
  Keadaan asal $DIR_ASAL/<kontrol>/   (direkam sebelum terapkan pertama)

  Coba sendiri:
    sudo -u $AGEN sudo -n $DIR_BIN/yoructl K05 periksa

  Jalankan siklus perbaikan sekarang:
    sudo -u $AGEN $DIR_BIN/yoru-agent --siklus perbaikan

  Lihat jadwal berikutnya:
    systemctl list-timers yoru-watch.timer

  Kalau dashboard bermasalah:
    journalctl -u yoru-web -n 30

  Mencopot:
    sudo bash install.sh --copot

SELESAI

case "$HOST_WEB" in
  127.0.0.1|localhost|::1) : ;;
  *)
    if systemctl is-active yoru-web.service >/dev/null 2>&1; then
      TOKEN_TERPASANG="$(ambil_konf "$KONF" DASHBOARD_TOKEN)"
      printf '  %sDashboard terbuka ke jaringan.%s\n' "$KUNING" "$H"
      printf '  Token untuk menekan tombolnya dari komputer lain:\n\n'
      printf '      %s\n\n' "${TOKEN_TERPASANG:-(kosong - isi DASHBOARD_TOKEN di $KONF)}"
      printf '  Dan port %s belum ada di PORT_DIIZINKAN. K05 memang tidak akan\n' "$PORT_WEB"
      printf '  menyalakan firewall selama masih ada port terbuka yang belum dijawab -\n'
      printf '  tambahkan sendiri kalau port ini memang mau dibiarkan terbuka:\n\n'
      printf '      PORT_DIIZINKAN="%s"   di %s\n\n' "$PORT_WEB" "$KONF"
    fi ;;
esac

if [ ! -x "$DIR_BIN/yoru-agent" ]; then
  printf '  %sBelum selesai betul.%s Agent Hermes belum terpasang di %s/yoru-agent.\n' "$KUNING" "$H" "$DIR_BIN"
  printf '  Dispatcher, katalog, dan timer sudah siap, tapi belum ada yang memakainya:\n'
  printf '  siklus penjagaan akan berhenti tiap hari sampai agentnya ada.\n\n'
fi
