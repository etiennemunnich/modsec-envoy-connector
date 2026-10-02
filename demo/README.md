# Demo: Envoy + ModSecurity + CRS

Run the connector locally behind Envoy with libmodsecurity and the OWASP Core Rule Set, then watch it allow, block, and fail closed.

Versions come from [`versions.lock.md`](../versions.lock.md): Envoy **v1.39.1**, libmodsecurity **v3.0.16**, CRS **v4.29.0**. How the pieces fit: [`docs/how-it-works.md`](../docs/how-it-works.md).

```text
curl ──► Envoy :18080 ──ext_proc gRPC──► ext-proc-modsec :18081 ──C API──► libmodsecurity + CRS
            │                                  (metrics / healthz :18082)
            └──► demo origin :18098   (only after the connector says Continue)
```

## Quick start (macOS)

```bash
brew install envoy modsecurity pkg-config     # or the install scripts below
./demo/scripts/install-crs.sh                  # CRS v4.29.0 → demo/.crs
./demo/scripts/up.sh                           # builds + starts origin, connector, Envoy
./demo/scripts/smoke.sh                        # allow / deny / body / response checks
./demo/scripts/fail-closed.sh                  # kill → 500, hang → 504, bad rules → 500
./demo/scripts/fail-modes.sh                   # the wider failure matrix, HTTP/1.1 + HTTP/2
./demo/scripts/go-ftw.sh smoke                 # OWASP CRS regression tests (needs go-ftw)
./demo/scripts/down.sh
```

Try it by hand once it is up:

```bash
curl -i http://127.0.0.1:18080/                                              # 200 from origin
curl -i "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"       # 403 (CRS SQLi)
curl -i -X POST --data "comment=<script>alert(1)</script>" \
     http://127.0.0.1:18080/comment                                          # 403 (CRS XSS, body)
curl -i http://127.0.0.1:18080/leak                                          # 403 (response-body rule)
curl -s http://127.0.0.1:18082/metrics | grep ext_proc_                      # connector counters
```

## Scripts

| Script | What it does |
|--------|--------------|
| [`install-envoy.sh`](./scripts/install-envoy.sh) | Checks `envoy --version` against the pin. On Linux, downloads the official release binary into `~/.local/bin` and checks its sha256 against the release checksums. `ENVOY_VERSION=vX.Y.Z` selects another release. |
| [`install-libmodsecurity.sh`](./scripts/install-libmodsecurity.sh) | macOS: Homebrew. Linux: builds v3.0.16 from source via [`scripts/install-libmodsecurity-ubuntu.sh`](../scripts/install-libmodsecurity-ubuntu.sh). |
| [`install-crs.sh`](./scripts/install-crs.sh) | Shallow-clones CRS at the pin into `demo/.crs` and creates `crs-setup.conf` from the example. `CRS_TAG` / `CRS_DIR` select another tag and directory. |
| [`up.sh`](./scripts/up.sh) | Generates `demo/.run/modsec.conf` (engine directives → CRS → demo rules), builds the connector, starts the origin, connector and Envoy detached, and waits for `/healthz` and Envoy `/ready`. `DEMO_CRS=0` skips CRS. `BODY_MODE=STREAMED` selects [`envoy/envoy-streamed.yaml`](./envoy/envoy-streamed.yaml). `BODY_MODE=BUFFERED_PARTIAL` selects [`envoy/envoy-buffered-partial.yaml`](./envoy/envoy-buffered-partial.yaml) (1 MiB prefix) and includes [`rules/engine-partial-overlay.conf`](./rules/engine-partial-overlay.conf). |
| [`smoke.sh`](./scripts/smoke.sh) | Live assertions: benign GET/POST/JSON → **200**; SQLi/XSS/traversal in the URL → **403**; SQLi/XSS in form and JSON bodies → **403**; response-body leak → **403**. STREAMED adds a chunked last-chunk SQLi cell. Body-path floor ≥ 5. Origin hit count checked every time. |
| [`partial-honesty.sh`](./scripts/partial-honesty.sh) | **BUFFERED_PARTIAL only.** 1 MiB prefix honesty under CRS: in-prefix SQLi **403**; trailing SQLi past 1 MiB **200** (miss); benign oversize **200**. Floor = 3. Not a full-CRS claim. |
| [`trailers.sh`](./scripts/trailers.sh) | Trailer safety with temporary trailer `SEND` Envoy config (`enable_trailers` for HTTP/1): allow+trailers **200** (trailer attack uninspected), body SQLi+trailers **403** origin +0, benign+trailers **200** (no spurious 500), live trailers_continue log, plus gRPC trailers-alone **500**. Floor ≥ 5. Restores default `SKIP` Envoy. |
| [`fail-closed.sh`](./scripts/fail-closed.sh) | Kills the connector (**500**), freezes it with SIGSTOP (**504** after 2s), restarts it with broken rules (process exits, **500**), then restores (**200**). The origin must receive nothing during any failure. |
| [`fail-modes.sh`](./scripts/fail-modes.sh) | The wider failure matrix over **HTTP/1.1 and HTTP/2**: connector kill, bad-rules boot, rule deny, hang, unwritable audit log, split `Cookie` headers, an attack only in the last chunk / DATA frames, and a negative control that temporarily sets `failure_mode_allow: true` to prove the checks can see fail-open. Every check asserts status and origin hits. `--proto h1\|h2`, `--class 1,4,5`. |
| [`go-ftw.sh`](./scripts/go-ftw.sh) | Runs the OWASP CRS regression tests with [go-ftw](https://github.com/coreruleset/go-ftw) against the demo (HTTP/1.x, status codes only). `smoke` (demo tests + body-heavy CRS SQLi/XSS tests), `body`, or `full`. Results in `demo/.run/go-ftw/`. |
| [`install-go-ftw.sh`](./scripts/install-go-ftw.sh) | Installs go-ftw (Homebrew tap, or `go install`). |
| [`hop-trace.sh`](./scripts/hop-trace.sh) | Sends one request and shows every hop by request id: Envoy access log, connector phase decisions, CRS rule matches, and whether the origin received it. `--expect-status`, `--expect-origin yes\|no`, `--proto h1\|h2\|ws\|grpc`. |
| [`hop-trace-ws.sh`](./scripts/hop-trace-ws.sh) | WebSocket **handshake** hop-trace only (stock demo → Envoy `upgrade_failed` 403; origin untouched; ModSec request-phase not entered). **Not** frame CRS / full WS WAF. |
| [`hop-trace-ws-frames.sh`](./scripts/hop-trace-ws-frames.sh) | Locks the WS **frame** bound: stock `upgrade_failed`; headers-only upgrade → 101 + handshake ModSec; SQLi-shaped **frames echo** (not CRS); fail-closed on handshake; BUFFERED+upgrade hang. Floor ≥ 6. **Not** frame CRS. |
| [`ws-echo.py`](./scripts/ws-echo.py) | Tiny stdlib WebSocket echo origin (:18091) for the frame-bound suite. |
| [`hop-trace-grpc.sh`](./scripts/hop-trace-grpc.sh) | gRPC hop-trace through Envoy → connector → `demo/grpc-echo` (:18090). Headers/path/metadata only (`envoy-grpc.yaml` body modes `NONE`). Allow + deny + fail-closed + CRS path cell; floor ≥ 6. **Not** protobuf CRS. Needs `go` + `grpcurl`. |
| [`perf.sh`](./scripts/perf.sh) | Latency samples (p50/p99) on allow/deny GET+POST paths through the live demo. Floors: `PERF_N ≥ 10`, every required WAF path must match expected status for all N samples, ≥ 6 WAF paths. Empty/partial runs fail. Not an SLO. Results in `demo/.run/perf/`. |
| [`down.sh`](./scripts/down.sh) | Stops everything the demo started. |
| [`origin.py`](./scripts/origin.py), [`daemonize.py`](./scripts/daemonize.py), [`lib.sh`](./scripts/lib.sh) | Demo origin (records every hit with its request id), a detach helper, and shared settings. |

Runtime files (logs, pid files, generated rules, ModSecurity audit log) go to `demo/.run/`.

## Configuration files

| File | Role |
|------|------|
| [`envoy/envoy.yaml`](./envoy/envoy.yaml) | Envoy listener :18080 with `ext_proc` → `modsec_ext_proc` cluster. `failure_mode_allow: false`, `message_timeout: 2s`, **BUFFERED** request and response bodies, trailers **SKIP**, `request_attributes` for real client IP / protocol, CONNECT answered locally. |
| [`envoy/envoy-grpc.yaml`](./envoy/envoy-grpc.yaml) | HTTP/2 + headers-only (`NONE` bodies) → `grpc-echo` :18090. Used only by `hop-trace-grpc.sh`. Headers/path/metadata only; **not** protobuf CRS. |
| [`envoy/envoy-ws-headers.yaml`](./envoy/envoy-ws-headers.yaml) | `upgrade_configs: websocket` + body `NONE` → `ws-echo` :18091. Handshake ModSec only. |
| [`envoy/envoy-ws-buffered.yaml`](./envoy/envoy-ws-buffered.yaml) | Same upgrade + **BUFFERED** bodies (hang bound for `hop-trace-ws-frames.sh` only). |
| [`envoy/envoy-streamed.yaml`](./envoy/envoy-streamed.yaml) | Same as above with **STREAMED** request and response bodies (`BODY_MODE=STREAMED`). |
| [`envoy/envoy-buffered-partial.yaml`](./envoy/envoy-buffered-partial.yaml) | **BUFFERED_PARTIAL** request/response bodies with explicit `per_connection_buffer_limit_bytes: 1048576` (1 MiB). Prefix-only CRS; not full fidelity. |
| [`envoy/envoy-trailers.yaml`](./envoy/envoy-trailers.yaml) / [`envoy-streamed-trailers.yaml`](./envoy/envoy-streamed-trailers.yaml) | Same body modes with trailer modes **SEND**, used only by `trailers.sh` (trailer values still not CRS-inspected). |
| [`rules/engine.conf`](./rules/engine.conf) | ModSecurity engine directives (from v3.0.16 `modsecurity.conf-recommended`, engine On, response body inspection On). |
| [`rules/connex-demo.conf`](./rules/connex-demo.conf) | One demo rule that blocks responses containing `CONNEX-LEAK-MARKER`, to show the response path. |
| [`ftw/`](./ftw/) | go-ftw config, demo test cases, and `envoy-overrides.yaml` (measured Envoy platform differences, same pattern as CRS's own nginx overrides). |

## Ports

| Port | Process |
|------|---------|
| 18080 | Envoy listener |
| 18089 | Envoy admin (`/ready`, `/stats`) |
| 18081 | Connector gRPC |
| 18082 | Connector `/metrics`, `/healthz` |
| 18098 | Demo origin |
| 18090 | Demo gRPC echo (started by `hop-trace-grpc.sh` only) |
| 18091 | Demo WebSocket echo (started by `hop-trace-ws-frames.sh` only) |

`up.sh` refuses to start if any of these are taken and tells you by what.

## Linux

Envoy's apt repo is unmaintained; `install-envoy.sh` fetches the [release binary](https://github.com/envoyproxy/envoy/releases/tag/v1.39.1) instead:

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib
./demo/scripts/up.sh
```

The scripts use `lsof`, `curl` and `python3`.

## Wiring your own Envoy

Point a cluster (HTTP/2) at the connector's `--listen` address and add the filter before the router. Keep `failure_mode_allow: false`:

```yaml
http_filters:
  - name: envoy.filters.http.ext_proc
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
      grpc_service:
        envoy_grpc:
          cluster_name: modsec_ext_proc
      failure_mode_allow: false
      message_timeout: 2s
      processing_mode:
        request_header_mode: SEND
        response_header_mode: SEND
        request_body_mode: BUFFERED
        response_body_mode: BUFFERED
        request_trailer_mode: SKIP
        response_trailer_mode: SKIP
      request_attributes: [source.address, source.port, destination.address, destination.port, request.protocol]
  - name: envoy.filters.http.router
    typed_config:
      "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
```

Run the connector with your rules, in load order:

```bash
ext-proc-modsec --listen 0.0.0.0:18081 --metrics-listen 127.0.0.1:18082 \
  --modsec-rules /etc/modsecurity/engine.conf,/etc/crs/crs-setup.conf,/etc/crs/rules.conf
```

---

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0. See [LICENSE](../LICENSE).
