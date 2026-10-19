#!/usr/bin/env python3
"""Minimal HTTP/3 client for the demo QUIC experiment (aioquic).

Not a product dependency. Used by demo/scripts/h3-probe.sh only.
"""
from __future__ import annotations

import argparse
import asyncio
import ssl
import sys

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, HeadersReceived, H3Event
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent


class H3ClientProtocol(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http: H3Connection | None = None
        self._events: dict[int, list] = {}
        self._waiters: dict[int, asyncio.Future] = {}

    def quic_event_received(self, event: QuicEvent) -> None:
        if self._http is None:
            self._http = H3Connection(self._quic)
        for http_event in self._http.handle_event(event):
            self._http_event_received(http_event)

    def _http_event_received(self, event: H3Event) -> None:
        if isinstance(event, (HeadersReceived, DataReceived)):
            sid = event.stream_id
            if sid not in self._events:
                return
            self._events[sid].append(event)
            if getattr(event, "stream_ended", False) and sid in self._waiters:
                fut = self._waiters.pop(sid)
                if not fut.done():
                    fut.set_result(self._events.pop(sid))

    async def request(
        self,
        method: str,
        path: str,
        body: bytes | None = None,
        authority: str = "localhost",
        timeout: float = 8.0,
    ) -> tuple[str | None, bytes]:
        if self._http is None:
            self._http = H3Connection(self._quic)
        stream_id = self._quic.get_next_available_stream_id()
        self._events[stream_id] = []
        fut = asyncio.get_running_loop().create_future()
        self._waiters[stream_id] = fut
        headers = [
            (b":method", method.encode()),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
            (b"user-agent", b"h3-probe/aioquic"),
        ]
        if body is not None:
            headers.append((b"content-type", b"application/x-www-form-urlencoded"))
            headers.append((b"content-length", str(len(body)).encode()))
        self._http.send_headers(
            stream_id=stream_id, headers=headers, end_stream=(body is None)
        )
        if body is not None:
            self._http.send_data(stream_id=stream_id, data=body, end_stream=True)
        self.transmit()
        events = await asyncio.wait_for(fut, timeout=timeout)
        status: str | None = None
        resp_body = b""
        for ev in events:
            if isinstance(ev, HeadersReceived):
                for k, v in ev.headers:
                    if k == b":status":
                        status = v.decode()
            elif isinstance(ev, DataReceived):
                resp_body += ev.data
        return status, resp_body


async def _amain() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=18443)
    p.add_argument("--method", default="GET")
    p.add_argument("--path", default="/")
    p.add_argument("--body", default=None)
    p.add_argument("--authority", default="localhost")
    p.add_argument("--timeout", type=float, default=8.0)
    args = p.parse_args()
    configuration = QuicConfiguration(is_client=True, alpn_protocols=H3_ALPN)
    configuration.verify_mode = ssl.CERT_NONE
    async with connect(
        args.host,
        args.port,
        configuration=configuration,
        create_protocol=H3ClientProtocol,
    ) as proto:
        body = None if args.body is None else args.body.encode()
        status, resp = await proto.request(
            args.method,
            args.path,
            body=body,
            authority=args.authority,
            timeout=args.timeout,
        )
        print(f"STATUS {status}")
        print(f"BODY {resp[:300]!r}")
        return 0 if status else 1


def main() -> None:
    try:
        raise SystemExit(asyncio.run(_amain()))
    except ModuleNotFoundError as e:
        print(f"missing dependency: {e} (pip install aioquic)", file=sys.stderr)
        raise SystemExit(2) from e


if __name__ == "__main__":
    main()
