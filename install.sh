#!/bin/bash
# install.sh - pemasang Yoru
#
# Pakai:
#   sudo bash install.sh                 pasang
#   sudo bash install.sh --pemilik budi  pasang, tentukan pemilik server
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
 
VERSI="0.1.0"
AGEN=yoru-agent
DIR_BIN=/opt/yoru/bin
DIR_CATALOG=/usr/share/yoru/catalog
DIR_ETC=/etc/yoru
DIR_LOG=/var/log/yoru
SUDOERS=/etc/sudoers.d/yoru
ASAL="$(dirname "$(readlink -f "$0")")"
 
H=$'\033[0m'; HIJAU=$'\033[32m'; MERAH=$'\033[31m'; KUNING=$'\033[33m'; TEBAL=$'\033[1m'
langkah() { printf '\n%s==> %s%s\n' "$TEBAL" "$1" "$H"; }
ok()      { printf '    %sok%s   %s\n' "$HIJAU" "$H" "$1"; }
lewat()   { printf '    %s--%s   %s\n' "$KUNING" "$H" "$1"; }
mati()    { printf '\n    %sberhenti%s  %s\n\n' "$MERAH" "$H" "$1"; exit 1; }
 
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
 
  for b in bin/yoructl bin/yoru.sudoers; do
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
  # Pengguna ini TIDAK BOLEH masuk grup sudo. Kalau masuk, dia mewarisi izin
  # penuh grup itu dan pembatasan di berkas sudoers jadi tidak ada artinya.
  if id -nG "$AGEN" | tr ' ' '\n' | grep -qx sudo; then
    mati "$AGEN ada di grup sudo - itu membatalkan seluruh pembatasan. Keluarkan dulu: gpasswd -d $AGEN sudo"
  fi
  ok "$AGEN bukan anggota grup sudo"
}
 
buat_folder() {
  langkah "Menyiapkan folder"
  install -d -o root -g root -m 755 "$DIR_BIN" "$DIR_CATALOG" "$DIR_ETC" "$DIR_LOG" \
    || mati "gagal membuat folder"
  ok "$DIR_BIN"
  ok "$DIR_CATALOG"
  ok "$DIR_ETC"
  ok "$DIR_LOG"
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
  # Milik root dan tidak bisa ditulis agent. Agent membaca katalog untuk
  # menimbang, jadi katalog yang bisa dia ubah sendiri sama saja dengan
  # membiarkan dia menulis ulang aturannya sendiri.
  ok "$n berkas katalog terpasang, hanya bisa dibaca agent"
}
 
pasang_sudoers() {
  langkah "Memasang aturan sudoers"
  local sementara=/tmp/yoru-sudoers.$$
  cp "$ASAL/bin/yoru.sudoers" "$sementara" || mati "gagal menyiapkan berkas sudoers"
  # Diperiksa SEBELUM dipasang. Berkas sudoers yang rusak bisa mematikan sudo
  # untuk semua orang di server ini, dan memperbaikinya butuh recovery mode.
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
}
 
# ---------------------------------------------------------------- copot
copot() {
  langkah "Mencopot Yoru"
  rm -f "$SUDOERS"          && ok "aturan sudoers dihapus"
  rm -rf /opt/yoru          && ok "/opt/yoru dihapus"
  rm -rf /usr/share/yoru    && ok "/usr/share/yoru dihapus"
  if id "$AGEN" >/dev/null 2>&1; then userdel "$AGEN" 2>/dev/null && ok "pengguna $AGEN dihapus"; fi
  lewat "$DIR_LOG dan $DIR_ETC sengaja DIBIARKAN - itu catatan tindakan, jejak audit tidak dihapus otomatis"
  printf '\n    Kontrol yang sudah diterapkan TIDAK dikembalikan.\n'
  printf '    Untuk mengembalikan, jalankan "kembalikan" per kontrol sebelum mencopot.\n\n'
  exit 0
}
 
# ---------------------------------------------------------------- jalan
PEMILIK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --pemilik) PEMILIK="${2-}"; shift 2 ;;
    --copot)   [ "$(id -u)" -eq 0 ] || mati "jalankan dengan sudo"; copot ;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \?//'; exit 0 ;;
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
uji_sendiri
 
cat <<SELESAI
 
${TEBAL}Selesai.${H}
 
  Dispatcher   $DIR_BIN/yoructl
  Katalog      $DIR_CATALOG
  Pemilik      $PEMILIK
  Catatan      $DIR_LOG/tindakan.log
 
  Coba sendiri:
    sudo -u $AGEN sudo -n $DIR_BIN/yoructl K05 periksa
 
  Mencopot:
    sudo bash install.sh --copot
 
SELESAI