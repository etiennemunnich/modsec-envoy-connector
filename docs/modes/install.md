# Install / build

How to get dependencies, build the connector, and run the Envoy demo. Pins live in [`versions.lock.md`](../../versions.lock.md): Envoy **v1.39.3**, libmodsecurity **v3.0.17**, CRS **v4.30.0**.

Quick path: [Getting started](./getting-started.md). Contributor gates: [`CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Prerequisites

| Need | Why |
|------|-----|
| Rust (cargo), toolchain from `rust-toolchain.toml` | Build `ext-proc-modsec` (MSRV 1.88+) |
| `pkg-config` + libmodsecurity at the pin | Linked in-process; `pkg-config modsecurity` must succeed (or set `MODSECURITY_LIB_DIR`) |
| Envoy at the pin | Live demo / e2e |
| Python 3, `curl`, `lsof` | Demo origin, health waits, port checks |
| CRS clone (optional but default) | `demo/scripts/install-crs.sh` → `demo/.crs` |
| go-ftw (optional) | CRS regression: `demo/scripts/install-go-ftw.sh` |

### Pin-safe path (preferred)

Scripts honor [`versions.lock.md`](../../versions.lock.md). Use these first, not a naked brew install.

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
./demo/scripts/install-libmodsecurity.sh
./demo/scripts/install-crs.sh
```

| Platform | What the scripts do |
|----------|---------------------|
| **macOS** | `install-libmodsecurity.sh` may use Homebrew under the hood at the pin; also need `brew install pkg-config` |
| **Linux** | Or `PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh` then `export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib` |

Do not lead with `brew install envoy modsecurity`. That skips the pin check those scripts enforce.

## Build the connector

Debug (what `up.sh` uses):

```bash
cargo build -p ext-proc-modsec
```

Release:

```bash
cargo build -p ext-proc-modsec --release
```

Run alone (libmodsecurity must be discoverable):

```bash
./target/release/ext-proc-modsec \
  --listen 0.0.0.0:18081 \
  --metrics-listen 127.0.0.1:18082 \
  --modsec-rules /etc/modsecurity/engine.conf,/etc/crs/crs-setup.conf,/etc/crs/rules.conf
```

Flags (also as env vars):

| Flag | Env | Default | Notes |
|------|-----|---------|-------|
| `--listen` | `EXT_PROC_LISTEN` | `127.0.0.1:18081` | Envoy `ext_proc` gRPC target |
| `--metrics-listen` | `EXT_PROC_METRICS_LISTEN` | `127.0.0.1:18082` | `/metrics`, `/healthz` |
| `--modsec-rules` | `MODSEC_RULES` | *(required)* | Files in load order (repeatable or comma-separated). Files that define **0** rules in total → connector exits |
| `--body-reply` | `EXT_PROC_BODY_REPLY` | `common` | `common` for BUFFERED / STREAMED / PARTIAL / NONE; `streamed` for **FULL_DUPLEX_STREAMED** (`StreamedBodyResponse`) |
| `--max-grpc-message-bytes` | `EXT_PROC_MAX_GRPC_MESSAGE_BYTES` | `4194304` (4 MiB) | Largest ext_proc message the connector reads. A larger one (e.g. a BUFFERED body above it) aborts the stream with `INTERNAL` → Envoy **500**. Raise it with Envoy's buffer limit when large bodies must be inspected |
| `--max-held-body-bytes` | `EXT_PROC_MAX_HELD_BODY_BYTES` | = `--max-grpc-message-bytes` | FULL_DUPLEX only: body bytes held per direction until the verdict. Over the cap → **500**. Must not exceed `--max-grpc-message-bytes` (the release is one message) |

Logging: `RUST_LOG=…` (default `info`).

## Demo stack (host processes)

The product PoC is **not** a compose lab. `./demo/scripts/up.sh` builds the connector and starts three host processes: demo origin, connector, Envoy. See [`demo/README.md`](../../demo/README.md).

```bash
./demo/scripts/up.sh
./demo/scripts/smoke.sh
./demo/scripts/down.sh
```

### Knobs that matter

| Knob | Effect |
|------|--------|
| `BODY_MODE` | Envoy YAML + connector `--body-reply`. Default `BUFFERED`. Also: `STREAMED`, `BUFFERED_PARTIAL`, `NONE`, `FULL_DUPLEX_STREAMED`, asymmetric `REQ_BUFFERED_RESP_STREAMED` / `REQ_STREAMED_RESP_BUFFERED`. Written to `demo/.run/body_mode` so later scripts match. |
| `DEMO_CRS=0` | Skip CRS; engine + demo rules only |
| `DEMO_PORT_BASE` | Remap ports (default `18080`); e.g. `18380` avoids collisions |
| `CRS_DIR` / `CRS_TAG` | Alternate CRS tree / tag for `install-crs.sh` |
| `ENVOY_VERSION` | Alternate Envoy for `install-envoy.sh` |
| Envoy `failure_mode_allow` | Must stay **`false`** on enforcement configs |
| Envoy `message_timeout` | Stock BUFFERED/STREAMED demo uses `2s` (stall past timeout → Envoy **504**). Envoy turns it **off** under `FULL_DUPLEX_STREAMED`, so the stall→504 fail-closed cell is skipped. |
| Envoy body / trailer modes | Must match connector `--body-reply` and the mode page you intend ([comparison](./README.md#mode-comparison)) |

### Release container image

CI’s `release` workflow builds Linux tarballs (binary + bundled `libmodsecurity.so`) and a multi-arch GHCR image from [`packaging/Dockerfile`](../../packaging/Dockerfile) (Ubuntu 24.04 runtime libs). That image is for deploying the connector next to your Envoy. It is not a substitute for `demo/scripts/up.sh`.

## Wire your own Envoy

Point an HTTP/2 cluster at `--listen`, put `ext_proc` before the router, keep `failure_mode_allow: false`. Sketch and full notes: [`demo/README.md`](../../demo/README.md#wiring-your-own-envoy). Body-mode semantics: [Architecture](./architecture.md) and the per-mode pages.
