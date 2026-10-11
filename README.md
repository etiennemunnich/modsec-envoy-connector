# modsec-envoy-connector

Protect HTTP workloads behind [Envoy Proxy](https://www.envoyproxy.io/) with **ModSecurity** and the **OWASP Core Rule Set (CRS)**.

Envoy does not run ModSecurity by itself. This project is a small Rust **External Processing** (`ext_proc`) connector that sits beside Envoy, inspects requests and responses with **libmodsecurity** (and optionally CRS), and tells Envoy to allow or block traffic before it reaches your origin. The connector loads libmodsecurity in-process and calls its C API from Rust.

Pinned versions: Envoy **v1.39.3**, libmodsecurity **v3.0.17**, CRS **v4.30.0** ([`versions.lock.md`](./versions.lock.md)).

**Author:** Etienne Munnich  
**License:** [Apache License 2.0](./LICENSE)

**Repository:** [github.com/etiennemunnich/modsec-envoy-connector](https://github.com/etiennemunnich/modsec-envoy-connector)

Developed as [`envoy-modsec-connex`](https://github.com/etiennemunnich/envoy-modsec-connex); the public project name is **modsec-envoy-connector**.

## Getting started

You need Rust (cargo), `pkg-config`, Python 3, `curl`, and `lsof` on `PATH`. On macOS, `brew install pkg-config`. Use the pin-safe scripts below; a naked `brew install envoy modsecurity` skips the pin check.

```bash
./demo/scripts/install-envoy.sh && export PATH=$HOME/.local/bin:$PATH
./demo/scripts/install-libmodsecurity.sh
./demo/scripts/install-crs.sh
```

From the repo root:

```bash
./demo/scripts/up.sh
./demo/scripts/smoke.sh
```

`up.sh` builds the connector and starts Envoy, the connector, and a tiny origin. Envoy listens on port 18080. By hand:

```bash
curl -i http://127.0.0.1:18080/                                         # 200 from origin
curl -i "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"  # 403 (CRS SQLi)
```

```bash
./demo/scripts/down.sh
```

Default body mode is BUFFERED. Other modes are in [docs/modes](./docs/modes/README.md).

## Docs

| Link | Topic |
|------|--------|
| [Getting started](./docs/modes/getting-started.md) | Same path, plus ports and health checks |
| [Docs index](./docs/modes/README.md) | Install, body modes, fail-closed, testing, architecture |
| [How it works](./docs/how-it-works.md) | Request path and what is inspected |
| [Fail-closed](./docs/fail-closed.md) | When the connector or engine cannot decide |
| [Testing](./docs/testing.md) | How the project is tested |
| [Security scan (ASH)](./docs/ash.md) | Report-only scan and how to run it |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Build from source and contribute |

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0. See [LICENSE](./LICENSE).
