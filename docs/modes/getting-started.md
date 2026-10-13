# Getting started

Bring up the local demo, prove allow/deny, tear it down. Pins: Envoy **v1.39.4**, libmodsecurity **v3.0.17**, CRS **v4.30.0** ([`versions.lock.md`](../../versions.lock.md)).

Dependency detail: [Install / build](./install.md). Suite coverage: [Testing suite](./testing-suite.md).

## 1. Clone

```bash
git clone https://github.com/etiennemunnich/modsec-envoy-connector.git
cd modsec-envoy-connector
```

## 2. Prerequisites (once)

You need Rust (cargo), `pkg-config`, Python 3, `curl`, and `lsof` on `PATH`.

**Pin-safe path (preferred).** Scripts honor [`versions.lock.md`](../../versions.lock.md):

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
./demo/scripts/install-libmodsecurity.sh    # Homebrew under the hood on macOS; source build on Linux
# Linux alternative: PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
#                   export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib
./demo/scripts/install-crs.sh               # CRS → demo/.crs
```

On macOS you also need `pkg-config` (`brew install pkg-config`). Do not lead with a naked `brew install envoy modsecurity`; that skips the pin check. Details: [Install / build](./install.md).

## 3. Up

From the repo root:

```bash
./demo/scripts/up.sh
```

That generates rules under `demo/.run/`, runs `cargo build -p ext-proc-modsec`, and starts Envoy, the connector, and a tiny origin.

| Port  | Process |
|-------|---------|
| 18080 | Envoy (app traffic) |
| 18081 | Connector gRPC |
| 18082 | Connector `/metrics` and `/healthz` |
| 18098 | Demo origin |
| 18089 | Envoy admin (`/ready`) |

Default body mode is **BUFFERED**. Other modes: `BODY_MODE=STREAMED ./demo/scripts/up.sh` (same for `BUFFERED_PARTIAL`, `NONE`, `FULL_DUPLEX_STREAMED`). Skip CRS with `DEMO_CRS=0`. Remap ports with `DEMO_PORT_BASE=18380` if the stock ports are taken.

## 4. Smoke

```bash
./demo/scripts/smoke.sh
```

What “working” looks like:

| Check | Expected |
|-------|----------|
| Benign GET/POST/JSON through Envoy | **200**, origin receives the request |
| SQLi / XSS / traversal in the URL | **403**, origin **untouched** |
| SQLi / XSS in form / JSON body | **403**, origin **untouched** |
| Response-body leak marker | **403** |
| Connector ready | `curl -sf http://127.0.0.1:18082/healthz` succeeds |
| Envoy ready | `curl -sf http://127.0.0.1:18089/ready` succeeds |

By hand once it is up:

```bash
curl -i http://127.0.0.1:18080/                                         # 200
curl -i "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"  # 403
curl -i -X POST --data "comment=<script>alert(1)</script>" \
     http://127.0.0.1:18080/comment                                     # 403
curl -i http://127.0.0.1:18080/leak                                     # 403
curl -s http://127.0.0.1:18082/metrics | grep ext_proc_
```

Optional next steps after smoke is green:

```bash
./demo/scripts/fail-closed.sh            # kill → 500; stall past message_timeout → 504 (skipped under FULL_DUPLEX); bad rules → 500
./demo/scripts/install-go-ftw.sh && ./demo/scripts/go-ftw.sh smoke
./demo/scripts/hop-trace.sh
```

Early-tester sign-off (smoke + fail-closed + checklist): [UAT](./uat.md).

## 5. Down

```bash
./demo/scripts/down.sh
```

Stops Envoy, the connector, and the origin. Logs and generated rules stay under `demo/.run/` until you delete that directory.

## Path sketch

```text
Client ──► Envoy :18080 ──ext_proc gRPC──► ext-proc-modsec :18081 ──C API──► libmodsecurity (+ CRS)
              │
              └──► demo origin :18098   (only after Continue)
```

More detail: [How it works](./how-it-works.md) · [demo/README](../../demo/README.md) · [body modes](./README.md#mode-comparison).
