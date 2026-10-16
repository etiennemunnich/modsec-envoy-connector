#!/usr/bin/env python3
"""Minimal WebSocket echo origin for the frame-bound demo.

Stdlib only. Accepts one RFC6455 upgrade, echoes text/binary frames, records
every accepted handshake (and optional post-upgrade frame count) to a hits file.

  python3 ws-echo.py <port> <hits-file>

Not a product server. Used by demo/scripts/hop-trace-ws-frames.sh.
"""

from __future__ import annotations

import base64
import hashlib
import socket
import struct
import sys
import threading

GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
HITS_LOCK = threading.Lock()


def record(hits_path: str, line: str) -> None:
    with HITS_LOCK, open(hits_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def accept_key(key: str) -> str:
    digest = hashlib.sha1((key + GUID).encode("ascii")).digest()
    return base64.b64encode(digest).decode("ascii")


def parse_headers(raw: bytes) -> tuple[str, dict[str, str]]:
    text = raw.decode("latin1", "replace")
    lines = text.split("\r\n")
    req = lines[0] if lines else ""
    headers: dict[str, str] = {}
    for line in lines[1:]:
        if not line or ":" not in line:
            continue
        k, v = line.split(":", 1)
        headers[k.strip().lower()] = v.strip()
    return req, headers


def read_frame(conn: socket.socket) -> tuple[int, bytes] | None:
    hdr = conn.recv(2)
    if len(hdr) < 2:
        return None
    b1, b2 = hdr[0], hdr[1]
    opcode = b1 & 0x0F
    masked = (b2 & 0x80) != 0
    length = b2 & 0x7F
    if length == 126:
        ext = conn.recv(2)
        if len(ext) < 2:
            return None
        length = struct.unpack("!H", ext)[0]
    elif length == 127:
        ext = conn.recv(8)
        if len(ext) < 8:
            return None
        length = struct.unpack("!Q", ext)[0]
    mask = b""
    if masked:
        mask = conn.recv(4)
        if len(mask) < 4:
            return None
    data = b""
    while len(data) < length:
        chunk = conn.recv(length - len(data))
        if not chunk:
            return None
        data += chunk
    if masked:
        data = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
    return opcode, data


def write_frame(conn: socket.socket, opcode: int, payload: bytes) -> None:
    header = bytearray()
    header.append(0x80 | (opcode & 0x0F))
    n = len(payload)
    if n < 126:
        header.append(n)
    elif n < 65536:
        header.append(126)
        header.extend(struct.pack("!H", n))
    else:
        header.append(127)
        header.extend(struct.pack("!Q", n))
    conn.sendall(bytes(header) + payload)


def handle(conn: socket.socket, hits_path: str) -> None:
    try:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = conn.recv(4096)
            if not chunk:
                return
            data += chunk
            if len(data) > 65536:
                return
        head, _ = data.split(b"\r\n\r\n", 1)
        req, headers = parse_headers(head)
        rid = headers.get("x-request-id", "-")
        path = req.split(" ")[1] if " " in req else "/"
        key = headers.get("sec-websocket-key")
        if (
            headers.get("upgrade", "").lower() != "websocket"
            or "upgrade" not in headers.get("connection", "").lower()
            or not key
        ):
            conn.sendall(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n")
            return
        accept = accept_key(key)
        resp = (
            "HTTP/1.1 101 Switching Protocols\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Accept: {accept}\r\n"
            "\r\n"
        )
        conn.sendall(resp.encode("ascii"))
        record(hits_path, f"UPGRADE {path} rid={rid}")
        frames = 0
        while True:
            frame = read_frame(conn)
            if frame is None:
                break
            opcode, payload = frame
            if opcode == 0x8:  # close
                write_frame(conn, 0x8, payload[:2] if len(payload) >= 2 else b"")
                break
            if opcode == 0x9:  # ping
                write_frame(conn, 0xA, payload)
                continue
            if opcode in (0x1, 0x2):  # text / binary
                frames += 1
                record(hits_path, f"FRAME opcode={opcode} bytes={len(payload)} rid={rid}")
                write_frame(conn, opcode, payload)
    finally:
        try:
            conn.close()
        except OSError:
            pass


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit("usage: ws-echo.py <port> <hits-file>")
    port, hits = int(sys.argv[1]), sys.argv[2]
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(16)
    sys.stderr.write(f"ws-echo listening 127.0.0.1:{port} hits={hits}\n")
    while True:
        conn, _ = srv.accept()
        threading.Thread(target=handle, args=(conn, hits), daemon=True).start()


if __name__ == "__main__":
    main()
