# envoy-modsec-connex

**Envoy `ext_proc` → Rust → libmodsecurity** (optional OWASP CRS).

An out-of-process Envoy External Processing connector that inspects HTTP traffic with ModSecurity v3. Envoy alone dials origin; the connector answers the ext_proc side-call and never opens a path to upstream.

**Author:** Etienne Munnich  
**License:** [Apache-2.0](./LICENSE) · [CONTRIBUTING](./CONTRIBUTING.md) (DCO; no CLA)

---

## Fail-closed

Protection routes lock `failure_mode_allow: false` (or equivalent). Connector down, hang past `message_timeout`, gRPC error, ModSec init/rules failure, or per-request engine `Err` → traffic does **not** reach origin as OK (typically **500** / **504** / policy **403**). Body mode (BUFFERED vs STREAMED) does not relax this. See [docs/fail-closed.md](./docs/fail-closed.md).

---

## Pins

Source of truth: [`versions.lock.md`](./versions.lock.md).

| Axis | Pin |
|------|-----|
| Envoy | `v1.39.1` |
| libmodsecurity | `v3.0.16` |
| OWASP CRS | `v4.29.0` (optional LTS `v4.25.1`) |
| Product | `v0.1.0` |

Bump deliberately. Do not invent tip flags.

---

## Docs

| Doc | What |
|-----|------|
| [docs/how-it-works.md](./docs/how-it-works.md) | Hop model, outcomes, pins |
| [docs/fail-closed.md](./docs/fail-closed.md) | Failure classes; Envoy vs connector ownership |
| [docs/testing.md](./docs/testing.md) | CI layers and lab gates |
| [versions.lock.md](./versions.lock.md) | Envoy / ModSec / CRS / product pins |
| [AGENTS.md](./AGENTS.md) | Coding-agent standards |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Setup, PR checklist, DCO |
| [docs/design-readiness-and-tests.md](./docs/design-readiness-and-tests.md) | Design readiness |
| [docs/findings/](./docs/findings/) | Research findings |
| [docs/boe/](./docs/boe/) | Built on Envoy notes |

Runnable lab proofs (compose, CRS go-ftw, fail-closed drills) live in private [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement) until deliberate migrate.

---

## Build

Rust **1.83+**. Workspace crates compile without system libmodsecurity until the native engine feature lands.

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace
./scripts/check-pins.sh
```

CI on every PR: `pin-check` + `rust-quality` (see `.github/workflows/ci.yml`).

### Layout

```
LICENSE / NOTICE               Apache-2.0
AGENTS.md / CONTRIBUTING.md    Agent + human contribute standards
versions.lock.md               Pin source of truth
crates/ext-proc-modsec         Product binary
crates/modsec-engine           Safe ModSec façade (fail-closed Decision)
docs/                          Product docs + findings + BoE notes
.github/                       PR template + thin CI
```

---

Copyright (c) 2026 Etienne Munnich. Licensed under the Apache License, Version 2.0 — see [LICENSE](./LICENSE).
