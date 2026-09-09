#!/bin/bash
# demo.sh - nyalakan dashboard Yoru dengan data contoh.
#
# Ini cuma pembungkus tipis untuk web/demo.py. Isinya sengaja satu tempat saja:
# dua implementasi demo yang harus dijaga bersamaan pasti berbeda perilaku
# suatu hari, dan yang menemukan bedanya biasanya orang yang sedang presentasi.
#
#   bash demo.sh            nyalakan di http://127.0.0.1:8000
#   bash demo.sh 9000       ganti port
#   bash demo.sh --bersih   hapus database demo, mulai dari nol
#   bash demo.sh --luar     biar bisa dibuka dari komputer lain
#
# Di Windows tidak ada bash. Pakai ini, sama saja:
#   cd web
#   python -m pip install fastapi uvicorn
#   python demo.py

cd "$(dirname "$0")/web" || exit 1
exec python3 demo.py "$@"
