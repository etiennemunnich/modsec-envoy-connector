# Run it beside your own Envoy

How to run `ext-proc-modsec` next to an Envoy you operate: get the connector, write the rules entry file, start it, add the `ext_proc` filter, and check that it fails closed. The local demo ([getting-started.md](./getting-started.md)) is the same wiring with every piece on one host.

Tested versions are in [`versions.lock.md`](../versions.lock.md): Envoy v1.39.4, libmodsecurity v3.0.17, CRS v4.30.0. Other versions are tested weekly ([testing.md](./testing.md#workflows)) but are not supported.

Access: while the repository is private, the image and release assets need a GitHub account with read access. `gh auth login` covers the tarball. For the image, log in with a token that has `read:packages`: `echo "$TOKEN" | docker login ghcr.io -u <github-user> --password-stdin`.

## 1. Get the connector

### Release tarball

Linux x86_64 and aarch64, from `v0.1.0-alpha.2` on (do not use `v0.1.0-alpha.1`, see [Known issues](#known-issues)). The tarball holds `bin/ext-proc-modsec`, `lib/libmodsecurity.so*`, `LICENSE`, `NOTICE` and `versions.lock.md`. It needs Ubuntu 24.04's runtime libraries.

```bash
VER=v0.1.0-alpha.2 ARCH=x86_64          # or aarch64
gh release download "$VER" -R etiennemunnich/modsec-envoy-connector -p "ext-proc-modsec-$VER-linux-$ARCH.tar.gz*"
sha256sum -c "ext-proc-modsec-$VER-linux-$ARCH.tar.gz.sha256"
tar xzf "ext-proc-modsec-$VER-linux-$ARCH.tar.gz"
sudo apt-get install -y libpcre2-8-0 libxml2 libyajl2 libcurl4t64 libgeoip1t64 liblmdb0
DIR="$PWD/ext-proc-modsec-$VER-linux-$ARCH"
"$DIR/bin/ext-proc-modsec" --version
```

The binary finds the bundled `lib/libmodsecurity.so` through its RUNPATH `$ORIGIN/../lib`: keep `bin/` and `lib/` side by side, and no `LD_LIBRARY_PATH` is needed.

### Container image

`ghcr.io/etiennemunnich/modsec-envoy-connector:<tag>` for `linux/amd64` and `linux/arm64`. The image:

- runs as UID 65532, so `SecTmpDir`, `SecDataDir` and `SecAuditLog` must point at writable paths (for example `/tmp`);
- ships **no rules and no CRS**: mount them;
- starts with `--listen 0.0.0.0:18081 --metrics-listen 0.0.0.0:18082` inside the container, so publish the ports to loopback only.

```bash
docker run --rm -p 127.0.0.1:18081:18081 -p 127.0.0.1:18082:18082 \
  -v /etc/modsecurity:/etc/modsecurity:ro -v /etc/crs:/etc/crs:ro \
  ghcr.io/etiennemunnich/modsec-envoy-connector:v0.1.0-alpha.2 \
  --modsec-rules /etc/modsecurity/main.conf
```

The release workflow builds the image and runs `--version` in it. The `docker run` above is not exercised by this repository's tests.

### From source

On Linux or macOS. libmodsecurity **3.0.13 or newer** must be visible to `pkg-config modsecurity`; only v3.0.17 is tested on every pull request. `./demo/scripts/install-libmodsecurity.sh` installs the pinned version (macOS: Homebrew; Linux: source build into `~/.local`).

```bash
export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib   # Linux, after install-libmodsecurity.sh
cargo build --release --locked -p ext-proc-modsec
./target/release/ext-proc-modsec --version
```

`MODSECURITY_LIB_DIR=<dir>` skips `pkg-config` and its version check. At run time the library must be on the loader path.

## 2. Write the rules entry file

`--modsec-rules` takes files and loads them in order; it does not expand globs. libmodsecurity does expand globs in `Include`, so write one entry file that includes everything. This is what `demo/scripts/up.sh` generates:

```apache
# /etc/modsecurity/main.conf
Include /etc/modsecurity/engine.conf
SecTmpDir  /var/lib/modsecurity
SecDataDir /var/lib/modsecurity
SecAuditEngine RelevantOnly
SecAuditLogRelevantStatus "^(?:5|4(?!04))"
SecAuditLogParts ABIJDEFHZ
SecAuditLogFormat JSON
SecAuditLogType Serial
SecAuditLog /var/log/modsecurity/audit.log
Include /etc/crs/crs-setup.conf
Include /etc/crs/rules/*.conf
```

- `engine.conf` is a copy of [`demo/rules/engine.conf`](../demo/rules/engine.conf): engine `On`, request and response body access `On`, body limits (`SecRequestBodyNoFilesLimit` 128 KiB, `SecRequestBodyLimit` 12.5 MiB, `SecResponseBodyLimit` 512 KiB). Review the limits and audit parts for your traffic and PII rules.
- `/etc/crs` is a CRS checkout (`CRS_DIR=/etc/crs ./demo/scripts/install-crs.sh`, as a user who can write there, fetches the pinned tag) with `crs-setup.conf` copied from `crs-setup.conf.example`.
- The `SecTmpDir`, `SecDataDir` and audit-log directories must exist and be writable by the connector's user.

If a file is missing, a rule does not parse, or the files define no rules at all, the connector exits before it listens, and Envoy answers every request with **500**. Rules that leave `SecRuleEngine` at `DetectionOnly` or `Off` load, but `/healthz` answers **503** ([Health and metrics](#health-and-metrics)).

## 3. Start the connector

```bash
ext-proc-modsec --listen 127.0.0.1:18081 --metrics-listen 127.0.0.1:18082 \
  --modsec-rules /etc/modsecurity/main.conf
```

| Flag | Env | Default | Notes |
|------|-----|---------|-------|
| `--listen` | `EXT_PROC_LISTEN` | `127.0.0.1:18081` | gRPC address for Envoy's `ext_proc` cluster (HTTP/2) |
| `--metrics-listen` | `EXT_PROC_METRICS_LISTEN` | `127.0.0.1:18082` | `GET /metrics`, `GET /healthz` |
| `--modsec-rules` | `MODSEC_RULES` | required | files in load order; repeatable or comma-separated. Startup fails if they define 0 rules; per-file and total rule counts are logged |
| `--body-reply` | `EXT_PROC_BODY_REPLY` | `common` | a consistency check: the connector takes each direction's body mode from Envoy's `protocol_config`. `streamed` when a direction is FULL_DUPLEX_STREAMED, `common` otherwise; a stream that disagrees fails closed (**500**) |
| `--max-grpc-message-bytes` | `EXT_PROC_MAX_GRPC_MESSAGE_BYTES` | `4194304` (4 MiB) | largest message read from Envoy. A larger one ends the stream with gRPC `INTERNAL`, and Envoy answers **500**. If you raise Envoy's `per_connection_buffer_limit_bytes` for BUFFERED bodies, keep this above it plus the header block. Replies may be up to 64 KiB larger |
| `--max-held-body-bytes` | `EXT_PROC_MAX_HELD_BODY_BYTES` | = `--max-grpc-message-bytes` | FULL_DUPLEX_STREAMED only: the body held per direction until ModSecurity allows it. Over it, **500** and nothing is released. Must not exceed `--max-grpc-message-bytes` |
| `--stream-idle-timeout` | `EXT_PROC_STREAM_IDLE_TIMEOUT` | `300` (s) | longest wait for Envoy's next message before the verdict; past it **504** |
| `--duplex-idle-timeout` | `EXT_PROC_DUPLEX_IDLE_TIMEOUT` | `30` (s) | FULL_DUPLEX_STREAMED: longest gap between Envoy's messages while a body is held; past it **504** |
| `--duplex-total-timeout` | `EXT_PROC_DUPLEX_TOTAL_TIMEOUT` | `300` (s) | FULL_DUPLEX_STREAMED: longest a stream may run before its verdict; past it **504** |
| `--max-concurrent-streams` | `EXT_PROC_MAX_CONCURRENT_STREAMS` | `1024` | HTTP/2 concurrent streams per Envoy connection |
| `--http2-keepalive-interval` / `--http2-keepalive-timeout` | `EXT_PROC_HTTP2_KEEPALIVE_INTERVAL` / `EXT_PROC_HTTP2_KEEPALIVE_TIMEOUT` | `30` / `10` (s) | HTTP/2 PING on an idle Envoy connection; unanswered, the connection is closed |
| `--allow-detection-only` | `EXT_PROC_ALLOW_DETECTION_ONLY=1` | off | lets `/healthz` report ready when the rules leave `SecRuleEngine` at `DetectionOnly` or `Off` |

The 504s from the connector's own timeouts carry `%RESPONSE_CODE_DETAILS%` `modsec_stream_timeout`.

Logging: `RUST_LOG=<level>[,<target>=<level>…]`, default `info`, one line per event on stderr. The WARN line for a rule intervention carries the transaction id, `request_id`, rule id and a truncated `msg`; the full ModSecurity log line is at `debug`, under the target `modsecurity` like the rest of libmodsecurity's messages. The transaction id is generated by the connector; Envoy's `x-request-id` is logged next to it.

**Keep both listeners on loopback** (or a pod- or node-local address). The gRPC listener is plaintext and unauthenticated, has no TLS option, and anyone who can reach it can ask it to judge traffic. Do not bind `0.0.0.0` on a shared network, and do not expose port 18081 or 18082 beyond Envoy and your metrics scraper.

## 4. Add the filter to Envoy

A complete static config for one listener. Merge the `ext_proc` filter, the CONNECT route and the `modsec_ext_proc` cluster into your own config; `your_origin` stands for your upstream.

```yaml
static_resources:
  listeners:
  - name: ingress
    address:
      socket_address: { address: 0.0.0.0, port_value: 8000 }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          generate_request_id: true
          http_protocol_options:
            allow_custom_methods: true      # let CRS rule 911100 judge non-standard methods
            enable_trailers: true           # HTTP/1 trailers reach ext_proc (see trailer modes below)
          route_config:
            virtual_hosts:
            - name: app
              domains: ["*"]
              routes:
              # A CONNECT tunnel never ends its request body; answer it here.
              - match: { connect_matcher: {} }
                direct_response: { status: 403 }
                typed_per_filter_config:
                  envoy.filters.http.ext_proc:
                    "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExtProcPerRoute
                    disabled: true
              - match: { prefix: "/" }
                route: { cluster: your_origin }
          http_filters:
          - name: envoy.filters.http.ext_proc          # must sit before the router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.ext_proc.v3.ExternalProcessor
              stat_prefix: modsec_ext_proc
              grpc_service:
                envoy_grpc: { cluster_name: modsec_ext_proc }
              failure_mode_allow: false              # never true on an enforcing filter
              message_timeout: 2s                    # hung connector -> 504 (not under FULL_DUPLEX_STREAMED)
              processing_mode:
                request_header_mode: SEND
                response_header_mode: SEND
                request_body_mode: BUFFERED          # see the body-mode table
                response_body_mode: BUFFERED
                request_trailer_mode: SEND           # required with any body mode but NONE
                response_trailer_mode: SEND
              # Real client and server addresses for ModSecurity REMOTE_ADDR and friends.
              request_attributes: [source.address, source.port, destination.address, destination.port, request.protocol]
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router
  clusters:
  - name: modsec_ext_proc
    type: STATIC
    connect_timeout: 1s
    typed_extension_protocol_options:
      envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
        "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
        explicit_http_config: { http2_protocol_options: {} }   # gRPC needs HTTP/2
    load_assignment:
      cluster_name: modsec_ext_proc
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 18081 } } }
  - name: your_origin
    type: STATIC
    connect_timeout: 1s
    load_assignment:
      cluster_name: your_origin
      endpoints:
      - lb_endpoints:
        - endpoint: { address: { socket_address: { address: 127.0.0.1, port_value: 8080 } } }
```

What breaks if you leave something out:

| Missing | Effect |
|---------|--------|
| `http2_protocol_options` on the cluster | the gRPC side-call fails: every request **500** |
| `failure_mode_allow: false` | nothing: `false` is Envoy's default, written out so nobody flips it. With `true`, a dead or failing connector lets traffic through |
| the CONNECT route | under BUFFERED a CONNECT request waits for a body end that never comes |
| `request_attributes` | ModSecurity sees `127.0.0.1` as `REMOTE_ADDR` and `HTTP/1.1` as the protocol (the connector logs `conn_source=fallback`), so IP-based rules misjudge |
| trailer modes `SEND` (with any body mode but NONE) | Envoy forwards the request to origin before the body phase finishes (`SKIP` is not fail-closed). Body-mode configs must use `SEND` |
| `stat_prefix: modsec_ext_proc` | the stat names in [Health and metrics](#health-and-metrics) change |

Do not use BUFFERED on WebSocket upgrade routes: the upgrade waits for a body end that never comes. WebSocket frames are not inspected in any mode.

## 5. Pick a body mode

Envoy's `processing_mode` and the connector's `--body-reply` must agree. Details and diagrams: [body-modes.md](./body-modes.md).

| Intent | `request_body_mode` / `response_body_mode` | Trailer modes | `--body-reply` | Hung connector | Caveat |
|--------|--------------------------------------------|---------------|----------------|----------------|--------|
| Default: whole body inspected before it moves on | `BUFFERED` | `SEND` | `common` | **504** after `message_timeout` | bodies over Envoy's buffer limit (`per_connection_buffer_limit_bytes`, default 1 MiB) get **413** from Envoy |
| Streaming | `STREAMED` | `SEND` | `common` | **504** | early request chunks can reach the origin before a body deny; a response-body deny after the response headers resets the client stream instead of answering 403 ([body-modes.md](./body-modes.md#streamed)) |
| Streaming without early release | `FULL_DUPLEX_STREAMED` | `SEND` | `streamed` | **not bounded by `message_timeout`** ([below](#full_duplex_streamed-timeouts)) | the connector holds each body in memory until ModSecurity allows, up to `--max-held-body-bytes` (4 MiB); over it, **500** |
| Headers only | `NONE` | `SKIP` | `common` | **504** | bodies are never sent to the connector or inspected |
| Prefix only | `BUFFERED_PARTIAL` | `SEND` | `common` | **504** | only the body prefix up to the buffer limit is inspected; bytes past it reach the origin uninspected; not full CRS |

The connector reads the body modes from the `protocol_config` Envoy sends on each stream; a stream without it, or with `--body-reply` set for the other reply shape, fails closed with **500**.

### FULL_DUPLEX_STREAMED timeouts

Envoy does not apply `message_timeout` under FULL_DUPLEX_STREAMED. The connector has its own deadlines for the other direction: if Envoy goes silent for `--duplex-idle-timeout` (30 s) while a body is held, or the stream runs past `--duplex-total-timeout` (300 s) without a verdict, it answers **504**. A frozen connector cannot fire them, so if the connector itself stalls the request waits until another Envoy timeout fires: the route `timeout`, or the connection manager's `request_timeout` / `stream_idle_timeout`. Set those explicitly on duplex routes. This repository does not test what the client receives in that case; the origin is not contacted while the connector holds the body.

## 6. Check it

With the connector and Envoy running:

```bash
curl -sf http://127.0.0.1:18082/healthz && echo ready               # connector
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/      # 200 from your origin
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8000/search?q=1'%20UNION%20SELECT%201,2--"   # 403
kill <connector pid>
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8000/      # 500, and your origin saw nothing
```

What each status means: [fail-closed.md](./fail-closed.md) and [troubleshooting.md](./troubleshooting.md).

## Health and metrics

- **Readiness and liveness:** `GET /healthz` on `--metrics-listen` (HTTP/1.1) returns 503 unless the rules leave `SecRuleEngine On` (`--allow-detection-only` accepts `DetectionOnly` and `Off`). Otherwise it returns 200 only if, within 2 s, the gRPC listener completes an HTTP/2 handshake and a headers-only probe through a fresh in-process exchange answers Continue; else 503. Every answer ends with `engine_mode=` and `rules=` lines. Probes do not count in the `ext_proc_*` metrics and log at `debug`, but each one is a real ModSecurity transaction: with `SecAuditEngine On` (not `RelevantOnly`) every probe writes an audit record. In Kubernetes, use an `httpGet` probe on port 18082. The gRPC port serves only `ExternalProcessor/Process`; gRPC health checking is not implemented.
- **Metrics:** `GET /metrics` (Prometheus): `ext_proc_requests_total`, `ext_proc_allow_total`, `ext_proc_deny_total`, `ext_proc_fail_closed_total`, `ext_proc_stream_errors_total` (streams the connector ended with a non-OK gRPC status: an unreadable or oversized message, or Envoy closing with a body phase open), `ext_proc_local_reply_passthrough_total`, body-byte counters and per-phase latency histograms.
- **Envoy:** `%RESPONSE_CODE_DETAILS%` in the access log shows `modsecurity_intervention`, `modsec_fail_closed` or `ext_proc_error_*`. Watch `http.<stat_prefix>.ext_proc.modsec_ext_proc.*`: `streams_failed`, `message_timeouts`, and `failure_mode_allowed`, which must stay 0.
- **Logs:** one line per phase with `request_id`, `phase`, `action` (`allow`, `deny`, `redirect`, `drop`, `fail_closed`), `latency_ms`, `body_bytes`. Rule ids and matched data appear in the connector log and the ModSecurity audit log, never in the response to the client.

## Sizing

Not measured beyond the latency samples of `demo/scripts/perf.sh`. ModSecurity work runs on the tokio worker threads, so concurrent inspections scale with CPU count; the logging phase (the audit-log write when a transaction ends) runs on tokio's blocking pool, so a deny does not wait for it. BUFFERED holds each whole body in Envoy and again in the engine. FULL_DUPLEX_STREAMED holds each body in the connector, up to `--max-held-body-bytes` per direction, so the worst case is about two times that limit per concurrent stream (`--max-concurrent-streams` per Envoy connection).

## Known issues

Open on `main`; see [`CHANGELOG.md`](../CHANGELOG.md).

- **Do not use `v0.1.0-alpha.1`.** It ends the gRPC stream with OK when it cannot read a message (for example a BUFFERED body over 4 MiB), and with trailer mode `SKIP` it never inspects a body that trailers follow. In both cases Envoy forwards the request to the origin uninspected. Both are fixed from `v0.1.0-alpha.2` on.
- **STREAMED responses:** Envoy forwards the response headers as soon as the connector answers them, so a response-body deny on a later chunk resets the client stream instead of answering 403; bytes already sent are not recalled. Use BUFFERED for the response when phase-4 blocking must answer 403.
- **Trailer values** are never passed to ModSecurity; trailers only end the body phase. Trailer mode `SKIP` with a body mode lets the request reach origin; set both trailer modes to `SEND` (see the table in [section 4](#4-add-the-filter-to-envoy)).
- **BUFFERED_PARTIAL** inspects only the prefix up to Envoy's buffer limit. **NONE** never inspects bodies.
- HTTP/3 and WebSocket frames are not inspected.
- Envoy strips non-URI `Referer` and hop-by-hop `Connection` before `ext_proc`; those CRS signals are weaker than typical nginx+ModSec. Limits and custom-rule guidance: [crs-and-envoy-limits.md](./crs-and-envoy-limits.md).
