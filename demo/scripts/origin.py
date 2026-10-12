#!/usr/bin/env python3
"""Demo origin for the Envoy → connector → origin path.

Appends one line per request it actually receives to a hits file, so the demo
scripts can prove that denied and fail-closed requests never reached it.

  GET /leak   → 200 text/plain containing DEMO-LEAK-MARKER (response-path demo)
  POST *      → 200 echo of the received byte count
  anything    → 200 "origin ok"
"""

import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HITS_LOCK = threading.Lock()


class Handler(BaseHTTPRequestHandler):
    server_version = "connex-demo-origin"
    protocol_version = "HTTP/1.1"

    def _record(self):
        with HITS_LOCK, open(self.server.hits_path, "a", encoding="utf-8") as f:
            rid = self.headers.get("x-request-id", "-")
            f.write(f"{self.command} {self.path} rid={rid}\n")

    def _reply(self, body: bytes, status: int = 200):
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def do_GET(self):
        self._record()
        if self.path.split("?", 1)[0] == "/leak":
            self._reply(b"internal token: DEMO-LEAK-MARKER\n")
        else:
            self._reply(f"origin ok: {self.command} {self.path}\n".encode())

    do_HEAD = do_GET

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        data = self.rfile.read(length) if length else b""
        self._record()
        self._reply(f"origin received {len(data)} bytes\n".encode())

    do_PUT = do_POST

    def log_message(self, fmt, *args):
        sys.stderr.write("origin: " + (fmt % args) + "\n")


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: origin.py <port> <hits-file>")
    port, hits = int(sys.argv[1]), sys.argv[2]
    srv = ThreadingHTTPServer(("127.0.0.1", port), Handler)
    srv.hits_path = hits
    srv.serve_forever()


if __name__ == "__main__":
    main()
