# How it works

Thin summary for this guide. Full detail (request path, body modes, what is not inspected): [docs/how-it-works.md](https://github.com/etiennemunnich/envoy-modsec-connex/blob/main/docs/how-it-works.md).

## Where it sits

```text
Client ──► Envoy ──ext_proc gRPC──► ext-proc-modsec ──C API──► libmodsecurity (+ CRS)
              │
              └──► origin   (only after Continue)
```

The connector never dials your origin. Envoy does, and only after the connector says **Continue**.

## Request path (one sentence per hop)

1. Client hits Envoy. `ext_proc` runs **before** the router (`failure_mode_allow: false`, demo `message_timeout: 2s` except FULL_DUPLEX).
2. Envoy sends `request_headers` → connector opens one ModSecurity transaction (phase 1). Deny → local **403** (or redirect); engine error → **500**.
3. Envoy sends request body (or not; see [body modes](./README.md#mode-comparison)). Connector appends every chunk; phase 2 at end-of-stream. Deny / fail-closed → local reply; Continue → Envoy may forward to origin.
4. Response headers / body come back through the same stream (phases 3 / 4). Then Continue or local **403**.

HTTP/1.1 and HTTP/2 use the same connector path. Trace one request: `./demo/scripts/hop-trace.sh`.

## What is inspected

| Surface | Inspected? |
|---------|------------|
| Request / response headers | Yes (when `SEND`) |
| Request / response bodies | Depends on body mode (BUFFERED / STREAMED / FULL_DUPLEX yes; PARTIAL = prefix; NONE = no) |
| Trailer *values* | No (no SecLang trailer phase; product default `SKIP`) |
| gRPC protobuf bodies | No (headers/path hop-trace only) |
| WebSocket frames | No (handshake headers only) |
| HTTP/3 | Not supported in the product demo |

## Body mode in one line

| Mode | Origin on request-body deny | Full CRS claim |
|------|----------------------------|----------------|
| **BUFFERED** | Untouched | Smoke + hosted full (proven) |
| **STREAMED** | Early chunks may move before EOS phase-2 | Smoke hosted; full matrix **wired** |
| **BUFFERED_PARTIAL** | Under-limit like BUFFERED; trailing can miss | Honesty only |
| **NONE** | Body attacks reach origin | Body CRS n/a |
| **FULL_DUPLEX_STREAMED** | Connector holds until allow | Smoke hosted; full matrix **wired**; `message_timeout` off |

## Related

- [Fail-closed](./fail-closed.md): 403 vs 500/504
- [Config / pins](./config-pins.md): versions, `BODY_MODE`, demo YAMLs
- [Architecture](./architecture.md): filter chain diagram
- [Troubleshooting](./troubleshooting.md)
