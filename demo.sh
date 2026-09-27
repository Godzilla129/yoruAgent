#!/bin/bash
# demo.sh - start the dashboard with sample data.
#
# A thin wrapper around web/demo.py. The logic lives in exactly one place on
# purpose: two demo implementations kept in parallel will behave differently
# one day, and the person who finds the difference is usually mid-presentation.
#
#   bash demo.sh            start at http://127.0.0.1:8000
#   bash demo.sh 9000       another port
#   bash demo.sh --bersih   wipe the demo database first
#   bash demo.sh --luar     reachable from other computers too
#
# Windows has no bash. This does the same thing:
#   cd web
#   python -m pip install fastapi uvicorn
#   python demo.py

cd "$(dirname "$0")/web" || exit 1
exec python3 demo.py "$@"
