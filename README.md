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

Pinned versions live in [`versions.lock.md`](./versions.lock.md) (Envoy **v1.39.1**, libmodsecurity **v3.0.17**, CRS **v4.30.0**). Deeper demo detail: [`demo/README.md`](./demo/README.md).

### 1. Prerequisites

You need Rust (cargo), `pkg-config`, Python 3, `curl`, and `lsof` on `PATH`.

**Pin-safe path (preferred).** Install scripts honor [`versions.lock.md`](./versions.lock.md):

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
./demo/scripts/install-libmodsecurity.sh    # Homebrew under the hood on macOS; source build on Linux
# Linux alternative: PREFIX=$HOME/.local ./scripts/install-libmodsecurity-ubuntu.sh
#                   export PKG_CONFIG_PATH=$HOME/.local/lib/pkgconfig LD_LIBRARY_PATH=$HOME/.local/lib
./demo/scripts/install-crs.sh               # CRS → demo/.crs
```

On macOS you also need `pkg-config` (`brew install pkg-config`). Do not lead with a naked `brew install envoy modsecurity`; that skips the pin check.

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

Optional: `DEMO_CRS=0 ./demo/scripts/up.sh` skips CRS (demo rules only). `BODY_MODE=STREAMED ./demo/scripts/up.sh` uses streamed bodies; `BODY_MODE=BUFFERED_PARTIAL ./demo/scripts/up.sh` uses prefix-only bodies (1 MiB listener buffer; **not** full CRS fidelity; see `demo/scripts/partial-honesty.sh`); `BODY_MODE=NONE ./demo/scripts/up.sh` is headers-only (body CRS n/a; body attacks reach origin); `BODY_MODE=FULL_DUPLEX_STREAMED ./demo/scripts/up.sh` uses full-duplex streamed bodies (`StreamedBodyResponse`, trailer SEND; Envoy turns `message_timeout` off, so the stall→504 fail-closed cell does not apply).

### 3. Exercise

Automated checks:

```bash
./demo/scripts/smoke.sh          # allow / deny / body / response
./demo/scripts/fail-closed.sh    # connector kill → 500; stall past message_timeout → 504; bad rules → 500
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

## Security scan (ASH)

CI runs [AWS Automated Security Helper](https://github.com/awslabs/automated-security-helper) **v3.7.1** in local mode on pull requests and on `main` (`.github/workflows/ash.yml`). Config is [`.ash/.ash.yaml`](./.ash/.ash.yaml). The severity threshold is `MEDIUM`.

The job is report-only. `fail_on_findings` is `false`, so findings are uploaded as the `ash-results` artifact and do not fail the build. A scan of the current tree already reports actionable findings in existing files. Set `fail_on_findings: true` in `.ash/.ash.yaml` when those should fail the job.

Local mode runs the scanners ASH installs itself (Bandit, Checkov, Semgrep, detect-secrets, npm-audit). Grype, Syft, cfn-nag, cdk-nag, and OpenGrep are skipped unless they are already on `PATH`.

To run the same scan locally (Python 3.10+, [uv](https://docs.astral.sh/uv/)):

```bash
alias ash="uvx git+https://github.com/awslabs/automated-security-helper.git@v3.7.1"
ash --mode local
```

`pipx install` or `pip install` of that same git URL also works. Reports are written to `.ash/ash_output/` (gitignored). `ash config validate` checks the config file.

---

## Docs and entry points

| Link | Topic |
|------|--------|
| [docs/how-it-works.md](./docs/how-it-works.md) | Request path, body modes, fail-closed, what is not inspected |
| [docs/modes/](./docs/modes/) | Pages guide: getting started, install, product path, testing, body modes |
| [docs/fail-closed.md](./docs/fail-closed.md) | Behaviour when the connector or engine fails |
| [docs/testing.md](./docs/testing.md) | How the project is tested |
| [demo/README.md](./demo/README.md) | Full demo scripts, ports, Envoy configs |
| [demo/scripts/](./demo/scripts/) | `up.sh` / `down.sh` / `smoke.sh` / hop-trace / CRS install |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Building from source and contributing |
| [versions.lock.md](./versions.lock.md) | Envoy, ModSecurity, and CRS versions used in this tree |

---

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0. See [LICENSE](./LICENSE).
