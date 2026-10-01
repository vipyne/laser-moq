#!/usr/bin/env python3
"""Localhost control endpoint for scripts/impair.sh — backs the page's
"impair network" button (local stack only; started by scripts/dev.sh).
GET /status · POST /on?profile=wifi · POST /off. CORS open: page lives on
localhost:8000, this listens on 127.0.0.1:9900."""
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs, urlparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
IMPAIR = os.path.join(ROOT, "scripts", "impair.sh")
# Only the local page may call cross-origin; a request with any other Origin
# (a drive-by page in the same browser) is refused.
ALLOWED_ORIGINS = {"http://localhost:8000", "http://127.0.0.1:8000"}


def impair(*args):
    return subprocess.run(["bash", IMPAIR, *args], capture_output=True, text=True)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body):
        data = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        origin = self.headers.get("Origin")
        if origin in ALLOWED_ORIGINS:
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Vary", "Origin")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _origin_ok(self):
        origin = self.headers.get("Origin")
        return origin is None or origin in ALLOWED_ORIGINS

    def do_GET(self):
        if not self._origin_ok():
            return self._send(403, '{"error":"forbidden origin"}')
        if urlparse(self.path).path != "/status":
            return self._send(404, '{"error":"not found"}')
        self._send(200, impair("status").stdout.strip() or '{"active":false,"profile":null}')

    def do_POST(self):
        if not self._origin_ok():
            return self._send(403, '{"error":"forbidden origin"}')
        url = urlparse(self.path)
        if url.path == "/on":
            profile = (parse_qs(url.query).get("profile") or ["wifi"])[0]
            if not re.fullmatch(r"[a-z]+", profile):
                return self._send(400, '{"error":"bad profile"}')
            r = impair("on", profile)
        elif url.path == "/off":
            r = impair("off")
        else:
            return self._send(404, '{"error":"not found"}')
        if r.returncode != 0:
            msg = (r.stderr or r.stdout).strip()[-300:]
            return self._send(500, json.dumps({"error": msg or "impair.sh failed (sudo rule? HUMAN.md §4)"}))
        self._send(200, impair("status").stdout.strip())

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", 9900), Handler).serve_forever()
