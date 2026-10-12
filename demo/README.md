# Demo: Envoy + ModSecurity + CRS

Scripts and configs that run the connector locally behind Envoy with libmodsecurity and the OWASP Core Rule Set. Step-by-step walkthrough: [`docs/getting-started.md`](../docs/getting-started.md). What each suite proves: [`docs/testing.md`](../docs/testing.md).

```text
curl ──► Envoy :18080 ──ext_proc gRPC──► ext-proc-modsec :18081 ──C API──► libmodsecurity + CRS
            │                                  (metrics / healthz :18082)
            └──► demo origin :18098   (only after the connector says Continue)
```

## Scripts

| Script | What it does |
|--------|--------------|
| [`install-envoy.sh`](./scripts/install-envoy.sh) | Envoy at the pin (`ENVOY_VERSION=vX.Y.Z` for another). Linux: downloads the release binary into `~/.local/bin` and checks its sha256 against the release checksums. macOS: `brew install` or `brew upgrade envoy`, then fails if Homebrew's version is not the pin. |
| [`install-libmodsecurity.sh`](./scripts/install-libmodsecurity.sh) | libmodsecurity at the pin. Linux: builds it from source into `~/.local` (`MODSECURITY_PREFIX` for another prefix) via [`scripts/install-libmodsecurity-ubuntu.sh`](../scripts/install-libmodsecurity-ubuntu.sh). macOS: Homebrew. Fails unless `pkg-config` then reports exactly the pin. |
| [`install-crs.sh`](./scripts/install-crs.sh) | CRS at the pin into `demo/.crs`, with `crs-setup.conf` from the example. `CRS_TAG` / `CRS_DIR` select another tag and directory. |
| [`install-go-ftw.sh`](./scripts/install-go-ftw.sh) | go-ftw at `GO_FTW_PIN`, checksum-verified, into `~/.local/bin` (`PREFIX` for another prefix). |
| [`up.sh`](./scripts/up.sh) | Writes `demo/.run/modsec.conf` (engine directives, CRS, demo rules), builds the connector, starts the origin, connector and Envoy in the background, and waits for `/healthz` and Envoy `/ready`. Starts BUFFERED unless `BODY_MODE` is set, and saves the mode in `demo/.run/body_mode` for the other scripts. `DEMO_CRS=0` skips CRS; `DEMO_PORT_BASE` moves every port. |
| [`smoke.sh`](./scripts/smoke.sh) | Benign GET, form and JSON → **200**; SQLi, XSS and traversal in the URL or body → **403**; response-body rule → **403**; CONNECT → **403**. Checks the origin hit count every time. At least 5 body checks must pass (NONE: 5 header checks). |
| [`fail-closed.sh`](./scripts/fail-closed.sh) | Connector killed → **500**; frozen with SIGSTOP → **504** after 2 s (`SKIP` under FULL_DUPLEX_STREAMED); restarted with broken rules → **500**; then restored → **200**. The origin must receive nothing during any failure. |
| [`fail-modes.sh`](./scripts/fail-modes.sh) | Failure classes 1–6 over HTTP/1.1 and HTTP/2: kill, bad rules, rule deny, hang, unwritable audit log, split `Cookie` headers, an attack only in the last chunk, and a negative control with `failure_mode_allow: true`. `--proto h1\|h2`, `--class 1,4,5`. |
| [`trailers.sh`](./scripts/trailers.sh) | Restarts Envoy with HTTP/1 trailers enabled: allow + trailers **200**, body SQLi + trailers **403** with the origin untouched, benign + trailers **200**, plus the gRPC trailers-without-session **500** test. Restores the stock config. |
| [`h2-trailers.sh`](./scripts/h2-trailers.sh) | HTTP/2 requests whose body ends in trailers, sent with [`h2c.py`](./scripts/h2c.py) through the stock config: SQLi body + trailers and SQLi query with trailers but no body → **403**, origin untouched; benign body + trailers and benign trailers-only → **200**, origin +1. At least 4 must pass (3 under NONE). |
| [`go-ftw.sh`](./scripts/go-ftw.sh) | OWASP CRS regression tests with [go-ftw](https://github.com/coreruleset/go-ftw), HTTP/1.x, judged by status code: `smoke`, `body` or `full`. Uses `FTW_BIN`, else `~/.local/bin/ftw`, else `PATH`. Results in `demo/.run/go-ftw/`. |
| [`hop-trace.sh`](./scripts/hop-trace.sh) | One request (default `GET /`) followed by request id through the Envoy access log, connector phases, CRS matches and the origin. `--expect-status`, `--expect-origin yes\|no`, `--proto h1\|h2\|ws\|grpc`. |
| [`hop-trace-ws.sh`](./scripts/hop-trace-ws.sh) | WebSocket handshake trace: the stock config rejects the upgrade (`upgrade_failed`, **403**). Frames are not inspected. |
| [`hop-trace-ws-frames.sh`](./scripts/hop-trace-ws-frames.sh) | WebSocket frame bounds with [`ws-echo.py`](./scripts/ws-echo.py) on :18091: a headers-only upgrade route gets **101**, SQLi-shaped frames are echoed (not inspected), fail-closed holds on the handshake. |
| [`hop-trace-grpc.sh`](./scripts/hop-trace-grpc.sh) | gRPC trace through [`grpc-echo`](./grpc-echo/) on :18090: headers, path and metadata only; protobuf bodies are not inspected. Needs `go` and `grpcurl`. |
| [`partial-honesty.sh`](./scripts/partial-honesty.sh) | BUFFERED_PARTIAL only: SQLi in a small body **403**; SQLi after a 2 MiB pad reaches the origin. |
| [`buffered-oversize.sh`](./scripts/buffered-oversize.sh) | BUFFERED only: a body over a 1 KiB ModSecurity and Envoy limit gets **413**. |
| [`connect-assert.sh`](./scripts/connect-assert.sh) | CONNECT → **403** fast, origin untouched, ext_proc disabled on that route. |
| [`perf.sh`](./scripts/perf.sh) | Latency samples (p50/p99) for allow and deny paths; fails on an empty or partial run. Not an SLO. Results in `demo/.run/perf/`. |
| [`down.sh`](./scripts/down.sh) | Stops everything `up.sh` started. |
| [`origin.py`](./scripts/origin.py), [`daemonize.py`](./scripts/daemonize.py), [`lib.sh`](./scripts/lib.sh) | Demo origin (records every hit with its request id and writes each response in one segment), a detach helper, shared settings. |

Logs, pid files, generated rules and the ModSecurity audit log go to `demo/.run/`.

## Configuration files

| File | Role |
|------|------|
| [`envoy/envoy.yaml`](./envoy/envoy.yaml) | Stock config: listener :18080, `ext_proc` → `modsec_ext_proc` cluster, `failure_mode_allow: false`, `message_timeout: 2s`, BUFFERED bodies, trailers `SEND` (the connector ends a body that trailers follow at the trailers), `request_attributes`, CONNECT answered by Envoy. |
| [`envoy/envoy-streamed.yaml`](./envoy/envoy-streamed.yaml) | STREAMED bodies (`BODY_MODE=STREAMED`). |
| [`envoy/envoy-full-duplex.yaml`](./envoy/envoy-full-duplex.yaml) | FULL_DUPLEX_STREAMED bodies, trailers `SEND`; the connector runs with `--body-reply streamed`. |
| [`envoy/envoy-none.yaml`](./envoy/envoy-none.yaml) | NONE: headers only (`BODY_MODE=NONE`). |
| [`envoy/envoy-buffered-partial.yaml`](./envoy/envoy-buffered-partial.yaml) | BUFFERED_PARTIAL with `per_connection_buffer_limit_bytes: 1048576` (1 MiB). |
| [`envoy/envoy-req-buffered-resp-streamed.yaml`](./envoy/envoy-req-buffered-resp-streamed.yaml), [`envoy/envoy-req-streamed-resp-buffered.yaml`](./envoy/envoy-req-streamed-resp-buffered.yaml) | Different body modes per direction. |
| [`envoy/envoy-trailers.yaml`](./envoy/envoy-trailers.yaml), [`envoy/envoy-streamed-trailers.yaml`](./envoy/envoy-streamed-trailers.yaml) | The stock and STREAMED configs plus HTTP/1 `enable_trailers`, for `trailers.sh`. |
| [`envoy/envoy-buffered-oversize.yaml`](./envoy/envoy-buffered-oversize.yaml) | BUFFERED with a 1 KiB buffer limit, for `buffered-oversize.sh`. |
| [`envoy/envoy-grpc.yaml`](./envoy/envoy-grpc.yaml) | HTTP/2, headers only → `grpc-echo` :18090, for `hop-trace-grpc.sh`. |
| [`envoy/envoy-ws-headers.yaml`](./envoy/envoy-ws-headers.yaml), [`envoy/envoy-ws-buffered.yaml`](./envoy/envoy-ws-buffered.yaml) | WebSocket upgrade with headers only, and with BUFFERED (the hang bound), for `hop-trace-ws-frames.sh`. |
| [`rules/engine.conf`](./rules/engine.conf) | ModSecurity engine directives, based on `modsecurity.conf-recommended`: engine `On`, response body inspection `On`. |
| [`rules/engine-partial-overlay.conf`](./rules/engine-partial-overlay.conf) | BUFFERED_PARTIAL: raises `SecRequestBodyNoFilesLimit` to 2 MiB so ModSecurity does not reject the 1 MiB prefix itself. |
| [`rules/engine-oversize-overlay.conf`](./rules/engine-oversize-overlay.conf) | 1 KiB `SecRequestBodyLimit` with `Reject`, for `buffered-oversize.sh`. |
| [`rules/demo-response.conf`](./rules/demo-response.conf) | One rule that blocks responses containing `DEMO-LEAK-MARKER`, to show the response path. |
| [`rules/demo-grpc.conf`](./rules/demo-grpc.conf) | gRPC trace rule: deny when the metadata `x-demo-grpc-probe: deny` is sent. |
| [`rules/demo-ws.conf`](./rules/demo-ws.conf) | WebSocket trace rule: a phase-1 deny on `UNION` in the URI. |
| [`ftw/`](./ftw/) | go-ftw config, demo test cases, and `envoy-overrides.yaml`: measured Envoy platform differences, like CRS's own nginx overrides. |

## Ports

| Port | Process |
|------|---------|
| 18080 | Envoy listener |
| 18081 | connector gRPC |
| 18082 | connector `/metrics`, `/healthz` |
| 18089 | Envoy admin (`/ready`, `/stats`) |
| 18098 | demo origin |
| 18090 | gRPC echo (`hop-trace-grpc.sh` only) |
| 18091 | WebSocket echo (`hop-trace-ws-frames.sh` only) |

With `DEMO_PORT_BASE=<base>`, Envoy listens on the base, the connector on base + 1, metrics on + 2, Envoy admin on + 9 and the origin on + 18. `up.sh` refuses to start if a port is taken and names the process.

Running beside your own Envoy instead: [`docs/deploy.md`](../docs/deploy.md).
