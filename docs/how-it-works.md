---
title: How it works — ModSec × Envoy × Rust ext_proc
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false · message_timeout 2s
product: Rust ext_proc → FFI → libmodsecurity
license: see LICENSE
---

# How it works

Envoy cannot run ModSecurity itself. `ext-proc-modsec` is a small Rust gRPC server that Envoy's `ext_proc` filter calls for every HTTP exchange. It feeds request headers, request body, response headers and response body into **one libmodsecurity transaction** and answers each step with **Continue**, a rule-driven **local reply** (403, redirect, …), or a fail-closed **500**. The connector never talks to your origin; only Envoy does, and only after the connector has said Continue.

Pins: [`versions.lock.md`](../versions.lock.md). Failure model: [fail-closed.md](./fail-closed.md). Tests: [testing.md](./testing.md). Runnable demo: [`demo/README.md`](../demo/README.md).

---

## Hops

| Hop | From → To | Protocol | Reaches origin? |
|-----|-----------|----------|-----------------|
| 1 | Client → **Envoy** | HTTP/1.1, HTTP/2 | No |
| 2 | **Envoy ↔ connector** | gRPC bidi `envoy.service.ext_proc.v3.ExternalProcessor/Process` | No — side-call |
| — | connector → **libmodsecurity** | in-process FFI (`msc_*` C API, declared in `modsec-engine`) | No |
| 3 | **Envoy → origin** | HTTP | **Yes — Envoy only**, after Continue |

With `request_body_mode: BUFFERED` Envoy holds the whole request until the connector has inspected the body, so a request-body deny happens before the origin sees anything — including when the attack sits only in the last HTTP/1.1 chunk or the last HTTP/2 DATA frames. The demo's origin records every hit with its `x-request-id`, and the demo suites assert it stays untouched for denied and failed requests. `demo/scripts/hop-trace.sh` shows all hops for one request.

HTTP/1.1 and HTTP/2 (cleartext prior knowledge in the demo) both go through the same path; Envoy reassembles split HTTP/2 `Cookie` headers before the connector sees them. Envoy's HTTP/1 codec accepts non-standard methods in the demo config (`allow_custom_methods`) so CRS rule 911100 enforces the method policy instead of the codec dropping the request.

---

## Code map

| Crate / file | Role |
|--------------|------|
| `crates/modsec-engine/src/lib.rs`, `ffi.rs`, `build.rs` | The only crate with `unsafe`. `ffi.rs` declares the ~25 libmodsecurity v3 `msc_*` functions used; `build.rs` links the system library via the `pkg-config` tool (≥ 3.0.13). `Engine` = one `ModSecurity` + `RulesSet` loaded at boot (shared via `Arc`; rule parsing and teardown serialised by a global lock). `InspectionSession` = one `Transaction` per exchange; enforces phase order; reads the intervention after every step; maps it to `Decision` (`Allow` / `Block` / `Redirect` / `Drop`). |
| `crates/ext-proc-modsec/src/processor.rs` | `ModSecProcessor` (tonic service). One `Exchange` per gRPC stream holds the session, `x-request-id`, and connection metadata; turns each `ProcessingRequest` into a `Step`. Envoy's messages are read only while tonic asks for the next reply. |
| `crates/ext-proc-modsec/src/pb/` | Generated prost/tonic code for `envoy.service.ext_proc.v3` and its imports (committed; no `protoc` at build time). Source: `proto/` (Envoy v1.39.1 API closure); regenerate with `scripts/gen-protos.sh`. |
| `crates/ext-proc-modsec/src/responses.rs` | Builds Continue / `ImmediateResponse` messages; validates statuses. |
| `crates/ext-proc-modsec/src/connection_meta.rs` | Reads Envoy `request_attributes` (`source.*`, `destination.*`, `request.protocol`) for `process_connection` / `process_uri`. |
| `crates/ext-proc-modsec/src/metrics.rs`, `metrics_server.rs` | Prometheus counters/histograms; `GET /metrics`, `GET /healthz`. |
| `crates/ext-proc-modsec/src/config.rs`, `logging.rs`, `main.rs` | CLI/env config; stderr log formatter for `tracing`; fail-closed boot; SIGINT/SIGTERM shutdown. |

---

## One exchange, step by step

One `Process` stream = one HTTP request/response = one ModSecurity transaction.

| Envoy sends | Connector does | Answers |
|-------------|----------------|---------|
| `request_headers` | Opens the transaction (id = `x-request-id`). Runs `process_connection` (real client/server IP:port from attributes), `process_uri` (method, `:path`, HTTP version), adds non-pseudo headers (`host` from `:authority` if missing), `process_request_headers`. If `end_of_stream`, also runs the request-body phase. | Continue, or terminal reply |
| `request_body` | `append_request_body` (intervention checked on every append, so body-limit rejects fire here); at `end_of_stream` runs `process_request_body` (CRS phase 2). | Continue, or terminal reply |
| `response_headers` | Closes the request body if still open, adds headers, `process_response_headers(:status, protocol)` (phase 3). If `end_of_stream`, also runs the response-body phase. | Continue, or terminal reply |
| `response_body` | `append_response_body`; at `end_of_stream` runs `process_response_body` (phase 4). | Continue, or terminal reply |
| trailers | Not inspected (the demo config sets trailer modes to `SKIP`). | Continue |
| `response_headers` **with no `request_headers` on the stream** | Envoy rejected the request itself before the request phase (e.g. a `#fragment` URI → 400, `OPTIONS *` → 404) and ext_proc only sees its local reply. The origin was never contacted. If `:status` is 4xx/5xx it is passed through; anything else fails closed. | Continue (status 4xx/5xx), else **500** |

Stream end drops the session, which runs ModSecurity's logging phase (audit log) and frees the transaction.

---

## Decisions → what the client sees

| Engine result | Connector answer | Client |
|---------------|------------------|--------|
| No disruptive intervention | Continue | Origin response |
| Deny with status 4xx/5xx | `ImmediateResponse` with that status, generic body, details `modsecurity_intervention` | e.g. **403** |
| Deny with any other status (1–399, ≥ 600, or unknown to Envoy) | `ImmediateResponse` **403** | **403** |
| Redirect | `ImmediateResponse` 3xx (302 if the rule's status is not 3xx) + `Location` | **302** |
| Drop (intervention status 0) | Stream aborted with gRPC `ABORTED` | Envoy local **500** |
| Engine error / phase-order violation / malformed message | `ImmediateResponse` **500**, details `modsec_fail_closed` | **500** |
| `CONNECT` | `ImmediateResponse` **403**, details `connect_rejected` | **403** |
| Envoy local reply 4xx/5xx with no request on the stream | Continue for its headers and body (not inspected; counted in `ext_proc_local_reply_passthrough_total`) | Envoy's own status, e.g. **400** |
| Response headers with no request on the stream and any other status | `ImmediateResponse` **500**, details `modsec_fail_closed` | **500** |

Why statuses are validated: Envoy v1.39 sends an `ImmediateResponse` whose status is missing or invalid (including 0) as **HTTP 200** (`DefaultImmediateStatus` in `ext_proc.cc`). The connector therefore never passes through an unchecked status. That is also why a drop becomes a stream abort (which Envoy fails closed) rather than status 0.

The deny body is always generic (`Forbidden`). ModSecurity's intervention message (rule id, matched data) goes only to the connector log and the ModSecurity audit log, never to the client.

After any terminal answer the connector closes the stream; nothing is ever sent as Continue after an engine error.

---

## Failure behaviour (summary)

| Case | Who enforces | Client |
|------|--------------|--------|
| Connector not running / crashed / stream error | Envoy (`failure_mode_allow: false`) | **500** |
| Connector hung past `message_timeout` (2s) | Envoy | **504** |
| Rules fail to load at boot | Connector exits non-zero before binding; Envoy then returns 500 | **500** |
| Per-request engine error | Connector `ImmediateResponse` 500 | **500** |

Details and drills: [fail-closed.md](./fail-closed.md).

---

## Configuration

`ext-proc-modsec` flags (each also readable from the environment):

| Flag | Env | Default | Notes |
|------|-----|---------|-------|
| `--listen` | `EXT_PROC_LISTEN` | `127.0.0.1:18081` | gRPC address Envoy's `modsec_ext_proc` cluster targets (HTTP/2). |
| `--metrics-listen` | `EXT_PROC_METRICS_LISTEN` | `127.0.0.1:18082` | `/metrics` and `/healthz`. |
| `--modsec-rules` | `MODSEC_RULES` | *(required)* | One or more files (repeat or comma-separate), loaded in order, e.g. engine directives → `crs-setup.conf` → `rules/*.conf`. |

`--help` and `--version` print usage and the version. Logging uses `RUST_LOG`: a comma-separated list of a default level and `target=level` overrides (default `info`), e.g. `RUST_LOG=info,modsecurity=debug`; ModSecurity's own messages are under target `modsecurity` at `debug`.

Envoy settings the connector relies on (see [`demo/envoy/envoy.yaml`](../demo/envoy/envoy.yaml)):

- `failure_mode_allow: false` and `message_timeout: 2s`.
- `http_protocol_options.allow_custom_methods: true`, so CRS sees methods like `TEST` (a work-in-progress field in Envoy v1.39; without CRS loaded, custom methods reach the origin).
- `processing_mode`: headers `SEND`, bodies `BUFFERED`, trailers `SKIP`.
- `request_attributes`: `source.address`, `source.port`, `destination.address`, `destination.port`, `request.protocol`. Without them, ModSecurity sees `127.0.0.1` as `REMOTE_ADDR` (logged as `conn_source=fallback`) and IP-based rules are wrong.
- Never enable `observability_mode` on an enforcing filter: Envoy does not wait for answers there, so the connector ignores those messages.

---

## Observability

- **Logs** (structured, `tracing`): one line per phase with `request_id`, `phase`, `action` (`allow`/`deny`/`redirect`/`drop`), `latency_ms`, `body_bytes`, and for request headers the client/server endpoints and their source. Fail-closed lines carry `action="fail_closed"` and the error.
- **Metrics** (`GET /metrics`, Prometheus text): `ext_proc_requests_total`, `ext_proc_allow_total`, `ext_proc_deny_total`, `ext_proc_fail_closed_total`, `ext_proc_stream_errors_total`, `ext_proc_local_reply_passthrough_total`, `ext_proc_{request,response}_body_bytes_total`, and `ext_proc_phase_{request_headers,request_body,response_headers,response_body}_seconds` histograms.
- **Readiness** (`GET /healthz`): returns 200 only if, within 2s, the gRPC listener completes an HTTP/2 preface + SETTINGS exchange **and** a headers-only `GET /__connex_healthz` run through a fresh per-stream `Exchange` (the same code `Process` runs, with the loaded rules) answers Continue. The connector ships no gRPC client, so the probe does not send a full `Process` RPC over the wire. Rules are always loaded before the server starts.
- **Envoy side**: `%RESPONSE_CODE_DETAILS%` shows `modsecurity_intervention` / `modsec_fail_closed` (and `ext_proc_error_*` when Envoy itself fails the call, e.g. connector down or timed out); ext_proc stats live under `http.<prefix>.ext_proc.modsec_ext_proc.*` (`streams_failed`, `message_timeouts`, `failure_mode_allowed` must stay 0).

---

## Known limits

- **Buffered bodies only are proven.** `STREAMED` mode works mechanically (intervention is checked on every append) but a phase-2/4 rule can only decide at end of stream, after earlier chunks may already have moved on. Envoy's buffer limit (default 1 MiB per stream) caps inspectable body size.
- **Trailers** are not inspected.
- **Pause** interventions are logged and ignored (ext_proc has no delay primitive).
- **Drop** cannot close the TCP connection through ext_proc; it maps to a stream abort → Envoy 500.
- `/healthz` probes run through the rules and are counted in `ext_proc_requests_total` / `ext_proc_allow_total`.
- **Envoy local replies before the request phase are not inspected.** When Envoy rejects a request itself before ext_proc sees its headers, the connector only sees the local reply. A 4xx/5xx passes through with Envoy's status; the request never reached ModSecurity or the origin, so there is nothing to decide. The pass-through relies on `request_header_mode: SEND` (Envoy never forwards a request to the origin without a request-headers message first). A stream-level 1xx–3xx without a request is still failed closed.
- HTTP/3 and WebSocket frame inspection are not supported.
