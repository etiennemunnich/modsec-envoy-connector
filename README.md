# envoy-modsec-connex

Protect HTTP workloads behind [Envoy Proxy](https://www.envoyproxy.io/) with **ModSecurity** and the **OWASP Core Rule Set (CRS)**.

Envoy does not run ModSecurity by itself. This project is a small Rust **External Processing** (`ext_proc`) connector that sits beside Envoy, inspects requests and responses with **libmodsecurity** (and optionally CRS), and lets Envoy allow or block traffic before it reaches your origin. The connector loads libmodsecurity in-process and calls its C API from Rust.

```text
Client ──► Envoy ──ext_proc gRPC──► ext-proc-modsec ──C API──► libmodsecurity (+ CRS)
              │
              └──► your origin   (only after the connector says Continue)
```

How the pieces fit, including the request path and what is (and is not) inspected: **[docs/how-it-works.md](./docs/how-it-works.md)**.

**Author:** Etienne Munnich  
**License:** [Apache License 2.0](./LICENSE)

---

## Getting Started (local PoC)

A short proof-of-concept on your machine: install dependencies, bring the demo up, exercise allow/deny, tear it down. The demo scripts build the connector and start Envoy, the connector, and a tiny origin for you.

Pinned versions live in [`versions.lock.md`](./versions.lock.md) (Envoy **v1.39.1**, libmodsecurity **v3.0.16**, CRS **v4.29.0**). Deeper demo detail: [`demo/README.md`](./demo/README.md).

### 1. Prerequisites

You need Rust (cargo), `pkg-config`, Python 3, `curl`, and `lsof` on `PATH`.

**macOS**

```bash
brew install envoy modsecurity pkg-config   # or the install scripts below
./demo/scripts/install-crs.sh               # CRS → demo/.crs
```

**Linux**

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib
./demo/scripts/install-crs.sh
```

`./demo/scripts/install-libmodsecurity.sh` is the cross-platform wrapper (Homebrew on macOS, source build on Linux). `./demo/scripts/install-envoy.sh` checks or installs Envoy at the pin.

### 2. Build and deploy

From the repo root:

```bash
./demo/scripts/up.sh
```

That generates rules under `demo/.run/`, runs `cargo build -p ext-proc-modsec`, and starts:

| Port  | Process |
|-------|---------|
| 18080 | Envoy (app traffic) |
| 18081 | Connector gRPC |
| 18082 | Connector `/metrics` and `/healthz` |
| 18098 | Demo origin |
| 18089 | Envoy admin (`/ready`) |

Optional: `DEMO_CRS=0 ./demo/scripts/up.sh` skips CRS (demo rules only). `BODY_MODE=STREAMED ./demo/scripts/up.sh` uses streamed bodies; `BODY_MODE=BUFFERED_PARTIAL ./demo/scripts/up.sh` uses prefix-only bodies (1 MiB listener buffer — **not** full CRS fidelity; see `demo/scripts/partial-honesty.sh`).

### 3. Exercise

Automated checks:

```bash
./demo/scripts/smoke.sh          # allow / deny / body / response
./demo/scripts/fail-closed.sh    # connector kill → 500, hang → 504, bad rules → 500
```

By hand once it is up:

```bash
curl -i http://127.0.0.1:18080/                                         # 200 from origin
curl -i "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"  # 403 (CRS SQLi)
curl -i -X POST --data "comment=<script>alert(1)</script>" \
     http://127.0.0.1:18080/comment                                     # 403 (CRS XSS, body)
curl -i http://127.0.0.1:18080/leak                                     # 403 (response-body rule)
curl -s http://127.0.0.1:18082/metrics | grep ext_proc_                 # connector counters
```

Follow one request across hops: `./demo/scripts/hop-trace.sh`. Wider failure matrix (HTTP/1.1 + HTTP/2): `./demo/scripts/fail-modes.sh`. CRS regression (needs [go-ftw](https://github.com/coreruleset/go-ftw)): `./demo/scripts/install-go-ftw.sh` then `./demo/scripts/go-ftw.sh smoke`.

### 4. Clean up

```bash
./demo/scripts/down.sh
```

Stops Envoy, the connector, and the demo origin (and clears leftover listeners on the demo ports). Runtime logs and generated rules stay under `demo/.run/` until you delete that directory yourself.

---

## Build and use outside the demo

Build the connector binary alone (libmodsecurity must be discoverable via `pkg-config`):

```bash
cargo build -p ext-proc-modsec --release
```

Run it with your rules, loaded in order (engine directives → CRS setup → rule files):

```bash
./target/release/ext-proc-modsec \
  --listen 0.0.0.0:18081 \
  --metrics-listen 127.0.0.1:18082 \
  --modsec-rules /etc/modsecurity/engine.conf,/etc/crs/crs-setup.conf,/etc/crs/rules.conf
```

Point Envoy's `ext_proc` filter (HTTP/2 cluster) at that listen address, with `failure_mode_allow: false`, before the router. A full filter sketch and more wiring notes are in [`demo/README.md`](./demo/README.md#wiring-your-own-envoy). Contributor build and test gates: [`CONTRIBUTING.md`](./CONTRIBUTING.md).

---

## Docs and entry points

| Link | Topic |
|------|--------|
| [docs/how-it-works.md](./docs/how-it-works.md) | Request path, body modes, fail-closed, what is not inspected |
| [docs/fail-closed.md](./docs/fail-closed.md) | Behaviour when the connector or engine fails |
| [docs/testing.md](./docs/testing.md) | How the project is tested |
| [demo/README.md](./demo/README.md) | Full demo scripts, ports, Envoy configs |
| [demo/scripts/](./demo/scripts/) | `up.sh` / `down.sh` / `smoke.sh` / hop-trace / CRS install |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Building from source and contributing |
| [versions.lock.md](./versions.lock.md) | Envoy, ModSecurity, and CRS versions used in this tree |

---

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0. See [LICENSE](./LICENSE).
