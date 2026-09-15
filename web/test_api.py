#!/usr/bin/env python3
"""
Who is allowed to reach which endpoint - checked, not assumed.

    python3 test_api.py

Needs only fastapi, the same dependency the dashboard already has. No pytest,
no httpx, no network: the app is driven directly as an ASGI callable, with the
scope built by hand.

That last part is the whole reason this file exists. The rule being tested is
"free from 127.0.0.1, token required from anywhere else", and a test client
that picks its own client address cannot express the difference. Here the
caller's IP is just a field we set, so both sides of the rule are reproducible.

What it is guarding against, concretely: this suite was written after six
endpoints turned out to be readable by anyone who could reach the port - the
report naming every control that FAILS on a server, and the root-owned action
log - and it immediately caught a seventh being re-opened by a later edit that
rewrote the function and dropped its guard line. That is exactly the kind of
mistake no amount of care prevents and one run catches.

Add every new endpoint to READ or WRITE below. An endpoint that belongs in
neither - one deliberately left open - goes in OPEN, so that "this is public"
stays a decision somebody wrote down rather than something nobody noticed.
"""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Pointed at throwaway files before api is imported: the module reads all of
# these at import time, and a test must never touch a real installation.
os.environ["YORU_DB"] = str(Path(tempfile.mkdtemp()) / "uji.db")
os.environ["YORU_KONF"] = str(Path(tempfile.mkdtemp()) / "yoru.conf")
os.environ["YORU_LOG"] = tempfile.mkdtemp()
TOKEN = os.environ["YORU_TOKEN"] = sys.argv[1] if len(sys.argv) > 1 else ""

sys.path.insert(0, str(HERE))
import api  # noqa: E402

LOCAL, REMOTE = "127.0.0.1", "203.0.113.9"

# Everything that hands out data about a guarded server.
READ = [("GET", "/api/laporan", None),
        ("GET", "/api/server", None),
        ("GET", "/api/riwayat", None),
        ("GET", "/api/log", None),
        ("GET", "/api/keputusan?server=uji", None),
        ("GET", "/api/konfigurasi", None)]

# Everything that changes something, on a server or in the decision queue.
WRITE = [("POST", "/api/keputusan", {"server": "uji", "kontrol": "K01", "nilai": "setuju"}),
         ("POST", "/api/port", {"server": "uji", "port": [8080]}),
         ("POST", "/api/konfigurasi", {"kunci": "NAMA_SERVER", "nilai": "uji"}),
         ("POST", "/api/jalankan", {"kontrol": "K01", "aksi": "periksa"}),
         ("POST", "/api/laporan", {"versi_kontrak": "1", "server": {"nama": "palsu"},
                                   "waktu": "x", "siklus": "penjagaan",
                                   "ringkasan": {"skor": 100}, "kontrol": []})]

# Open on purpose. The page has to load before anyone can type a token into it,
# and the installer polls /sehat before a token exists.
OPEN = [("GET", "/"), ("GET", "/sehat")]

# Anything that is not a refusal. A 404 or a 422 still means "you got through".
ALLOWED = {200, 404, 422, 500}
REFUSED = {401, 403}


async def call(method, path, host, token=None, body=None):
    query = b""
    if "?" in path:
        path, _, qs = path.partition("?")
        query = qs.encode()
    headers, raw = [], b""
    if token:
        headers.append((b"authorization", b"Bearer " + token.encode()))
    if body is not None:
        raw = json.dumps(body).encode()
        headers += [(b"content-type", b"application/json"),
                    (b"content-length", str(len(raw)).encode())]

    scope = {"type": "http", "asgi": {"version": "3.0"}, "http_version": "1.1",
             "method": method, "scheme": "http", "path": path, "raw_path": path.encode(),
             "query_string": query, "root_path": "", "headers": headers,
             "client": (host, 51234), "server": ("127.0.0.1", 8000)}

    got, done = {}, asyncio.Event()

    async def receive():
        return {"type": "http.request", "body": raw, "more_body": False}

    async def send(message):
        if message["type"] == "http.response.start":
            got["status"] = message["status"]
        elif message["type"] == "http.response.body":
            got["body"] = got.get("body", b"") + message.get("body", b"")
            if not message.get("more_body"):
                done.set()

    await api.app(scope, receive, send)
    await done.wait()
    return got.get("status"), got.get("body", b"")


async def main():
    failures = []

    def check(label, ok, detail=""):
        print(f"  {'ok   ' if ok else 'GAGAL'} {label}{detail}")
        if not ok:
            failures.append(label)

    print(f"\n  Token: {'diisi' if TOKEN else '(kosong)'}\n")

    print("  Dari jaringan tanpa token - semua harus ditolak")
    for method, path, body in READ + WRITE:
        status, _ = await call(method, path, REMOTE, None, body)
        check(f"{method} {path}", status in REFUSED, f"  -> {status}")

    print("\n  Dari 127.0.0.1 tanpa token - semua harus boleh")
    for method, path, body in READ + WRITE:
        status, _ = await call(method, path, LOCAL, None, body)
        check(f"{method} {path}", status in ALLOWED, f"  -> {status}")

    if TOKEN:
        print("\n  Dari jaringan dengan token benar - semua harus boleh")
        for method, path, body in READ + WRITE:
            status, _ = await call(method, path, REMOTE, TOKEN, body)
            check(f"{method} {path}", status in ALLOWED, f"  -> {status}")

        print("\n  Dari jaringan dengan token salah - semua harus ditolak")
        for method, path, body in READ + WRITE:
            status, _ = await call(method, path, REMOTE, TOKEN + "x", body)
            check(f"{method} {path}", status in REFUSED, f"  -> {status}")

    print("\n  Sengaja terbuka")
    for method, path in OPEN:
        status, _ = await call(method, path, REMOTE)
        check(f"{method} {path}", status in ALLOWED, f"  -> {status}")

    # /sehat answers before any token exists, so it must not describe the
    # installation to a stranger while doing so.
    _, body = await call("GET", "/sehat", REMOTE)
    check("/sehat dari jaringan tidak menyebut jalur database", b'"db"' not in body)

    # One agent collecting answers must never swallow another server's.
    status, _ = await call("GET", "/api/keputusan", LOCAL)
    check("GET /api/keputusan tanpa ?server= ditolak", status == 422, f"  -> {status}")

    if failures:
        print(f"\n  GAGAL {len(failures)}:")
        for f in failures:
            print(f"    - {f}")
        return 1
    print("\n  Semua lulus.\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(asyncio.run(main()))
    except KeyboardInterrupt:
        sys.exit(130)
