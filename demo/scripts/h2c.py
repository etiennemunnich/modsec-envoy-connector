#!/usr/bin/env python3
"""Minimal HTTP/2 prior-knowledge (h2c) client, standard library only.

Sends one request whose body and trailers are under the caller's control,
which curl cannot do (it never sends request trailers):

    h2c.py PORT PATH [--method M] [--header k:v ...] [--data BODY]
           [--trailer k:v ...] [--empty-data]

Frame order: HEADERS (END_STREAM only when there is neither data nor
trailers), DATA (END_STREAM unless trailers follow), trailers HEADERS
(END_STREAM). Prints the response :status, or RST / GOAWAY / 000 when the
stream is reset, the connection is refused, or nothing arrives in time.

Only :status is decoded from the response: static-table entries, or a literal
value (raw or Huffman-coded digits). One connection per request, so the
dynamic table is never referenced for it.
"""
import argparse
import socket
import struct
import sys

PREFACE = b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
DATA, HEADERS, RST_STREAM, SETTINGS, PING, GOAWAY, CONTINUATION = 0, 1, 3, 4, 6, 7, 9
END_STREAM, END_HEADERS, PADDED, PRIORITY = 0x1, 0x4, 0x8, 0x20
STATIC_STATUS = {8: "200", 9: "204", 10: "206", 11: "304", 12: "400", 13: "404", 14: "500"}
# HPACK Huffman codes for the ten digits (RFC 7541 Appendix B).
HUFFMAN_DIGITS = {
    (0b00000, 5): "0", (0b00001, 5): "1", (0b00010, 5): "2", (0b011001, 6): "3",
    (0b011010, 6): "4", (0b011011, 6): "5", (0b011100, 6): "6", (0b011101, 6): "7",
    (0b011110, 6): "8", (0b011111, 6): "9",
}


def frame(ftype, flags, stream, payload=b""):
    return struct.pack(">I", len(payload))[1:] + bytes([ftype, flags]) + struct.pack(">I", stream) + payload


def hpack_string(s):
    b = s.encode()
    if len(b) >= 127:
        raise ValueError("header strings up to 126 bytes only")
    return bytes([len(b)]) + b


def hpack_block(pairs):
    # Literal header field without indexing, new name, no Huffman.
    return b"".join(b"\x00" + hpack_string(k) + hpack_string(v) for k, v in pairs)


def hpack_int(block, i, prefix_bits):
    mask = (1 << prefix_bits) - 1
    value = block[i] & mask
    i += 1
    if value < mask:
        return value, i
    shift = 0
    while True:
        b = block[i]
        i += 1
        value += (b & 0x7F) << shift
        shift += 7
        if not b & 0x80:
            return value, i


def huffman_digits(data):
    bits = "".join(f"{b:08b}" for b in data)
    out, i = "", 0
    while i < len(bits):
        for (code, n), digit in HUFFMAN_DIGITS.items():
            if i + n <= len(bits) and int(bits[i:i + n], 2) == code:
                out += digit
                i += n
                break
        else:
            break  # EOS padding (all ones) or a non-digit
    return out


def status_from_block(block):
    i = 0
    while i < len(block) and block[i] & 0xE0 == 0x20:  # dynamic table size update
        _, i = hpack_int(block, i, 5)
    b = block[i]
    if b & 0x80:
        idx, _ = hpack_int(block, i, 7)
        return STATIC_STATUS.get(idx, f"indexed:{idx}")
    prefix = 6 if b & 0x40 else 4
    idx, i = hpack_int(block, i, prefix)
    if idx not in STATIC_STATUS:
        return f"literal-name:{idx}"
    huffman = block[i] & 0x80
    length, i = hpack_int(block, i, 7)
    raw = block[i:i + length]
    return huffman_digits(raw) if huffman else raw.decode()


def read_exact(sock, n):
    buf = b""
    while len(buf) < n:
        part = sock.recv(n - len(buf))
        if not part:
            raise ConnectionError("closed")
        buf += part
    return buf


def header_pair(s):
    k, _, v = s.partition(":")
    return k.strip().lower(), v.strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("port", type=int)
    ap.add_argument("path")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--authority", default="localhost")
    ap.add_argument("--method", default="POST")
    ap.add_argument("--header", action="append", default=[], type=header_pair)
    ap.add_argument("--data")
    ap.add_argument("--empty-data", action="store_true", help="send a zero-length DATA frame")
    ap.add_argument("--trailer", action="append", default=[], type=header_pair)
    ap.add_argument("--timeout", type=float, default=10.0)
    a = ap.parse_args()

    body = a.data.encode() if a.data is not None else (b"" if a.empty_data else None)
    if body is not None and len(body) > 16384:
        sys.exit("--data up to 16384 bytes (one DATA frame)")
    request = [(":method", a.method), (":scheme", "http"), (":authority", a.authority), (":path", a.path)]
    request += a.header
    try:
        sock = socket.create_connection((a.host, a.port), timeout=a.timeout)
    except OSError:
        print("000")
        return
    sock.settimeout(a.timeout)
    out = PREFACE + frame(SETTINGS, 0, 0)
    last_is_headers = body is None and not a.trailer
    out += frame(HEADERS, END_HEADERS | (END_STREAM if last_is_headers else 0), 1, hpack_block(request))
    if body is not None:
        out += frame(DATA, 0 if a.trailer else END_STREAM, 1, body)
    if a.trailer:
        out += frame(HEADERS, END_HEADERS | END_STREAM, 1, hpack_block(a.trailer))
    sock.sendall(out)

    result, block = "000", b""
    try:
        while True:
            head = read_exact(sock, 9)
            length = int.from_bytes(head[:3], "big")
            ftype, flags = head[3], head[4]
            stream = struct.unpack(">I", head[5:9])[0] & 0x7FFFFFFF
            payload = read_exact(sock, length)
            if ftype == SETTINGS and not flags & 0x1:
                sock.sendall(frame(SETTINGS, 0x1, 0))
            elif ftype == PING and not flags & 0x1:
                sock.sendall(frame(PING, 0x1, 0, payload))
            elif ftype == GOAWAY:
                result = "GOAWAY"
                break
            elif ftype == RST_STREAM and stream == 1:
                result = "RST"
                break
            elif ftype in (HEADERS, CONTINUATION) and stream == 1:
                p = payload
                if ftype == HEADERS:
                    pad = p[0] if flags & PADDED else 0
                    p = p[1:] if flags & PADDED else p
                    p = p[5:] if flags & PRIORITY else p
                    p = p[:len(p) - pad]
                block += p
                if flags & END_HEADERS:
                    result = status_from_block(block)
                    break
    except (ConnectionError, socket.timeout, OSError):
        pass
    finally:
        sock.close()
    print(result)


if __name__ == "__main__":
    main()
