---
title: Testing — layers, gates, where lab lives
audience: operators + contributors
date: 2026-09-27
pins: Envoy v1.39.1 · libmodsecurity v3.0.16 · CRS v4.29.0 · failure_mode_allow:false
license: see LICENSE
status: PR CI = pins + Rust (libmodsecurity linked); live demo drills on a Mac / self-hosted host
---

# Testing

**One sentence:** PR CI runs pins + fmt/clippy/tests with libmodsecurity linked (including in-process gRPC tests of every phase and fail-closed path); the live Envoy demo, fail-closed drills and CRS go-ftw run on a Mac or self-hosted host.

Cross-links: [how-it-works.md](./how-it-works.md) · [fail-closed.md](./fail-closed.md) · [`versions.lock.md`](../versions.lock.md).

---

## Layer map

| Layer | Proves | On connex today? | Where it runs |
|-------|--------|------------------|---------------|
| **A — Pins + Rust** | pins; engine + connector unit tests; gRPC integration tests against libmodsecurity (allow, deny, redirect, request/response body, REMOTE_ADDR from attributes, fail-closed 500 paths, `/healthz`) | **Yes** | GitHub Actions (`pin-check`, `rust-quality`) and `cargo test --workspace` locally |
| **B — Live demo** | Envoy v1.39.1 → connector → libmodsecurity + CRS: benign **200**, SQLi/XSS URL + body **403**, response-body **403**; kill → **500**, hang → **504**, bad rules → **500**; origin untouched on every deny/failure | **Yes** | `demo/scripts/up.sh`, `smoke.sh`, `fail-closed.sh` (Mac / self-hosted) |
| **C — CRS go-ftw** | Full CRS regression over HTTP/1.x | **Not in this repo** | Experiment lab (`run-go-ftw.sh`) |
| **D — Version matrix** | Sliding ModSec / CRS / Envoy windows | **Not landed here** | Experiment dispatch workflows (when tip-merged) |

Do **not** gate connex PR merge on Mac-only hang/SIGSTOP, full CRS, or Envoy e2e.

---

## Local gates

```bash
cargo fmt --all -- --check
cargo clippy --workspace --all-targets -- -D warnings
cargo test --workspace            # CRS test runs when demo/.crs exists

./demo/scripts/up.sh              # Envoy + connector + CRS + origin
./demo/scripts/smoke.sh           # allow / deny / body / response path
./demo/scripts/fail-closed.sh     # kill → 500, hang → 504, bad rules → 500
./demo/scripts/down.sh
```

Product model for those classes: [fail-closed.md](./fail-closed.md).

---

## Honest boundaries

- **Not ported:** go-ftw CRS regression, HTTP/2 protocol-delivery suite, version matrix, perf harness. Those remain in [`modsec-envoy-experiement`](https://github.com/etiennemunnich/modsec-envoy-experiement).
- **CI green ≠ live proof.** Hosted CI does not run Envoy; the live demo drills are the end-to-end evidence.
- **No wiki.** In-repo `docs/` + README index only.
- **Pins:** quote [`versions.lock.md`](../versions.lock.md) — do not invent tip flags.
