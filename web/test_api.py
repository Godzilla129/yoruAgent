#!/usr/bin/env python3
"""
Who is allowed to reach which endpoint - checked, not assumed.

    python3 test_api.py [token]

Needs only fastapi. The app is driven directly as an ASGI callable with the
scope built by hand, because the rule under test is "free from 127.0.0.1,
token required from anywhere else" and a normal test client cannot set the
caller's IP. Add every new endpoint below to READ, WRITE or OPEN.
"""

import asyncio
import json
import os
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent

# Pointed at throwaway files before api is imported - it reads them at import time.
os.environ["YORU_DB"] = str(Path(tempfile.mkdtemp()) / "uji.db")
os.environ["YORU_KONF"] = str(Path(tempfile.mkdtemp()) / "yoru.conf")
os.environ["YORU_LOG"] = tempfile.mkdtemp()
TOKEN = os.environ["YORU_TOKEN"] = sys.argv[1] if len(sys.argv) > 1 else ""

sys.path.insert(0, str(HERE))
import api  # noqa: E402

LOCAL, REMOTE = "127.0.0.1", "203.0.113.9"

READ = [("GET", "/api/report", None),
        ("GET", "/api/servers", None),
        ("GET", "/api/history", None),
        ("GET", "/api/log", None),
        ("GET", "/api/decision?server=uji", None),
        ("GET", "/api/config", None)]

WRITE = [("POST", "/api/decision", {"server": "uji", "control": "K01", "value": "setuju"}),
         ("POST", "/api/port", {"server": "uji", "port": [8080]}),
         ("POST", "/api/config", {"key": "NAMA_SERVER", "value": "uji"}),
         ("POST", "/api/run", {"control": "K01", "action": "periksa"}),
         ("POST", "/api/report", {"contract_version": "1", "server": {"name": "palsu"},
                                   "time": "x", "cycle": "penjagaan",
                                   "summary": {"score": 100}, "controls": []})]

# Open on purpose: the page loads before a token exists, and the installer polls /health.
OPEN = [("GET", "/"), ("GET", "/health")]

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

    _, body = await call("GET", "/health", REMOTE)
    check("/health dari jaringan tidak menyebut jalur database", b'"db"' not in body)

    status, _ = await call("GET", "/api/decision", LOCAL)
    check("GET /api/decision tanpa ?server= ditolak", status == 422, f"  -> {status}")

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
