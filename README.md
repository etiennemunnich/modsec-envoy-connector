# modsec-envoy-connector

Protect HTTP workloads behind [Envoy Proxy](https://www.envoyproxy.io/) with **ModSecurity** and the **OWASP Core Rule Set (CRS)**.

Envoy does not run ModSecurity by itself. This project is a small Rust **External Processing** (`ext_proc`) connector that sits beside Envoy, inspects requests and responses with **libmodsecurity** (and optionally CRS) in-process, and tells Envoy to allow or block. Envoy alone forwards traffic to your origin, and only after the connector allows it.

**Status:** early testing only; not a production release. Current pre-release: `v0.1.0-alpha.2`. Do not use `v0.1.0-alpha.1`: it can forward uninspected requests (a body over 4 MiB, or a body that ends in trailers). Open issues and release notes: [`CHANGELOG.md`](./CHANGELOG.md). Tested with Envoy v1.39.4, libmodsecurity v3.0.17 and CRS v4.30.0 ([`versions.lock.md`](./versions.lock.md)).

## How it decides

- **Allow:** Envoy forwards the request to the origin.
- **Rule deny:** **403** (or the rule's 4xx/5xx status); the origin is not contacted.
- **Connector down, or an engine error:** **500**; the origin is not contacted.
- **Connector hung:** **504** after Envoy's `message_timeout` (not under the FULL_DUPLEX_STREAMED body mode).

Details: [fail-closed](./docs/fail-closed.md).

## Try it locally

Prerequisites: on **macOS**, Xcode Command Line Tools, [Homebrew](https://brew.sh) and [rustup](https://rustup.rs); on **Linux** (tested on Ubuntu 24.04, with `sudo`), rustup, `git`, `curl`, `python3` and `lsof`. The scripts install Envoy, libmodsecurity (a source build on Linux) and CRS at the pinned versions, and stop if what they find is something else.

```bash
git clone https://github.com/etiennemunnich/modsec-envoy-connector.git
cd modsec-envoy-connector
export PATH="$HOME/.local/bin:$PATH"
./demo/scripts/install-envoy.sh
./demo/scripts/install-libmodsecurity.sh
./demo/scripts/install-crs.sh
./demo/scripts/up.sh                # Envoy :18080, connector, a small origin; BUFFERED body mode
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18080/                                          # 200
curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"   # 403
./demo/scripts/smoke.sh             # allow and deny checks
./demo/scripts/fail-closed.sh       # kill → 500, hang → 504, bad rules → 500
./demo/scripts/down.sh
```

Full walkthrough, other body modes and the early-tester checklist: [Getting started](./docs/getting-started.md).

## Run it beside your own Envoy

1. Get the connector: pull `ghcr.io/etiennemunnich/modsec-envoy-connector:v0.1.0-alpha.2` (multi-arch; pin by digest in [`versions.lock.md`](./versions.lock.md)), or a Linux release tarball, or `cargo build --release -p ext-proc-modsec`. Details and auth while the package is private: [Deploy](./docs/deploy.md).
2. Write one rules entry file, for example `/etc/modsecurity/main.conf`, that `Include`s the engine settings, `crs-setup.conf` and `rules/*.conf`.
3. Start it on loopback: `ext-proc-modsec --listen 127.0.0.1:18081 --metrics-listen 127.0.0.1:18082 --modsec-rules /etc/modsecurity/main.conf` (or the equivalent `docker run` from Deploy).
4. Add the `ext_proc` filter before the router, with an HTTP/2 cluster to the connector and `failure_mode_allow: false`. With any body mode other than NONE, also set `request_trailer_mode: SEND` and `response_trailer_mode: SEND`; `SKIP` lets the request reach origin before the body phase runs.
5. Check: `/healthz` is 200, a SQLi gets 403, and with the connector stopped requests get 500.

Complete Envoy config, body-mode settings, timeouts, health checks and security notes: [Deploy](./docs/deploy.md).

## What is not inspected

| Surface | Status |
|---------|--------|
| request and response bodies under the NONE body mode | not sent to the connector |
| body bytes past the limit under BUFFERED_PARTIAL | not inspected |
| HTTP/3 | not configured or tested |
| WebSocket frames | not inspected (the upgrade handshake can be) |
| gRPC message bodies | not inspected (headers and metadata are) |
| trailer values | not inspected |
| Non-URI `Referer`, hop-by-hop `Connection` | Envoy strips before the connector; see [CRS and Envoy limits](./docs/crs-and-envoy-limits.md) |

Not every CRS or custom SecRule works like nginx+ModSecurity. Limits (signal loss vs early reject vs FTW quirk): [CRS and Envoy limits](./docs/crs-and-envoy-limits.md).

## Docs

| Page | Topic |
|------|-------|
| [Getting started](./docs/getting-started.md) | local demo, step by step, and the early-tester checklist |
| [Deploy](./docs/deploy.md) | running the connector beside your own Envoy |
| [How it works](./docs/how-it-works.md) | request path and what the client sees |
| [CRS and Envoy limits](./docs/crs-and-envoy-limits.md) | what CRS/custom rules cannot fully do behind Envoy |
| [Body modes](./docs/body-modes.md) | what each Envoy body mode inspects, and when |
| [Fail-closed](./docs/fail-closed.md) | what happens when the connector or engine cannot decide |
| [Troubleshooting](./docs/troubleshooting.md) | status codes, install errors, logs |
| [Testing](./docs/testing.md) | what is tested, where, and how to run it |

Bugs, questions and alpha security reports: [issue templates](https://github.com/etiennemunnich/modsec-envoy-connector/issues/new/choose) ([SECURITY.md](./SECURITY.md)). Contributing: [CONTRIBUTING.md](./CONTRIBUTING.md).

Copyright © 2026 Etienne Munnich. Licensed under the [Apache License 2.0](./LICENSE).
