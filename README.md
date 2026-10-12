# modsec-envoy-connector

Protect HTTP workloads behind [Envoy Proxy](https://www.envoyproxy.io/) with **ModSecurity** and the **OWASP Core Rule Set (CRS)**.

Envoy does not run ModSecurity by itself. This project is a small Rust **External Processing** (`ext_proc`) connector that sits beside Envoy, inspects requests and responses with **libmodsecurity** (and optionally CRS), and tells Envoy to allow or block traffic before it reaches your origin. The connector loads libmodsecurity in-process and calls its C API from Rust.

**Status:** **0.1 alpha** (`v0.1.0-alpha.1`) for early testing / UAT — not a production release. Sign-off path: [UAT checklist](./docs/modes/uat.md). Notes: [`CHANGELOG.md`](./CHANGELOG.md).

Pinned versions: Envoy **v1.39.3**, libmodsecurity **v3.0.17**, CRS **v4.30.0** ([`versions.lock.md`](./versions.lock.md)).

**Author:** Etienne Munnich  
**License:** [Apache License 2.0](./LICENSE)

**Repository:** [github.com/etiennemunnich/modsec-envoy-connector](https://github.com/etiennemunnich/modsec-envoy-connector)

Formerly developed under the private name [`envoy-modsec-connex`](https://github.com/etiennemunnich/envoy-modsec-connex).

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
./demo/scripts/fail-closed.sh   # recommended for UAT
```

`up.sh` builds the connector and starts Envoy, the connector, and a tiny origin. Envoy listens on port 18080. By hand:

```bash
curl -i http://127.0.0.1:18080/                                         # 200 from origin
curl -i "http://127.0.0.1:18080/search?q=1'%20UNION%20SELECT%201,2--"  # 403 (CRS SQLi)
```

```bash
./demo/scripts/down.sh
```

Default body mode is BUFFERED. Other modes are in [docs/modes](./docs/modes/README.md). Early-tester checklist: [UAT](./docs/modes/uat.md).

## Docs

| Link | Topic |
|------|--------|
| [Getting started](./docs/modes/getting-started.md) | Same path, plus ports and health checks |
| [Early testing / UAT](./docs/modes/uat.md) | Clone → install → smoke → sign-off for 0.1 alpha |
| [Docs index](./docs/modes/README.md) | Install, body modes, fail-closed, testing, architecture |
| [How it works](./docs/how-it-works.md) | Request path and what is inspected |
| [Fail-closed](./docs/fail-closed.md) | When the connector or engine cannot decide |
| [Testing](./docs/testing.md) | How the project is tested |
| [Changelog](./CHANGELOG.md) | Release notes source |
| [Security scan (ASH)](./docs/ash.md) | Report-only scan and how to run it |
| [SECURITY.md](./SECURITY.md) | Vulnerability reporting (private) |
| [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) | Contributor Covenant |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Build from source, PRs, releases |

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0. See [LICENSE](./LICENSE).
