#!/bin/bash
# demo.sh - nyalakan dashboard Yoru dengan data contoh, tanpa menyentuh server.
#
# Gunanya buat latihan presentasi dan buat Lane 2 mengerjakan tampilan tanpa
# menunggu server siap. Semua datanya dari examples/ - tidak ada satu pun
# perintah yang menyentuh konfigurasi mesin ini.
#
#   bash demo.sh          nyalakan di http://127.0.0.1:8000
#   bash demo.sh 9000     ganti port
#   bash demo.sh --bersih hapus database demo lalu nyalakan dari nol

set -uo pipefail
cd "$(dirname "$0")"

PORT=8000
BERSIH=0
for a in "$@"; do
  case "$a" in
    --bersih) BERSIH=1 ;;
    [0-9]*)   PORT="$a" ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "argumen tidak dikenal: $a"; exit 1 ;;
  esac
done

H='\033[0m'; HIJAU='\033[32m'; KUNING='\033[33m'; TEBAL='\033[1m'
ok()    { printf "  ${HIJAU}ok${H}   %s\n" "$1"; }
lewat() { printf "  ${KUNING}--${H}   %s\n" "$1"; }
mati()  { printf "\n  GAGAL: %s\n\n" "$1"; exit 1; }

printf "\n${TEBAL}Yoru - demo dashboard${H}\n\n"

command -v python3 >/dev/null || mati "python3 tidak ada"
python3 -c 'import fastapi, uvicorn' 2>/dev/null || {
  lewat "fastapi/uvicorn belum ada, memasang..."
  pip install --quiet fastapi uvicorn 2>/dev/null \
    || pip install --quiet --break-system-packages fastapi uvicorn 2>/dev/null \
    || mati "gagal memasang fastapi. Coba: pip install fastapi uvicorn"
}
ok "fastapi dan uvicorn siap"

[ "$BERSIH" = "1" ] && { rm -f web/yoru.db web/yoru.db-wal web/yoru.db-shm; ok "database demo dihapus"; }

# Port yang sudah dipakai lebih baik ketahuan sekarang daripada saat presentasi.
if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then
  exec 3>&- 2>/dev/null
  mati "port $PORT sudah dipakai proses lain. Pakai port lain: bash demo.sh 9000"
fi

( cd web && exec python3 -m uvicorn api:app --host 127.0.0.1 --port "$PORT" ) \
  >/tmp/yoru-demo.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null' EXIT

for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PORT/sehat" >/dev/null 2>&1 && break
  kill -0 $PID 2>/dev/null || { cat /tmp/yoru-demo.log; mati "server berhenti saat dinyalakan"; }
  sleep 0.25
done
curl -sf "http://127.0.0.1:$PORT/sehat" >/dev/null || { cat /tmp/yoru-demo.log; mati "server tidak menjawab"; }
ok "server jalan di port $PORT"

kirim() {
  curl -sf -o /dev/null -X POST "http://127.0.0.1:$PORT/api/laporan" \
    -H 'Content-Type: application/json' --data-binary "@$1" \
    && ok "$2" || lewat "gagal mengirim $1"
}

# Urutannya sengaja: perbaikan dulu (server sakit, skor 10), lalu penjagaan
# (server sehat, ada satu perubahan mencurigakan). Itu cerita demonya - dari
# server yang baru disewa sampai server yang sudah dijaga tiap hari.
kirim examples/report-fix.json   "laporan siklus perbaikan dimuat (server sakit)"
kirim examples/report-watch.json "laporan siklus penjagaan dimuat (ada drift)"

cat <<SELESAI

  ${TEBAL}Buka:${H}  http://127.0.0.1:$PORT

  Yang bisa dicoba:
    - lihat skor dan sepuluh kontrol
    - mencet "Setuju, amankan" - jawabannya tersimpan, bukan langsung jalan
    - bagian "Ada yang berubah di server kamu" - itu Siklus Penjagaan

  Data ini dari examples/, tidak ada server yang disentuh.
  Log server: /tmp/yoru-demo.log

  Tekan Ctrl-C untuk berhenti.

SELESAI

wait $PID
