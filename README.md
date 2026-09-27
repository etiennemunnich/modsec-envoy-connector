# envoy-modsec-connex

Protect HTTP workloads behind [Envoy Proxy](https://www.envoyproxy.io/) with **ModSecurity** and the **OWASP Core Rule Set (CRS)**.

Envoy does not run ModSecurity by itself. This project is a small Rust **External Processing** (`ext_proc`) connector that sits beside Envoy, inspects requests and responses with **libmodsecurity** (and optionally CRS), and lets Envoy allow or block traffic before it reaches your origin.

**Author:** Etienne Munnich  
**License:** [Apache License 2.0](./LICENSE)

---

## Install

See **[demo/README.md](./demo/README.md)** for installing Envoy Proxy, libmodsecurity, and CRS, building the connector, and running a local smoke test.

---

## Docs

| Doc | Topic |
|-----|--------|
| [docs/how-it-works.md](./docs/how-it-works.md) | How Envoy, the connector, and ModSecurity fit together |
| [docs/fail-closed.md](./docs/fail-closed.md) | Behaviour when the connector or engine fails |
| [docs/testing.md](./docs/testing.md) | How the project is tested |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Building from source and contributing |
| [versions.lock.md](./versions.lock.md) | Envoy, ModSecurity, and CRS versions used in this tree |

---

Copyright © 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0 — see [LICENSE](./LICENSE).
